import { describe, it, expect, vi, beforeEach } from 'vitest';

// journalService imports the supabase client (needs import.meta.env) at module
// scope (directly and via feedService) — mock it so the pure helpers and the
// service paths can be exercised in the node test environment. No network.
const mocks = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { from: mocks.from, rpc: mocks.rpc } }));

// The B6 gate decides whether logReviewActivityEvent fires at all — spy on it.
const feedMocks = vi.hoisted(() => ({ logReviewActivityEvent: vi.fn() }));
vi.mock('../feedService', () => ({ logReviewActivityEvent: feedMocks.logReviewActivityEvent }));

// reviewService pulls profile enrichment helpers — stub them so its read
// paths run without network.
vi.mock('../profileService', () => ({
  getProfilesByIds: vi.fn(async () => new Map()),
  getFollowingIdSet: vi.fn(async () => new Set()),
  toTier: () => undefined,
}));

import {
  resolveVisibility,
  shouldEmitReviewEvent,
  JOURNAL_ENTRY_SHARED_COLUMN_LIST,
  JOURNAL_ENTRY_SHARED_COLUMNS,
  upsertJournalEntry,
  listJournalEntries,
  getJournalEntry,
  getJournalEntryById,
  pickEntryForEdit,
} from '../journalService';
import type { ResolvedJournalVisibility } from '../journalService';
import type { JournalEntry } from '../../types';
import { REVIEW_ENTRY_COLUMNS, getReviewsForMovie, getReviewsByUser } from '../reviewService';

/**
 * Chainable PostgREST-builder fake: every method returns the chain itself,
 * and awaiting the chain resolves to `result` (thenable).
 */
function chain(result: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const c: any = {};
  for (const m of [
    'insert', 'upsert', 'delete', 'select', 'eq', 'in', 'not', 'contains',
    'gte', 'lte', 'order', 'range', 'limit', 'maybeSingle', 'single',
  ]) {
    c[m] = vi.fn(() => c);
  }
  c.then = (onFulfilled: (v: unknown) => unknown) =>
    Promise.resolve(result).then(onFulfilled);
  return c;
}

/** Route supabase.from(table) to a per-table chain; unknown tables throw. */
function routeTables(map: Record<string, unknown>) {
  mocks.from.mockImplementation((table: string) => {
    if (!(table in map)) throw new Error(`unexpected table: ${table}`);
    return map[table];
  });
}

function tablesCalled(): string[] {
  return mocks.from.mock.calls.map((c) => c[0] as string);
}

const DB_ROW = {
  id: 'entry-1',
  user_id: 'user-1',
  tmdb_id: '603',
  title: 'The Matrix',
  poster_url: null,
  rating_tier: 'S',
  review_text: 'great',
  contains_spoilers: false,
  mood_tags: [],
  vibe_tags: [],
  favorite_moments: [],
  standout_performances: [],
  watched_date: '2026-07-07',
  watched_location: null,
  watched_with_user_ids: [],
  watched_platform: null,
  is_rewatch: false,
  rewatch_note: null,
  personal_takeaway: null,
  photo_paths: [],
  visibility_override: null as string | null,
  like_count: 0,
  created_at: '2026-07-07T00:00:00Z',
  updated_at: '2026-07-07T00:00:00Z',
};

beforeEach(() => {
  mocks.from.mockReset();
  mocks.rpc.mockReset();
  feedMocks.logReviewActivityEvent.mockReset();
  feedMocks.logReviewActivityEvent.mockResolvedValue(true);
});

// ── resolveVisibility — the adjudicated resolution truth table (B2) ─────────
//
// visibility_override IS NULL ("Default") resolves to the author's
// profiles.profile_visibility; an explicit override always wins. Mirrors the
// SQL policy's COALESCE(visibility_override, profile_visibility) exactly.

