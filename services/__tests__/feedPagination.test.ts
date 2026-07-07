import { describe, it, expect, vi } from 'vitest';

// feedService imports the shared supabase client at module load; stub it so the
// pure pagination helpers can be imported without VITE_* env vars. No test in
// this file touches the network.
vi.mock('../../lib/supabase', () => ({ supabase: {} }));

import {
  cursorFromFeedRow,
  decodeFeedCursor,
  encodeFeedCursor,
  FeedCursor,
} from '../feedService';

/**
 * Pins for the `get_feed_page` keyset-pagination RPC
 * (supabase/migrations/20260707_feed_page_rpc.sql).
 *
 * `boostedTsMirror` below is a pure TS transcription of the SQL ordering
 * expression (same technique as feedScores.test.ts's sqlTierScore):
 *
 *   boosted_ts = created_at + interval '2 hours' * (event_type = 'review')::int
 *
 * WINDOWLESS: every review sorts as created_at + 2h permanently — reviews
 * float above up-to-2h-newer cards at ANY age, exactly like the legacy
 * client's applyReviewBoost (plan-owner decision, 2026-07-07 review; the
 * earlier 2h-window pins were a plan-authoring error). The expression is a
 * pure function of the row — no now(), no session anchor — so the ordering
 * is deterministic forever and cursors never expire.
 *
 * The mirror is TEST-ONLY: in production the RPC returns boosted_ts as a
 * server-computed column and `cursorFromFeedRow` copies it verbatim, so the
 * client never recomputes the ordering key (byte-exact cursors, µs
 * precision preserved).
 */
function boostedTsMirror(eventType: string, createdAt: string): number {
  const HOUR_MS = 60 * 60 * 1000;
  const base = Date.parse(createdAt);
  return eventType === 'review' ? base + 2 * HOUR_MS : base;
}

const NOW = '2026-07-07T12:00:00.000Z';

/** ISO timestamp `minutes` before NOW (an arbitrary fixed reference). */
function minutesBefore(minutes: number): string {
  return new Date(Date.parse(NOW) - minutes * 60 * 1000).toISOString();
}

/** In-test comparator mirroring the SQL `order by boosted_ts desc, id desc`. */
function sortBoostedDesc(
  rows: { eventType: string; createdAt: string; id: string }[],
): { eventType: string; createdAt: string; id: string }[] {
  return [...rows].sort((a, b) => {
    const at = boostedTsMirror(a.eventType, a.createdAt);
    const bt = boostedTsMirror(b.eventType, b.createdAt);
    if (at !== bt) return bt - at;
    return b.id.localeCompare(a.id);
  });
}

describe('feed cursor encode/decode', () => {
  it('round-trips a cursor with a JS-normalized timestamp', () => {
    const cursor: FeedCursor = {
      boostedTs: '2026-07-07T12:01:00.000Z',
      id: '5f4dcc3b-5aa7-4f65-9d3c-7a1b2c3d4e5f',
    };
    expect(decodeFeedCursor(encodeFeedCursor(cursor))).toEqual(cursor);
  });

  it('round-trips a cursor with a raw PostgREST microsecond timestamp', () => {
    // boosted_ts arrives from the server in PostgREST's +00:00 microsecond
    // format; the cursor must survive it byte-exact.
    const cursor: FeedCursor = {
      boostedTs: '2026-07-07T08:15:42.123456+00:00',
      id: '00000000-0000-4000-8000-000000000001',
    };
    expect(decodeFeedCursor(encodeFeedCursor(cursor))).toEqual(cursor);
  });

  it('rejects malformed cursors with null instead of throwing', () => {
    expect(decodeFeedCursor('not json at all')).toBeNull();
    expect(decodeFeedCursor('')).toBeNull();
    expect(decodeFeedCursor('null')).toBeNull();
    expect(decodeFeedCursor('[]')).toBeNull();
    expect(decodeFeedCursor('{}')).toBeNull();
    expect(decodeFeedCursor('{"boostedTs":"2026-07-07T12:00:00Z"}')).toBeNull(); // id missing
    expect(decodeFeedCursor('{"id":"abc"}')).toBeNull(); // boostedTs missing
    expect(decodeFeedCursor('{"boostedTs":123,"id":"abc"}')).toBeNull(); // wrong type
    expect(decodeFeedCursor('{"boostedTs":"","id":""}')).toBeNull(); // empty strings
  });
});

