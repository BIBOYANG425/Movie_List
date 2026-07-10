import { describe, it, expect } from 'vitest';
import {
  allowPath,
  sanitizeQuery,
} from '../../supabase/functions/tmdb-proxy/rules';

// Imports the SAME rules.ts that supabase/functions/tmdb-proxy/index.ts uses.
// rules.ts is import-clean (no Deno globals) so vitest compiles it directly.

// ── allowPath: every allowlist entry accepted ────────────────────────────────

describe('allowPath — allowlist entries accepted', () => {
  const accepted = [
    'search/movie',
    'search/tv',
    'search/person',
    'movie/603',
    'movie/603/similar',
    'movie/603/recommendations',
    'tv/1399',
    'tv/1399/season/1',
    'tv/1399/season/12',
    'person/287',
    'person/287/movie_credits',
    'trending/movie/day',
    'trending/movie/week',
    'trending/tv/day',
    'trending/tv/week',
    'discover/movie',
    'discover/tv',
    'movie/now_playing',
    'movie/upcoming',
  ];

  for (const p of accepted) {
    it(`accepts ${p}`, () => {
      expect(allowPath(p)).toBe(true);
    });
  }

  it('accepts a leading slash form', () => {
    expect(allowPath('/search/movie')).toBe(true);
  });
});

// ── allowPath: non-allowlisted rejected ──────────────────────────────────────

describe('allowPath — non-allowlisted rejected', () => {
  const rejected = [
    'configuration',
    'account',
    'authentication/token/new',
    'movie/603/account_states',
    'movie/603/reviews',
    'tv/1399/credits',
    'person/287/tagged_images',
    'list/1',
    'collection/10',
    'company/1',
    'keyword/1/movies',
    'genre/movie/list',
    'trending/all/day', // media_type must be movie|tv
    'trending/movie/year', // time_window must be day|week
    'trending/person/week',
    'movie', // bare, no id
    'tv', // bare, no id
    'movie/now_showing', // not now_playing/upcoming
    'movie/latest',
    'search/multi', // only movie|tv|person
    'search/company',
    'tv/1399/season', // needs season number
    'tv/1399/season/x', // non-numeric season
    'person/287/tv_credits', // only movie_credits allowlisted
    '',
    '/',
  ];

  for (const p of rejected) {
    it(`rejects ${p}`, () => {
      expect(allowPath(p)).toBe(false);
    });
  }
});

// ── allowPath: id must be numeric ────────────────────────────────────────────

describe('allowPath — id shape enforced', () => {
  it('rejects non-numeric movie id', () => {
    expect(allowPath('movie/abc')).toBe(false);
  });
  it('rejects non-numeric tv id', () => {
    expect(allowPath('tv/abc/season/1')).toBe(false);
  });
  it('rejects non-numeric person id', () => {
    expect(allowPath('person/abc/movie_credits')).toBe(false);
  });
  it('accepts multi-digit ids', () => {
    expect(allowPath('movie/1234567')).toBe(true);
  });
});

// ── allowPath: traversal / encoded-slash / absolute rejected ─────────────────

describe('allowPath — traversal and smuggling rejected', () => {
  const attacks = [
    '../3/account',
    'movie/603/../../account',
    'movie/../../etc/passwd',
    'movie/603/%2e%2e/account', // encoded dot-dot
    'movie/603%2F..%2F..', // encoded slash
    'movie/603%2Faccount', // encoded slash smuggle
    'search%2Fmovie', // fully encoded path
    'http://evil.com/movie/603', // absolute URL
    'https://api.themoviedb.org/3/account', // absolute URL
    '//evil.com/movie/603', // protocol-relative
    '\\evil', // backslash
    'movie/603\\..\\account', // backslash traversal
    'movie/603?x=1', // query smuggled into path
    'movie/603#frag', // fragment smuggled
    'movie/6 03', // whitespace
    'movie/603/similar/..', // trailing traversal
    'movie/603/', // trailing slash (non-canonical)
  ];

  for (const p of attacks) {
    it(`rejects ${p}`, () => {
      expect(allowPath(p)).toBe(false);
    });
  }
});

// ── sanitizeQuery: param safelist ────────────────────────────────────────────

