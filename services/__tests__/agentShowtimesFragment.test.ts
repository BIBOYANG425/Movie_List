import { describe, it, expect } from 'vitest';
import { parseShowtimesFragment } from '../agentShowtimesFragment';

// The /agent-showtimes fragment parser (S2b). Pure — no window, no fetch — so it
// runs straight in the node test env. Guards the URL contract the agent
// composes: `#c=<uuid>` (the card row id, no JWT).

const UUID = '11111111-2222-4333-8444-555555555555';

describe('parseShowtimesFragment — happy paths', () => {
  it('parses a card fragment with a leading #', () => {
    expect(parseShowtimesFragment(`#c=${UUID}`)).toEqual({ cardId: UUID });
  });

  it('parses a bare param string (no leading #)', () => {
    expect(parseShowtimesFragment(`c=${UUID}`)).toEqual({ cardId: UUID });
  });

  it('accepts a uuid regardless of case', () => {
    const upper = UUID.toUpperCase();
    expect(parseShowtimesFragment(`#c=${upper}`)).toEqual({ cardId: upper });
  });

  it('ignores extra params and reads c', () => {
    expect(parseShowtimesFragment(`#foo=bar&c=${UUID}`)).toEqual({ cardId: UUID });
  });
});

describe('parseShowtimesFragment — null cases (render the friendly state)', () => {
  it('returns null for an empty hash', () => {
    expect(parseShowtimesFragment('')).toBeNull();
    expect(parseShowtimesFragment('#')).toBeNull();
  });

  it('returns null when c is missing', () => {
    expect(parseShowtimesFragment('#t=jwt')).toBeNull();
  });

  it('returns null for an empty c value', () => {
    expect(parseShowtimesFragment('#c=')).toBeNull();
  });

  it('returns null for a non-uuid c value', () => {
    expect(parseShowtimesFragment('#c=not-a-uuid')).toBeNull();
    expect(parseShowtimesFragment('#c=12345')).toBeNull();
    expect(parseShowtimesFragment(`#c=${UUID}-extra`)).toBeNull();
  });
});
