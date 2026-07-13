import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { rowToRankedItem } from '../agentRankRows';
import { Tier, Bracket } from '../../types';

// MAPPER PARITY for the /agent-rank route.
//
// The defect (owner, 2026-07-13): AgentRankPage kept a local copy of
// RankingAppPage.rowToRankedItem that dropped watched_with_user_ids. The
// placement upsert writes `watched_with_user_ids: placed.watchedWithUserIds ?? []`,
// so every re-rank through the iMessage card wiped the user's companions.
// These tests lock the shared mapper to the webapp's field set.

const FULL_ROW = {
  tmdb_id: 'tmdb_120',
  title: 'The Lord of the Rings: The Two Towers',
  year: '2002',
  poster_url: 'https://image.tmdb.org/t/p/w500/two-towers.jpg',
  type: 'movie',
  genres: ['Adventure', 'Fantasy', 'Action'],
  director: 'Peter Jackson',
  tier: 'S',
  rank_position: 1,
  bracket: 'Commercial',
  notes: 'the power of friendship man',
  watched_with_user_ids: ['friend-uuid-1', 'friend-uuid-2'],
};

describe('agentRankRows.rowToRankedItem — webapp field parity', () => {
  it('maps every ceremony-relevant field, including watchedWithUserIds', () => {
    const item = rowToRankedItem(FULL_ROW);
    expect(item.id).toBe('tmdb_120');
    expect(item.title).toBe('The Lord of the Rings: The Two Towers');
    expect(item.year).toBe('2002');
    expect(item.posterUrl).toContain('two-towers');
    expect(item.type).toBe('movie');
    expect(item.genres).toEqual(['Adventure', 'Fantasy', 'Action']);
    expect(item.director).toBe('Peter Jackson');
    expect(item.tier).toBe(Tier.S);
    expect(item.rank).toBe(1);
    expect(item.bracket).toBe(Bracket.Commercial);
    expect(item.notes).toBe('the power of friendship man');
    // The field the old local copy dropped — the re-rank wipe regression.
    expect(item.watchedWithUserIds).toEqual(['friend-uuid-1', 'friend-uuid-2']);
  });

  it('empty / missing watched_with_user_ids → undefined (mirrors the webapp mapper)', () => {
    expect(rowToRankedItem({ ...FULL_ROW, watched_with_user_ids: [] }).watchedWithUserIds).toBeUndefined();
    expect(rowToRankedItem({ ...FULL_ROW, watched_with_user_ids: null }).watchedWithUserIds).toBeUndefined();
    const { watched_with_user_ids: _drop, ...withoutWw } = FULL_ROW;
    expect(rowToRankedItem(withoutWw).watchedWithUserIds).toBeUndefined();
  });

  it('bracket falls back to classifyBracket(genres) when the row has none', () => {
    const item = rowToRankedItem({ ...FULL_ROW, bracket: null });
    expect(item.bracket).toBe(Bracket.Commercial);
  });

  it('null-ish optionals normalize the same way the webapp seeds them', () => {
    const item = rowToRankedItem({
      ...FULL_ROW,
      year: null,
      poster_url: null,
      director: null,
      notes: null,
      genres: null,
    });
    expect(item.year).toBe('');
    expect(item.posterUrl).toBe('');
    expect(item.director).toBeUndefined();
    expect(item.notes).toBeUndefined();
    expect(item.genres).toEqual([]);
  });
});

describe('no forked mapper — AgentRankPage consumes the shared one', () => {
  it('AgentRankPage imports rowToRankedItem from services/agentRankRows and keeps no local copy', () => {
    const src = readFileSync(resolve(__dirname, '../../pages/AgentRankPage.tsx'), 'utf8');
    expect(src).toContain("from '../services/agentRankRows'");
    expect(src).not.toMatch(/function\s+rowToRankedItem/);
  });
});
