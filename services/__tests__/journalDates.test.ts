import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// journalService imports the supabase client (needs import.meta.env) at module
// scope (directly and via feedService) — mock it so the pure helpers and the
// service paths can be exercised in the node test environment. No network.
// It also imports stubService (for localDateString, audit B7), which pulls in
// the browser-only color lib at module scope — mock that too.
const mocks = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { from: mocks.from, rpc: mocks.rpc } }));
vi.mock('../feedService', () => ({ logReviewActivityEvent: vi.fn() }));
vi.mock('color-thief-browser', () => ({ default: class ColorThief {} }));

import { computeStreaks, upsertJournalEntry, getJournalStats } from '../journalService';
import { localDateString } from '../stubService';

/**
 * Chainable PostgREST-builder fake: every method returns the chain itself,
 * and awaiting the chain resolves to `result` (thenable).
 */
function chain(result: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const c: any = {};
  for (const m of ['insert', 'upsert', 'delete', 'select', 'eq', 'in', 'order', 'range', 'single', 'maybeSingle']) {
    c[m] = vi.fn(() => c);
  }
  c.then = (onFulfilled: (v: unknown) => unknown) =>
    Promise.resolve(result).then(onFulfilled);
  return c;
}

// ── computeStreaks truth table (audit B7: whole LOCAL calendar days) ─────────

describe('computeStreaks', () => {
  it('returns zeros for no entries', () => {
    expect(computeStreaks([], '2026-07-06')).toEqual({ currentStreak: 0, longestStreak: 0 });
  });

  it('single entry today → current 1, longest 1', () => {
    expect(computeStreaks(['2026-07-06'], '2026-07-06')).toEqual({ currentStreak: 1, longestStreak: 1 });
  });

  it('single entry yesterday → streak still current (B7 regression: was 0 in UTC-negative offsets)', () => {
    // Old code compared UTC-midnight-parsed dates against LOCAL midnight, so
    // daysSinceLast for a yesterday entry evaluated to ~1.3 in UTC-7 and the
    // `<= 1` check failed. Pure string calendar math makes this exactly 1.
    expect(computeStreaks(['2026-07-05'], '2026-07-06')).toEqual({ currentStreak: 1, longestStreak: 1 });
  });

  it('single entry two days ago → current 0, longest 1', () => {
    expect(computeStreaks(['2026-07-04'], '2026-07-06')).toEqual({ currentStreak: 0, longestStreak: 1 });
  });

  it('consecutive run ending today (gap = 1 day chains)', () => {
    expect(computeStreaks(['2026-07-04', '2026-07-05', '2026-07-06'], '2026-07-06'))
      .toEqual({ currentStreak: 3, longestStreak: 3 });
  });

  it('gap = 2 days breaks the chain', () => {
    expect(computeStreaks(['2026-07-01', '2026-07-03'], '2026-07-03'))
      .toEqual({ currentStreak: 1, longestStreak: 1 });
  });

  it('duplicate same-day entries collapse to one day', () => {
    expect(computeStreaks(['2026-07-05', '2026-07-05', '2026-07-06', '2026-07-06'], '2026-07-06'))
      .toEqual({ currentStreak: 2, longestStreak: 2 });
  });

  it('ignores null/undefined watched_dates', () => {
    expect(computeStreaks([null, undefined, '2026-07-06'], '2026-07-06'))
      .toEqual({ currentStreak: 1, longestStreak: 1 });
  });

  it('sorts unordered input before chaining', () => {
    expect(computeStreaks(['2026-07-06', '2026-07-04', '2026-07-05'], '2026-07-06'))
      .toEqual({ currentStreak: 3, longestStreak: 3 });
  });

  it('chains across a month boundary', () => {
    expect(computeStreaks(['2026-06-30', '2026-07-01'], '2026-07-01'))
      .toEqual({ currentStreak: 2, longestStreak: 2 });
  });

  it('chains across a year boundary', () => {
    expect(computeStreaks(['2025-12-31', '2026-01-01'], '2026-01-01'))
      .toEqual({ currentStreak: 2, longestStreak: 2 });
  });

  it('handles leap-day chains (Feb 28 → Feb 29 → Mar 1, 2024)', () => {
    expect(computeStreaks(['2024-02-28', '2024-02-29', '2024-03-01'], '2024-03-01'))
      .toEqual({ currentStreak: 3, longestStreak: 3 });
  });

  it('non-leap Feb 28 → Mar 1 chains (Feb has 28 days in 2025)', () => {
    expect(computeStreaks(['2025-02-28', '2025-03-01'], '2025-03-01'))
      .toEqual({ currentStreak: 2, longestStreak: 2 });
  });

  it('leap-year Feb 28 → Mar 1 is a gap of 2 (skips Feb 29, chain breaks)', () => {
    expect(computeStreaks(['2024-02-28', '2024-03-01'], '2024-03-01'))
      .toEqual({ currentStreak: 1, longestStreak: 1 });
  });

  it('keeps the longest historical run when the current one is shorter', () => {
    expect(computeStreaks(
      ['2026-06-01', '2026-06-02', '2026-06-03', '2026-06-10', '2026-06-11'],
      '2026-06-11',
    )).toEqual({ currentStreak: 2, longestStreak: 3 });
  });

  it('stale run: last entry 2+ days before today → current 0, longest preserved', () => {
    expect(computeStreaks(['2026-06-01', '2026-06-02', '2026-06-03'], '2026-06-20'))
      .toEqual({ currentStreak: 0, longestStreak: 3 });
  });

  it('tolerates a future-dated last entry (legacy UTC-stamped "tomorrow" rows, B7 data)', () => {
    // Old writes could stamp tomorrow's date for evening users west of UTC.
    // daysSinceLast is then negative; the run must still count as current
    // rather than silently zeroing an active streak.
    expect(computeStreaks(['2026-07-06', '2026-07-07'], '2026-07-06'))
      .toEqual({ currentStreak: 2, longestStreak: 2 });
  });
});

