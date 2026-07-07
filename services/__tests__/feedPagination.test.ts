import { describe, it, expect, vi } from 'vitest';

// feedService imports the shared supabase client at module load; stub it so the
// pure pagination helpers can be imported without VITE_* env vars. No test in
// this file touches the network.
vi.mock('../../lib/supabase', () => ({ supabase: {} }));

import {
  computeBoostedTs,
  decodeFeedCursor,
  encodeFeedCursor,
  FeedCursor,
} from '../feedService';

/**
 * Pins for the `get_feed_page` keyset-pagination RPC
 * (supabase/migrations/20260707_feed_page_rpc.sql).
 *
 * `computeBoostedTs` is the production TS mirror of the SQL ordering
 * expression — the client MUST reproduce it exactly to build the keyset
 * cursor from the last row of a page:
 *
 *   boosted_ts = case
 *     when event_type = 'review'
 *      and created_at > session_ts - interval '2 hours'
 *     then created_at + interval '2 hours'
 *     else created_at
 *   end
 *
 * `session_ts` is the FIRST page's timestamp, frozen for the whole pagination
 * session, so the boost window does not drift between pages as wall-clock
 * now() advances (rows would otherwise shift across page boundaries and be
 * duplicated or skipped). Same SQL-mirror technique as feedScores.test.ts's
 * sqlTierScore.
 */

const SESSION_TS = '2026-07-07T12:00:00.000Z';
const HOUR_MS = 60 * 60 * 1000;

/** ISO timestamp `minutes` before SESSION_TS. */
function minutesBefore(minutes: number): string {
  return new Date(Date.parse(SESSION_TS) - minutes * 60 * 1000).toISOString();
}

/** In-test comparator mirroring the SQL `order by boosted_ts desc, id desc`. */
function sortBoostedDesc(
  rows: { eventType: string; createdAt: string; id: string }[],
): { eventType: string; createdAt: string; id: string }[] {
  return [...rows].sort((a, b) => {
    const at = Date.parse(computeBoostedTs(a.eventType, a.createdAt, SESSION_TS));
    const bt = Date.parse(computeBoostedTs(b.eventType, b.createdAt, SESSION_TS));
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
    // Non-boosted rows pass created_at through verbatim, so the cursor must
    // survive the +00:00 microsecond format PostgREST emits.
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

describe('computeBoostedTs — SQL boosted_ts mirror', () => {
  it('boosts a review created 1h59m before session_ts by exactly +2h', () => {
    const createdAt = minutesBefore(119);
    const boosted = computeBoostedTs('review', createdAt, SESSION_TS);
    expect(Date.parse(boosted)).toBe(Date.parse(createdAt) + 2 * HOUR_MS);
  });

  it('does NOT boost a review created 2h01m before session_ts', () => {
    const createdAt = minutesBefore(121);
    expect(computeBoostedTs('review', createdAt, SESSION_TS)).toBe(createdAt);
  });

  it('window boundary is strict: exactly 2h old is NOT boosted, 1ms younger is', () => {
    const atBoundary = minutesBefore(120);
    expect(computeBoostedTs('review', atBoundary, SESSION_TS)).toBe(atBoundary);

    const justInside = new Date(Date.parse(atBoundary) + 1).toISOString();
    expect(Date.parse(computeBoostedTs('review', justInside, SESSION_TS))).toBe(
      Date.parse(justInside) + 2 * HOUR_MS,
    );
  });

  it('never boosts non-review events, however recent', () => {
    for (const eventType of ['ranking_add', 'ranking_move', 'ranking_remove', 'list_create', 'milestone']) {
      const createdAt = minutesBefore(1);
      expect(computeBoostedTs(eventType, createdAt, SESSION_TS)).toBe(createdAt);
    }
  });

  it('passes non-boosted timestamps through VERBATIM (keyset needs full µs precision)', () => {
    const microseconds = '2026-07-07T08:15:42.123456+00:00';
    expect(computeBoostedTs('ranking_add', microseconds, SESSION_TS)).toBe(microseconds);
    // Out-of-window review: also verbatim.
    expect(computeBoostedTs('review', '2026-07-06T08:15:42.123456+00:00', SESSION_TS)).toBe(
      '2026-07-06T08:15:42.123456+00:00',
    );
  });

  it('freezing session_ts keeps the boost stable across pages; a drifting clock would not', () => {
    const createdAt = minutesBefore(115); // 1h55m before the frozen session_ts
    const frozen = computeBoostedTs('review', createdAt, SESSION_TS);
    expect(Date.parse(frozen)).toBe(Date.parse(createdAt) + 2 * HOUR_MS);

    // Same row evaluated 10 minutes later (as an unfrozen now() would): the
    // review has crossed the 2h boundary and loses the boost — its sort key
    // would collapse by ~2h between pages. Passing the first page's
    // session_ts to every page prevents exactly this.
    const laterNow = new Date(Date.parse(SESSION_TS) + 10 * 60 * 1000).toISOString();
    expect(computeBoostedTs('review', createdAt, laterNow)).toBe(createdAt);
  });
});

describe('keyset ordering (boosted_ts desc, id desc)', () => {
  it('review at 1h59m sorts above a ranking_add at 30m; review at 2h01m sorts below it', () => {
    const boostedReview = { eventType: 'review', createdAt: minutesBefore(119), id: 'b' };
    const rankingAdd = { eventType: 'ranking_add', createdAt: minutesBefore(30), id: 'c' };
    const staleReview = { eventType: 'review', createdAt: minutesBefore(121), id: 'a' };

    const sorted = sortBoostedDesc([staleReview, rankingAdd, boostedReview]);
    expect(sorted.map(r => r.id)).toEqual(['b', 'c', 'a']);
  });

  it('boosted reviews keep their relative recency among themselves', () => {
    const newerReview = { eventType: 'review', createdAt: minutesBefore(10), id: 'a' };
    const olderReview = { eventType: 'review', createdAt: minutesBefore(90), id: 'z' };
    // 'z' > 'a' lexically, so an id-desc tiebreak would flip them if the boost
    // collapsed both keys to a single timestamp; the additive boost must not.
    const sorted = sortBoostedDesc([olderReview, newerReview]);
    expect(sorted.map(r => r.id)).toEqual(['a', 'z']);
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
});
