import { describe, it, expect } from 'vitest';
import { parseRankFragment, parseMediaId } from '../agentRankFragment';

// The /agent-rank fragment parser (P3-B, task B1). Pure — no window, no fetch —
// so it runs straight in the node test environment. Guards the URL contract the
// agent must compose: `#t=<jwt>&m=<tmdb_603|tv_1396>`.

describe('parseRankFragment — happy paths', () => {
  it('parses a movie fragment with a leading #', () => {
    const parsed = parseRankFragment('#t=abc.def.ghi&m=tmdb_603');
    expect(parsed).toEqual({
      token: 'abc.def.ghi',
      mediaId: 'tmdb_603',
      kind: 'movie',
      tmdbNumericId: 603,
    });
  });

  it('parses a bare param string (no leading #)', () => {
    const parsed = parseRankFragment('t=jwt&m=tmdb_27205');
    expect(parsed?.token).toBe('jwt');
    expect(parsed?.tmdbNumericId).toBe(27205);
    expect(parsed?.kind).toBe('movie');
  });

  it('parses a TV fragment and marks kind tv', () => {
    const parsed = parseRankFragment('#t=jwt&m=tv_1396');
    expect(parsed).toEqual({
      token: 'jwt',
      mediaId: 'tv_1396',
      kind: 'tv',
      tmdbNumericId: 1396,
    });
  });

  it('tolerates the token/media params in any order', () => {
    const parsed = parseRankFragment('#m=tmdb_603&t=jwt');
    expect(parsed?.token).toBe('jwt');
    expect(parsed?.mediaId).toBe('tmdb_603');
  });

  it('preserves a JWT that contains url-safe base64 chars', () => {
    const jwt = 'eyJhbGciOiJ.eyJzdWIiOiIx-_9.sig-nature';
    const parsed = parseRankFragment(`#t=${jwt}&m=tmdb_603`);
    expect(parsed?.token).toBe(jwt);
  });
});

describe('parseRankFragment — null cases (render the friendly state)', () => {
  it('returns null for an empty hash', () => {
    expect(parseRankFragment('')).toBeNull();
    expect(parseRankFragment('#')).toBeNull();
  });

  it('returns null when the token is missing', () => {
    expect(parseRankFragment('#m=tmdb_603')).toBeNull();
  });

  it('returns null when the media id is missing', () => {
    expect(parseRankFragment('#t=jwt')).toBeNull();
  });

  it('returns null for an empty token value', () => {
    expect(parseRankFragment('#t=&m=tmdb_603')).toBeNull();
  });

  it('returns null for an unrecognized media id shape', () => {
    expect(parseRankFragment('#t=jwt&m=book_ol123')).toBeNull();
    expect(parseRankFragment('#t=jwt&m=603')).toBeNull();
    expect(parseRankFragment('#t=jwt&m=tmdb_abc')).toBeNull();
  });
});

describe('parseMediaId', () => {
  it('maps tmdb_<n> to a movie', () => {
    expect(parseMediaId('tmdb_603')).toEqual({ kind: 'movie', tmdbNumericId: 603 });
  });

  it('maps tv_<n> to a tv title', () => {
    expect(parseMediaId('tv_1396')).toEqual({ kind: 'tv', tmdbNumericId: 1396 });
  });

  it('rejects a zero id', () => {
    expect(parseMediaId('tmdb_0')).toBeNull();
  });

  it('rejects unknown prefixes and malformed ids', () => {
    expect(parseMediaId('imdb_tt0133093')).toBeNull();
    expect(parseMediaId('tmdb_')).toBeNull();
    expect(parseMediaId('tv_')).toBeNull();
    expect(parseMediaId('')).toBeNull();
  });
});
