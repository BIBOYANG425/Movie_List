import { Tier, EnginePhase } from '../types';
import { TIER_COMPARISON_PROMPTS, GENRE_COMPARISON_PROMPTS } from '../constants';

/** Tiers where genre-specific prompts add emotional value */
const GENRE_PROMPT_TIERS = new Set<Tier>([Tier.S, Tier.A, Tier.B]);

/**
 * Pick the emotional comparison prompt based on tier, genres, and phase.
 *
 * Rules:
 * - Cross-genre phase → always tier prompt (movies are different genres)
 * - Same genre + genre has a prompt + tier is S/A/B → genre prompt
 * - Otherwise → tier prompt (C/D tiers always use tier prompt)
 */
export function getComparisonPrompt(
  tier: Tier,
  genreA: string,
  genreB: string,
  phase: EnginePhase,
): string {
  const tierPrompt = TIER_COMPARISON_PROMPTS[tier];

  if (phase === 'cross_genre') return tierPrompt;

  if (
    GENRE_PROMPT_TIERS.has(tier) &&
    genreA === genreB &&
    genreA in GENRE_COMPARISON_PROMPTS
  ) {
    return GENRE_COMPARISON_PROMPTS[genreA];
  }

  return tierPrompt;
}
