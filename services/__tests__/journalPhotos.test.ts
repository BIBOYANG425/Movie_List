import { describe, it, expect, vi, beforeEach } from 'vitest';

// journalService imports the supabase client (needs import.meta.env) at module
// scope (directly and via feedService) — mock it so the pure helpers and the
// signing paths can be exercised in the node test environment. No network.
const mocks = vi.hoisted(() => ({
  from: vi.fn(),
  rpc: vi.fn(),
  storageFrom: vi.fn(),
}));
vi.mock('../../lib/supabase', () => ({
  supabase: { from: mocks.from, rpc: mocks.rpc, storage: { from: mocks.storageFrom } },
}));
vi.mock('../feedService', () => ({ logReviewActivityEvent: vi.fn() }));

import {
  extractJournalPhotoPath,
  getJournalPhotoUrl,
  getJournalPhotoUrls,
  JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS,
} from '../journalService';

const UID = '4f1c2a9e-7b3d-4e5f-8a6b-9c0d1e2f3a4b';
const ENTRY = 'e57850c0-1111-2222-3333-444455556666';
const PATH = `${UID}/${ENTRY}/0.jpg`;
const BASE = 'https://abcdefghij.supabase.co';

beforeEach(() => {
  vi.clearAllMocks();
});

// ── Pure: legacy-URL → path extraction (audit B4) ───────────────────────────

describe('extractJournalPhotoPath', () => {
  it('passes a plain storage path through unchanged', () => {
    expect(extractJournalPhotoPath(PATH)).toBe(PATH);
  });

  it('trims whitespace and strips leading slashes from a stored path', () => {
    expect(extractJournalPhotoPath(`  /${PATH} `)).toBe(PATH);
  });

  it('extracts the path from a legacy public object URL', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/journal-photos/${PATH}`),
    ).toBe(PATH);
  });

  it('strips a query string from a legacy public URL', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/journal-photos/${PATH}?t=1700000000`),
    ).toBe(PATH);
  });

  it('extracts the path from a previously signed URL and drops its token', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/sign/journal-photos/${PATH}?token=eyJhbGciOi.abc.def`),
    ).toBe(PATH);
  });

  it('extracts the path from an authenticated object URL', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/authenticated/journal-photos/${PATH}`),
    ).toBe(PATH);
  });

  it('extracts the path from a render/image transformation URL', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/render/image/public/journal-photos/${PATH}?width=300`),
    ).toBe(PATH);
  });

  it('decodes percent-encoded segments in a legacy URL', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/journal-photos/${UID}/${ENTRY}/0.My%20Photo`),
    ).toBe(`${UID}/${ENTRY}/0.My Photo`);
  });

  it('splits on the FIRST bucket marker when the bucket name recurs inside the path', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/journal-photos/${UID}/journal-photos/0.jpg`),
    ).toBe(`${UID}/journal-photos/0.jpg`);
  });

  it('treats a plain path containing a journal-photos folder as a path, not a URL', () => {
    expect(extractJournalPhotoPath(`${UID}/journal-photos/0.jpg`)).toBe(`${UID}/journal-photos/0.jpg`);
  });

  it('returns null for a URL from a different bucket', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/avatars/${UID}/avatar.png`),
    ).toBeNull();
  });

  it('returns null for an arbitrary URL without the storage marker', () => {
    expect(extractJournalPhotoPath('https://example.com/some/image.jpg')).toBeNull();
  });

  it('returns null for a URL where nothing follows the bucket marker', () => {
    expect(
      extractJournalPhotoPath(`${BASE}/storage/v1/object/public/journal-photos/`),
    ).toBeNull();
  });

  it('returns null for empty and whitespace-only input', () => {
    expect(extractJournalPhotoPath('')).toBeNull();
    expect(extractJournalPhotoPath('   ')).toBeNull();
  });
});

// ── TTL constant (adjudicated: 30 days, re-signed on render) ────────────────

describe('JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS', () => {
  it('is 30 days in seconds', () => {
    expect(JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS).toBe(30 * 24 * 60 * 60);
  });
});

// ── Signing wrappers (mocked storage; assert bucket, path, TTL) ─────────────