describe('resolveVisibility', () => {
  const truthTable: Array<{
    override: string | null | undefined;
    profile: string;
    expected: ResolvedJournalVisibility;
  }> = [
    // explicit 'public' override wins over every profile value
    { override: 'public', profile: 'public', expected: 'public' },
    { override: 'public', profile: 'friends', expected: 'public' },
    { override: 'public', profile: 'private', expected: 'public' },
    // explicit 'friends' override wins over every profile value
    { override: 'friends', profile: 'public', expected: 'friends' },
    { override: 'friends', profile: 'friends', expected: 'friends' },
    { override: 'friends', profile: 'private', expected: 'friends' },
    // explicit 'private' override wins over every profile value
    { override: 'private', profile: 'public', expected: 'private' },
    { override: 'private', profile: 'friends', expected: 'private' },
    { override: 'private', profile: 'private', expected: 'private' },
    // NULL ("Default") inherits the author's profile visibility — the B2 fix:
    // this row set was world-readable before.
    { override: null, profile: 'public', expected: 'public' },
    { override: null, profile: 'friends', expected: 'friends' },
    { override: null, profile: 'private', expected: 'private' },
    // undefined (form never touched the field) behaves exactly like NULL
    { override: undefined, profile: 'public', expected: 'public' },
    { override: undefined, profile: 'friends', expected: 'friends' },
    { override: undefined, profile: 'private', expected: 'private' },
  ];

  for (const { override, profile, expected } of truthTable) {
    it(`override=${String(override)} + profile=${profile} → ${expected}`, () => {
      expect(resolveVisibility(override, profile)).toBe(expected);
    });
  }

  it('unknown profile visibility fails closed to the DB default (friends), never public', () => {
    // profiles.profile_visibility is NOT NULL DEFAULT 'friends' — null here
    // means the client-side fetch failed, not that the DB allows null.
    expect(resolveVisibility(null, null)).toBe('friends');
    expect(resolveVisibility(null, undefined)).toBe('friends');
    expect(resolveVisibility(null, 'bogus')).toBe('friends');
  });

  it('an invalid explicit override fails closed to private (mirrors the SQL policy matching neither branch)', () => {
    expect(resolveVisibility('bogus', 'public')).toBe('private');
  });

  it('never resolves public unless an explicit public override or a public profile says so', () => {
    const overrides = ['friends', 'private', null, undefined, 'bogus'];
    const profiles = ['friends', 'private', null, undefined, 'bogus'];
    for (const o of overrides) {
      for (const p of profiles) {
        expect(resolveVisibility(o, p)).not.toBe('public');
      }
    }
  });
});

// ── shouldEmitReviewEvent — the B6 gate predicate ────────────────────────────
//
// activity_events review rows reach ALL authenticated users via the C1
// explore policy when the author's profile is public, so emission is allowed
// only when the entry's RESOLVED visibility is 'public' (was `!== 'private'`).

describe('shouldEmitReviewEvent', () => {
  it('emits for an explicit public override (profile irrelevant)', () => {
    expect(shouldEmitReviewEvent('great', 'public', null)).toBe(true);
    expect(shouldEmitReviewEvent('great', 'public', 'private')).toBe(true);
  });

  it('emits for a NULL override on a public profile (resolved public)', () => {
    expect(shouldEmitReviewEvent('great', null, 'public')).toBe(true);
  });

  it('does NOT emit for a friends override on a public profile — the exact B6 leak', () => {
    // Before this fix, a 'friends'-only entry by a public-visibility profile
    // emitted metadata.reviewBody into activity_events, readable by everyone.
    expect(shouldEmitReviewEvent('great', 'friends', 'public')).toBe(false);
  });

  it('does NOT emit for NULL override on a friends/private profile (resolved non-public)', () => {
    expect(shouldEmitReviewEvent('great', null, 'friends')).toBe(false);
    expect(shouldEmitReviewEvent('great', null, 'private')).toBe(false);
  });

  it('does NOT emit for a private override', () => {
    expect(shouldEmitReviewEvent('great', 'private', 'public')).toBe(false);
  });

  it('does NOT emit without review text', () => {
    expect(shouldEmitReviewEvent('', 'public', 'public')).toBe(false);
    expect(shouldEmitReviewEvent(undefined, 'public', 'public')).toBe(false);
    expect(shouldEmitReviewEvent(null, 'public', 'public')).toBe(false);
  });

  it('fails closed when the profile visibility is unknown (fetch failure)', () => {
    expect(shouldEmitReviewEvent('great', null, null)).toBe(false);
  });
});

// ── Column lists — B5's read half ────────────────────────────────────────────

describe('JOURNAL_ENTRY_SHARED_COLUMNS', () => {
  it('excludes owner-only personal_takeaway and the internal search_vector', () => {
    expect(JOURNAL_ENTRY_SHARED_COLUMN_LIST).not.toContain('personal_takeaway');
    expect(JOURNAL_ENTRY_SHARED_COLUMN_LIST).not.toContain('search_vector');
    expect(JOURNAL_ENTRY_SHARED_COLUMNS).not.toMatch(/personal_takeaway/);
  });

  it('carries every other contract column (matches the Task 1 search RPC return set, 23 columns)', () => {
    expect([...JOURNAL_ENTRY_SHARED_COLUMN_LIST].sort()).toEqual(
      [
        'id', 'user_id', 'tmdb_id', 'title', 'poster_url', 'rating_tier',
        'review_text', 'contains_spoilers', 'mood_tags', 'vibe_tags',
        'favorite_moments', 'standout_performances', 'watched_date',
        'watched_location', 'watched_with_user_ids', 'watched_platform',
        'is_rewatch', 'rewatch_note', 'photo_paths', 'visibility_override',
        'like_count', 'created_at', 'updated_at',
      ].sort(),
    );
  });
});

