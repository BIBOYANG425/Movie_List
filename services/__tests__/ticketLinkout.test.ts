import { describe, it, expect } from 'vitest';
import { ticketLinkout } from '../../lib/ticketLinkout';

// The single ticketing-linkout module for /agent-showtimes time chips (S2b).
// A future affiliate wrap changes only lib/ticketLinkout.ts; these tests pin the
// current Fandango-search behavior so the swap is visible in the diff.

describe('ticketLinkout', () => {
  it('builds a Fandango title-search URL', () => {
    expect(ticketLinkout('Dune')).toBe('https://www.fandango.com/search?q=Dune');
  });

  it('URI-encodes spaces and punctuation in the title', () => {
    expect(ticketLinkout('Dune: Part Two')).toBe(
      'https://www.fandango.com/search?q=Dune%3A%20Part%20Two',
    );
  });

  it('encodes ampersands so they do not split the query', () => {
    expect(ticketLinkout('Fast & Furious')).toBe(
      'https://www.fandango.com/search?q=Fast%20%26%20Furious',
    );
  });

  it('handles an empty title without throwing', () => {
    expect(ticketLinkout('')).toBe('https://www.fandango.com/search?q=');
  });
});