// ── Date derivation (audit B7: user-local calendar day, never UTC) ───────────

/** yyyy-MM-dd for an instant in a NAMED timezone (C0's technique). */
function dayIn(timeZone: string | undefined, instant: Date): string {
  return new Intl.DateTimeFormat('en-CA', {
    ...(timeZone ? { timeZone } : {}),
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(instant);
}

describe('local vs UTC calendar days (named-timezone fixtures)', () => {
  it('an LA evening straddling UTC midnight lands on DIFFERENT calendar days', () => {
    // 2026-01-01T04:30Z is 8:30pm Dec 31 in Los Angeles: the old
    // toISOString().split('T')[0] default stamped New Year's Eve entries as
    // New Year's Day for every user west of UTC.
    const nyeInLa = new Date('2026-01-01T04:30:00Z');
    expect(dayIn('America/Los_Angeles', nyeInLa)).toBe('2025-12-31');
    expect(nyeInLa.toISOString().split('T')[0]).toBe('2026-01-01');
  });

  it('a plain LA evening is stamped tomorrow by the UTC derivation', () => {
    const eveningInLa = new Date('2026-07-07T05:30:00Z'); // 10:30pm Jul 6 in LA
    expect(dayIn('America/Los_Angeles', eveningInLa)).toBe('2026-07-06');
    expect(eveningInLa.toISOString().split('T')[0]).toBe('2026-07-07');
  });

  it('localDateString agrees with the runtime-timezone calendar at those instants', () => {
    // Whatever timezone the suite runs in (UTC on CI, LA locally), the local
    // formatter must match Intl's calendar for that same runtime zone — i.e.
    // run with TZ=America/Los_Angeles these become the LA fixtures above.
    for (const iso of ['2026-01-01T04:30:00Z', '2026-07-07T05:30:00Z']) {
      const instant = new Date(iso);
      expect(localDateString(instant)).toBe(dayIn(undefined, instant));
    }
  });
});

describe('upsertJournalEntry watched_date default', () => {
  let rankingChain: ReturnType<typeof chain>;
  let entryChain: ReturnType<typeof chain>;

  const dbRow = {
    id: 'e-1',
    user_id: 'u-1',
    tmdb_id: '603',
    title: 'The Matrix',
    poster_url: null,
    rating_tier: null,
    review_text: null,
    contains_spoilers: false,
    mood_tags: [],
    vibe_tags: [],
    favorite_moments: [],
    standout_performances: [],
    watched_date: '2026-07-06',
    watched_location: null,
    watched_with_user_ids: [],
    watched_platform: null,
    is_rewatch: false,
    rewatch_note: null,
    personal_takeaway: null,
    photo_paths: [],
    visibility_override: null,
    like_count: 0,
    created_at: '2026-07-06T00:00:00Z',
    updated_at: '2026-07-06T00:00:00Z',
  };

  beforeEach(() => {
    vi.clearAllMocks();
    rankingChain = chain({ data: null, error: null });
    entryChain = chain({ data: dbRow, error: null });
    mocks.from.mockImplementation((table: string) =>
      table === 'user_rankings' ? rankingChain : entryChain);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('defaults watched_date to the user-LOCAL calendar day at 11:30pm local (B7)', async () => {
    vi.useFakeTimers();
    // Constructed from LOCAL components: 11:30pm July 6 local time. In any
    // timezone west of UTC (and for TZ=UTC itself) the old UTC derivation and
    // the local day diverge or coincide — but localDateString must ALWAYS
    // yield July 6 here, because the wall clock says July 6.
    vi.setSystemTime(new Date(2026, 6, 6, 23, 30, 0));

    await upsertJournalEntry('u-1', '603', { title: 'The Matrix' });

    expect(entryChain.upsert).toHaveBeenCalledTimes(1);
    const payload = entryChain.upsert.mock.calls[0][0];
    expect(payload.watched_date).toBe('2026-07-06');
    expect(payload.watched_date).toBe(localDateString(new Date()));
  });

  it('uses an explicitly provided watchedDate verbatim', async () => {
    await upsertJournalEntry('u-1', '603', { title: 'The Matrix', watchedDate: '2026-04-18' });
    const payload = entryChain.upsert.mock.calls[0][0];
    expect(payload.watched_date).toBe('2026-04-18');
  });
});

describe('getJournalStats streaks (service wiring)', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  function statsChainFor(dates: (string | null)[]) {
    const rows = dates.map((d) => ({
      mood_tags: [],
      review_text: null,
      watched_date: d,
      watched_with_user_ids: [],
    }));
    const c = chain({ data: rows, error: null });
    mocks.from.mockReturnValue(c);
    return c;
  }

  it('a yesterday-entry streak is current at 8pm local (B7 regression: was 0 west of UTC)', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 6, 6, 20, 0, 0)); // 8pm July 6 LOCAL
    statsChainFor(['2026-07-05']);

    const stats = await getJournalStats('u-1');

    expect(stats.currentStreak).toBe(1);
    expect(stats.longestStreak).toBe(1);
  });

  it('consecutive local days including today produce a running streak', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 6, 6, 23, 59, 0)); // 11:59pm July 6 LOCAL
    statsChainFor(['2026-07-04', '2026-07-05', '2026-07-06', '2026-07-06', null]);

    const stats = await getJournalStats('u-1');

    expect(stats.totalEntries).toBe(5);
    expect(stats.currentStreak).toBe(3);
    expect(stats.longestStreak).toBe(3);
  });

  it('a run ending two local days ago is not current', async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2026, 6, 6, 12, 0, 0));
    statsChainFor(['2026-07-03', '2026-07-04']);

    const stats = await getJournalStats('u-1');

    expect(stats.currentStreak).toBe(0);
    expect(stats.longestStreak).toBe(2);
  });
});