describe('REVIEW_ENTRY_COLUMNS', () => {
  it('excludes personal_takeaway from the review read shape', () => {
    expect(REVIEW_ENTRY_COLUMNS).not.toMatch(/personal_takeaway/);
    expect(REVIEW_ENTRY_COLUMNS).toMatch(/review_text/);
  });
});

// ── upsertJournalEntry — B6 gate wired through the service ──────────────────

describe('upsertJournalEntry review event gate (B6)', () => {
  function upsertChains(overrides: Partial<typeof DB_ROW> = {}, profileVisibility?: string | null) {
    return {
      user_rankings: chain({ data: { tier: 'S' }, error: null }),
      journal_entries: chain({ data: { ...DB_ROW, ...overrides }, error: null }),
      profiles: chain({
        data: profileVisibility === undefined ? null : { profile_visibility: profileVisibility },
        error: null,
      }),
    };
  }

  it('emits for an explicit public override without consulting profiles', async () => {
    routeTables(upsertChains({ visibility_override: 'public' }));

    const entry = await upsertJournalEntry('user-1', '603', {
      title: 'The Matrix',
      reviewText: 'great',
      visibilityOverride: 'public',
    });

    expect(entry).not.toBeNull();
    expect(feedMocks.logReviewActivityEvent).toHaveBeenCalledTimes(1);
    expect(feedMocks.logReviewActivityEvent).toHaveBeenCalledWith('user-1', expect.objectContaining({
      tmdbId: '603',
      body: 'great',
    }));
    expect(tablesCalled()).not.toContain('profiles');
  });

  it('does NOT emit for a friends override even when the profile is public (B6 leak case)', async () => {
    routeTables(upsertChains({ visibility_override: 'friends' }, 'public'));

    const entry = await upsertJournalEntry('user-1', '603', {
      title: 'The Matrix',
      reviewText: 'great',
      visibilityOverride: 'friends',
    });

    expect(entry).not.toBeNull();
    expect(feedMocks.logReviewActivityEvent).not.toHaveBeenCalled();
    // Explicit non-public override short-circuits: no profile lookup needed.
    expect(tablesCalled()).not.toContain('profiles');
  });

  it('emits for a NULL override when the author profile is public', async () => {
    routeTables(upsertChains({}, 'public'));

    const entry = await upsertJournalEntry('user-1', '603', {
      title: 'The Matrix',
      reviewText: 'great',
    });

    expect(entry).not.toBeNull();
    expect(tablesCalled()).toContain('profiles');
    expect(feedMocks.logReviewActivityEvent).toHaveBeenCalledTimes(1);
  });

  it('does NOT emit for a NULL override on a friends-visibility profile (B2-resolved default)', async () => {
    routeTables(upsertChains({}, 'friends'));

    const entry = await upsertJournalEntry('user-1', '603', {
      title: 'The Matrix',
      reviewText: 'great',
    });

    expect(entry).not.toBeNull();
    expect(feedMocks.logReviewActivityEvent).not.toHaveBeenCalled();
  });

  it('fails closed (no event) when the profile lookup returns nothing', async () => {
    routeTables(upsertChains({}, undefined));

    const entry = await upsertJournalEntry('user-1', '603', {
      title: 'The Matrix',
      reviewText: 'great',
    });

    expect(entry).not.toBeNull();
    expect(feedMocks.logReviewActivityEvent).not.toHaveBeenCalled();
  });

  it('never emits (and never fetches profiles) without review text', async () => {
    routeTables(upsertChains());

    const entry = await upsertJournalEntry('user-1', '603', { title: 'The Matrix' });

    expect(entry).not.toBeNull();
    expect(feedMocks.logReviewActivityEvent).not.toHaveBeenCalled();
    expect(tablesCalled()).not.toContain('profiles');
  });
});

// ── Read paths — B5 column exclusion wiring ──────────────────────────────────