describe('cursorFromFeedRow — server-computed boosted_ts, copied verbatim', () => {
  it('takes the server boosted_ts byte-exact for a boosted review row (µs preserved)', () => {
    const row = {
      id: '5f4dcc3b-5aa7-4f65-9d3c-7a1b2c3d4e5f',
      event_type: 'review',
      created_at: '2026-07-07T08:15:42.123456+00:00',
      boosted_ts: '2026-07-07T10:15:42.123456+00:00', // created_at + 2h, server-computed
    };
    const cursor = cursorFromFeedRow(row);
    expect(cursor.boostedTs).toBe(row.boosted_ts); // exact string, no recomputation
    expect(cursor.id).toBe(row.id);
    // The server value agrees with the TS mirror of the SQL expression
    // (compared at ms precision — the mirror exists only to pin semantics).
    expect(Date.parse(cursor.boostedTs)).toBe(
      boostedTsMirror(row.event_type, row.created_at),
    );
  });

  it('takes the server boosted_ts for a non-boosted row (equals created_at)', () => {
    const row = {
      id: '00000000-0000-4000-8000-000000000002',
      event_type: 'ranking_add',
      created_at: '2026-07-07T08:15:42.654321+00:00',
      boosted_ts: '2026-07-07T08:15:42.654321+00:00',
    };
    const cursor = cursorFromFeedRow(row);
    expect(cursor.boostedTs).toBe(row.boosted_ts);
    expect(Date.parse(cursor.boostedTs)).toBe(
      boostedTsMirror(row.event_type, row.created_at),
    );
  });

  it('round-trips through encode/decode unchanged', () => {
    const row = {
      id: '00000000-0000-4000-8000-000000000003',
      event_type: 'review',
      created_at: '2026-07-06T23:59:59.999999+00:00',
      boosted_ts: '2026-07-07T01:59:59.999999+00:00',
    };
    const cursor = cursorFromFeedRow(row);
    expect(decodeFeedCursor(encodeFeedCursor(cursor))).toEqual(cursor);
  });
});

describe('boostedTsMirror — windowless SQL boosted_ts semantics', () => {
  it('boosts every review by exactly +2h regardless of age', () => {
    for (const minutes of [1, 30, 119, 121, 180, 60 * 24, 60 * 24 * 30]) {
      const createdAt = minutesBefore(minutes);
      expect(boostedTsMirror('review', createdAt)).toBe(
        Date.parse(createdAt) + 2 * 60 * 60 * 1000,
      );
    }
  });

  it('never boosts non-review events', () => {
    for (const eventType of ['ranking_add', 'ranking_move', 'ranking_remove', 'list_create', 'milestone']) {
      const createdAt = minutesBefore(1);
      expect(boostedTsMirror(eventType, createdAt)).toBe(Date.parse(createdAt));
    }
  });
});

describe('keyset ordering (boosted_ts desc, id desc) — windowless boost', () => {
  it('a review created 3h ago outranks a ranking_add created 1.5h ago', () => {
    // review: -180m + 120m boost = -60m effective; ranking_add: -90m.
    const review = { eventType: 'review', createdAt: minutesBefore(180), id: 'r' };
    const rankingAdd = { eventType: 'ranking_add', createdAt: minutesBefore(90), id: 'k' };
    expect(sortBoostedDesc([rankingAdd, review]).map(r => r.id)).toEqual(['r', 'k']);
  });

  it('a review created 2h01m ago outranks a ranking_add created 30m ago', () => {
    // Windowless: review -121m + 120m = -1m effective > -30m. (This inverts
    // the earlier window-based pin, which was a plan-authoring error.)
    const review = { eventType: 'review', createdAt: minutesBefore(121), id: 'r' };
    const rankingAdd = { eventType: 'ranking_add', createdAt: minutesBefore(30), id: 'k' };
    expect(sortBoostedDesc([rankingAdd, review]).map(r => r.id)).toEqual(['r', 'k']);
  });

  it('a review does NOT outrank a card more than 2h newer', () => {
    // review: -180m + 120m = -60m effective; ranking_add at -50m stays above.
    const review = { eventType: 'review', createdAt: minutesBefore(180), id: 'r' };
    const rankingAdd = { eventType: 'ranking_add', createdAt: minutesBefore(50), id: 'k' };
    expect(sortBoostedDesc([review, rankingAdd]).map(r => r.id)).toEqual(['k', 'r']);
  });

  it('reviews keep their relative recency among themselves (uniform +2h shift)', () => {
    const newerReview = { eventType: 'review', createdAt: minutesBefore(10), id: 'a' };
    const olderReview = { eventType: 'review', createdAt: minutesBefore(90), id: 'z' };
    // 'z' > 'a' lexically, so an id-desc tiebreak would flip them if the
    // boost collapsed their keys; the uniform shift must not.
    expect(sortBoostedDesc([olderReview, newerReview]).map(r => r.id)).toEqual(['a', 'z']);
  });

  it('breaks exact boosted_ts ties by id desc', () => {
    const t = minutesBefore(45);
    const rows = [
      { eventType: 'ranking_add', createdAt: t, id: '11111111-0000-4000-8000-000000000000' },
      { eventType: 'ranking_add', createdAt: t, id: '99999999-0000-4000-8000-000000000000' },
    ];
    const sorted = sortBoostedDesc(rows);
    expect(sorted[0].id).toBe('99999999-0000-4000-8000-000000000000');
    expect(sorted[1].id).toBe('11111111-0000-4000-8000-000000000000');
  });

  it('a boosted review and a 2h-newer non-review tie exactly on boosted_ts (id decides)', () => {
    // Deliberate edge: created_at + 2h of the review == created_at of the
    // ranking_add. The SQL and the mirror must agree this is a tie.
    const review = { eventType: 'review', createdAt: minutesBefore(150), id: 'a' };
    const rankingAdd = { eventType: 'ranking_add', createdAt: minutesBefore(30), id: 'z' };
    expect(boostedTsMirror(review.eventType, review.createdAt)).toBe(
      boostedTsMirror(rankingAdd.eventType, rankingAdd.createdAt),
    );
    expect(sortBoostedDesc([review, rankingAdd]).map(r => r.id)).toEqual(['z', 'a']);
  });
});