function storageApi(overrides: Record<string, unknown> = {}) {
  const api = {
    createSignedUrl: vi.fn(async (path: string) => ({
      data: { signedUrl: `${BASE}/storage/v1/object/sign/journal-photos/${path}?token=tok` },
      error: null,
    })),
    createSignedUrls: vi.fn(async (paths: string[]) => ({
      data: paths.map((p) => ({
        error: null,
        path: p,
        signedUrl: `${BASE}/storage/v1/object/sign/journal-photos/${p}?token=tok`,
      })),
      error: null,
    })),
    ...overrides,
  };
  mocks.storageFrom.mockReturnValue(api);
  return api;
}

describe('getJournalPhotoUrl', () => {
  it('signs a stored path against the journal-photos bucket with the 30-day TTL', async () => {
    const api = storageApi();
    const url = await getJournalPhotoUrl(PATH);
    expect(mocks.storageFrom).toHaveBeenCalledWith('journal-photos');
    expect(api.createSignedUrl).toHaveBeenCalledWith(PATH, JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS);
    expect(url).toContain('/object/sign/journal-photos/');
  });

  it('converts a legacy public URL to its path before signing', async () => {
    const api = storageApi();
    await getJournalPhotoUrl(`${BASE}/storage/v1/object/public/journal-photos/${PATH}`);
    expect(api.createSignedUrl).toHaveBeenCalledWith(PATH, JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS);
  });

  it('returns null for an unsignable input without touching storage', async () => {
    storageApi();
    const url = await getJournalPhotoUrl('https://example.com/not-ours.jpg');
    expect(url).toBeNull();
    expect(mocks.storageFrom).not.toHaveBeenCalled();
  });

  it('returns null when signing fails', async () => {
    storageApi({
      createSignedUrl: vi.fn(async () => ({ data: null, error: { message: 'not found' } })),
    });
    expect(await getJournalPhotoUrl(PATH)).toBeNull();
  });
});

describe('getJournalPhotoUrls', () => {
  it('signs many photos in ONE batch call and keys the map by the ORIGINAL inputs', async () => {
    const api = storageApi();
    const legacy = `${BASE}/storage/v1/object/public/journal-photos/${UID}/${ENTRY}/1.png`;
    const map = await getJournalPhotoUrls([PATH, legacy]);

    expect(api.createSignedUrls).toHaveBeenCalledTimes(1);
    expect(api.createSignedUrls).toHaveBeenCalledWith(
      [PATH, `${UID}/${ENTRY}/1.png`],
      JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS,
    );
    expect(map.get(PATH)).toContain(`/object/sign/journal-photos/${PATH}`);
    expect(map.get(legacy)).toContain(`/object/sign/journal-photos/${UID}/${ENTRY}/1.png`);
  });

  it('omits per-item failures but keeps the successful entries', async () => {
    storageApi({
      createSignedUrls: vi.fn(async (paths: string[]) => ({
        data: paths.map((p, i) => (i === 0
          ? { error: 'Object not found', path: null, signedUrl: '' }
          : { error: null, path: p, signedUrl: `${BASE}/sign/${p}` })),
        error: null,
      })),
    });
    const other = `${UID}/${ENTRY}/1.png`;
    const map = await getJournalPhotoUrls([PATH, other]);
    expect(map.has(PATH)).toBe(false);
    expect(map.get(other)).toBe(`${BASE}/sign/${other}`);
  });

  it('skips unsignable inputs while still batch-signing the rest (alignment preserved)', async () => {
    const api = storageApi();
    const map = await getJournalPhotoUrls(['https://example.com/junk.jpg', PATH]);
    expect(api.createSignedUrls).toHaveBeenCalledWith([PATH], JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS);
    expect(map.size).toBe(1);
    expect(map.get(PATH)).toContain(PATH);
  });

  it('returns an empty map for empty input without touching storage', async () => {
    storageApi();
    const map = await getJournalPhotoUrls([]);
    expect(map.size).toBe(0);
    expect(mocks.storageFrom).not.toHaveBeenCalled();
  });

  it('returns an empty map when the batch call fails outright', async () => {
    storageApi({
      createSignedUrls: vi.fn(async () => ({ data: null, error: { message: 'boom' } })),
    });
    const map = await getJournalPhotoUrls([PATH]);
    expect(map.size).toBe(0);
  });
});