describe('journal read paths (B5)', () => {
  it('listJournalEntries (serves other profiles) selects the shared list, never personal_takeaway', async () => {
    const c = chain({ data: [], error: null });
    routeTables({ journal_entries: c });

    await listJournalEntries('user-2');

    const selectArg = c.select.mock.calls[0][0] as string;
    expect(selectArg).not.toMatch(/personal_takeaway/);
    expect(selectArg).not.toBe('*');
    expect(selectArg).toContain(JOURNAL_ENTRY_SHARED_COLUMNS);
    // profile enrichment join stays intact
    expect(selectArg).toContain('profiles!journal_entries_user_id_fkey');
  });

  it('getJournalEntry (owner path) keeps the full row including personal_takeaway', async () => {
    const c = chain({ data: DB_ROW, error: null });
    routeTables({ journal_entries: c });

    await getJournalEntry('user-1', '603');

    expect(c.select).toHaveBeenCalledWith('*');
  });

  it('getJournalEntryById (id-addressed, cross-user capable) selects the shared list', async () => {
    const c = chain({ data: DB_ROW, error: null });
    routeTables({ journal_entries: c });

    await getJournalEntryById('entry-1');

    expect(c.select).toHaveBeenCalledWith(JOURNAL_ENTRY_SHARED_COLUMNS);
  });

  it('getReviewsForMovie selects explicit review columns and reads liked-state from journal_entry_likes', async () => {
    const entries = chain({ data: [{ ...DB_ROW }], error: null });
    const likes = chain({ data: [{ entry_id: 'entry-1' }], error: null });
    routeTables({ journal_entries: entries, journal_entry_likes: likes });

    const reviews = await getReviewsForMovie('603', 'viewer-1');

    expect(entries.select).toHaveBeenCalledWith(REVIEW_ENTRY_COLUMNS);
    expect(tablesCalled()).toContain('journal_entry_likes');
    expect(tablesCalled()).not.toContain('journal_likes');
    expect(reviews).toHaveLength(1);
    expect(reviews[0].isLikedByViewer).toBe(true);
  });

  it('getReviewsByUser selects explicit review columns and reads liked-state from journal_entry_likes', async () => {
    const entries = chain({ data: [{ ...DB_ROW }], error: null });
    const likes = chain({ data: [], error: null });
    routeTables({ journal_entries: entries, journal_entry_likes: likes });

    const reviews = await getReviewsByUser('user-1', 'viewer-1');

    expect(entries.select).toHaveBeenCalledWith(REVIEW_ENTRY_COLUMNS);
    expect(tablesCalled()).toContain('journal_entry_likes');
    expect(tablesCalled()).not.toContain('journal_likes');
    expect(reviews).toHaveLength(1);
    expect(reviews[0].isLikedByViewer).toBe(false);
  });
});

// ── pickEntryForEdit — probe-vs-prop seam for the composer (B5 follow-up) ───
//
// Grid/search edit passes a list/search row as `existingEntry` — those rows
// come from cross-user reads that EXCLUDE owner-only personal_takeaway, and
// the save path is a full-replace upsert: trusting the passed row would
// silently wipe the takeaway. The composer must always probe the owner row
// (getJournalEntry keeps select('*')) and prefer it over the prop.

describe('pickEntryForEdit', () => {
  function entryFixture(overrides: Partial<JournalEntry> = {}): JournalEntry {
    return {
      id: 'entry-1',
      userId: 'user-1',
      tmdbId: '603',
      title: 'The Matrix',
      containsSpoilers: false,
      moodTags: [],
      vibeTags: [],
      favoriteMoments: [],
      standoutPerformances: [],
      watchedWithUserIds: [],
      isRewatch: false,
      photoPaths: [],
      likeCount: 0,
      createdAt: '2026-07-07T00:00:00Z',
      updatedAt: '2026-07-07T00:00:00Z',
      ...overrides,
    } as JournalEntry;
  }

  it('prefers the probed owner row over the passed row — takeaway survives the grid-edit path', () => {
    // The grid/search row lacks personalTakeaway (shared column list / search
    // RPC, audit B5); the owner probe carries it.
    const probed = entryFixture({ personalTakeaway: 'my private takeaway' });
    const fromGrid = entryFixture({ personalTakeaway: undefined });

    const picked = pickEntryForEdit(probed, fromGrid);

    expect(picked).toBe(probed);
    expect(picked?.personalTakeaway).toBe('my private takeaway');
  });

  it('prefers the probed row even when the prop carries a (stale) takeaway', () => {
    const probed = entryFixture({ personalTakeaway: 'fresh' });
    const prop = entryFixture({ personalTakeaway: 'stale' });
    expect(pickEntryForEdit(probed, prop)?.personalTakeaway).toBe('fresh');
  });

  it('falls back to the passed row when the probe returns nothing', () => {
    const prop = entryFixture();
    expect(pickEntryForEdit(null, prop)).toBe(prop);
  });

  it('returns null when there is no entry at all (fresh journal → chat phase)', () => {
    expect(pickEntryForEdit(null, null)).toBeNull();
    expect(pickEntryForEdit(null, undefined)).toBeNull();
  });
});
