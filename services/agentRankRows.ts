// services/agentRankRows.ts
//
// user_rankings row → RankedItem mapping for the /agent-rank route.
//
// This is the EXACT mirror of RankingAppPage.rowToRankedItem — extracted so the
// agent ceremony seeds from the same field set the main webapp seeds from, and
// so a unit test can lock the parity. The /agent-rank page previously kept a
// local copy that DROPPED watched_with_user_ids; because the placement upsert
// writes `watched_with_user_ids: placed.watchedWithUserIds ?? []`, a re-rank
// through the card silently wiped the user's companions. One mapper, tested,
// ends that fork.
//
// The single intentional difference from the webapp mapper: `type` falls back
// to 'movie' when the row predates the type column — the card only ever seeds
// the movie ceremony, and a null type would fail the NOT NULL write-back.
//
// Header last reviewed: 2026-07-13

import { RankedItem, Tier, Bracket, MediaType } from '../types';
import { classifyBracket } from './rankingAlgorithm';

export function rowToRankedItem(row: any): RankedItem {
  const wwIds = row.watched_with_user_ids;
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: (row.type as MediaType) ?? 'movie',
    genres: row.genres ?? [],
    director: row.director ?? undefined,
    tier: row.tier as Tier,
    rank: row.rank_position,
    bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
    notes: row.notes ?? undefined,
    watchedWithUserIds: Array.isArray(wwIds) && wwIds.length > 0 ? wwIds : undefined,
  };
}