describe('sanitizeQuery — safelist pass-through', () => {
  it('keeps safelisted params', () => {
    const out = sanitizeQuery(
      new URLSearchParams({
        query: 'matrix',
        page: '2',
        language: 'en-US',
        include_adult: 'false',
        year: '1999',
        primary_release_year: '1999',
        with_genres: '28,12',
        sort_by: 'popularity.desc',
        region: 'US',
      }),
    );
    expect(out.get('query')).toBe('matrix');
    expect(out.get('page')).toBe('2');
    expect(out.get('language')).toBe('en-US');
    expect(out.get('include_adult')).toBe('false');
    expect(out.get('year')).toBe('1999');
    expect(out.get('primary_release_year')).toBe('1999');
    expect(out.get('with_genres')).toBe('28,12');
    expect(out.get('sort_by')).toBe('popularity.desc');
    expect(out.get('region')).toBe('US');
  });

  it('keeps dotted numeric-filter params', () => {
    const out = sanitizeQuery(
      new URLSearchParams({
        'vote_count.gte': '100',
        'vote_average.gte': '7',
        'primary_release_date.gte': '2020-01-01',
        'primary_release_date.lte': '2023-12-31',
        'first_air_date.gte': '2020-01-01',
        'first_air_date.lte': '2023-12-31',
      }),
    );
    expect(out.get('vote_count.gte')).toBe('100');
    expect(out.get('vote_average.gte')).toBe('7');
    expect(out.get('primary_release_date.gte')).toBe('2020-01-01');
    expect(out.get('primary_release_date.lte')).toBe('2023-12-31');
    expect(out.get('first_air_date.gte')).toBe('2020-01-01');
    expect(out.get('first_air_date.lte')).toBe('2023-12-31');
  });

  it('strips api_key (client never sends it; function injects it)', () => {
    const out = sanitizeQuery(
      new URLSearchParams({ query: 'matrix', api_key: 'evil-key' }),
    );
    expect(out.has('api_key')).toBe(false);
    expect(out.get('query')).toBe('matrix');
  });

  it('strips unknown / dangerous params', () => {
    const out = sanitizeQuery(
      new URLSearchParams({
        query: 'matrix',
        session_id: 'abc',
        account_id: '1',
        callback: 'x',
        __proto__: 'y',
        path: 'other',
      }),
    );
    expect(out.get('query')).toBe('matrix');
    expect(out.has('session_id')).toBe(false);
    expect(out.has('account_id')).toBe(false);
    expect(out.has('callback')).toBe(false);
    expect(out.has('path')).toBe(false);
  });

  it('preserves values verbatim (URL-encoding happens on rebuild via toString)', () => {
    const out = sanitizeQuery(new URLSearchParams({ query: 'the matrix & co' }));
    expect(out.get('query')).toBe('the matrix & co');
    // toString re-encodes safely
    expect(out.toString()).toContain('query=the+matrix+%26+co');
  });
});

// ── sanitizeQuery: append_to_response restriction ────────────────────────────

describe('sanitizeQuery — append_to_response restricted', () => {
  it('keeps the full allowed combo', () => {
    const out = sanitizeQuery(
      new URLSearchParams({ append_to_response: 'watch/providers,credits' }),
    );
    expect(out.get('append_to_response')).toBe('watch/providers,credits');
  });

  it('keeps a single allowed value', () => {
    expect(
      sanitizeQuery(
        new URLSearchParams({ append_to_response: 'credits' }),
      ).get('append_to_response'),
    ).toBe('credits');
    expect(
      sanitizeQuery(
        new URLSearchParams({ append_to_response: 'watch/providers' }),
      ).get('append_to_response'),
    ).toBe('watch/providers');
  });

  it('accepts reversed order combo', () => {
    expect(
      sanitizeQuery(
        new URLSearchParams({ append_to_response: 'credits,watch/providers' }),
      ).get('append_to_response'),
    ).toBe('credits,watch/providers');
  });

  it('drops append_to_response with a disallowed value', () => {
    const out = sanitizeQuery(
      new URLSearchParams({ append_to_response: 'credits,images,videos' }),
    );
    expect(out.has('append_to_response')).toBe(false);
  });

  it('drops append_to_response that smuggles a non-allowed sub-path', () => {
    const out = sanitizeQuery(
      new URLSearchParams({ append_to_response: 'account_states' }),
    );
    expect(out.has('append_to_response')).toBe(false);
  });
});
