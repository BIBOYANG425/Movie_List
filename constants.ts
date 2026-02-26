import { Tier, Bracket, RankedItem, MoodTagDef, VibeTagDef, MoodCategory, SuggestionPoolType } from './types';

export const TIERS = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];

export const TIER_COLORS = {
  [Tier.S]: 'text-tier-s border-tier-s/20 bg-tier-s/5',
  [Tier.A]: 'text-tier-a border-tier-a/20 bg-tier-a/5',
  [Tier.B]: 'text-tier-b border-tier-b/20 bg-tier-b/5',
  [Tier.C]: 'text-tier-c border-tier-c/20 bg-tier-c/5',
  [Tier.D]: 'text-tier-d border-tier-d/20 bg-tier-d/5',
};

export const TIER_LABELS = {
  [Tier.S]: 'Masterpiece',
  [Tier.A]: 'Excellent',
  [Tier.B]: 'Good',
  [Tier.C]: 'Mediocre',
  [Tier.D]: 'Poor',
};

export const TIER_USER_PROMPTS = {
  [Tier.S]: 'All-time great. Would rewatch endlessly.',
  [Tier.A]: 'Loved it. Highly recommend.',
  [Tier.B]: 'Enjoyed it. Solid watch.',
  [Tier.C]: 'It was fine. Wouldn\'t rush to rewatch.',
  [Tier.D]: 'Didn\'t enjoy it. Would not recommend.',
};

export const TIER_SCORE_RANGES = {
  [Tier.S]: { min: 9.0, max: 10.0 },
  [Tier.A]: { min: 7.0, max: 8.9 },
  [Tier.B]: { min: 5.0, max: 6.9 },
  [Tier.C]: { min: 3.0, max: 4.9 },
  [Tier.D]: { min: 0.1, max: 2.9 },
};

export const BRACKETS: Bracket[] = [
  Bracket.Commercial,
  Bracket.Artisan,
  Bracket.Documentary,
  Bracket.Animation,
];

export const BRACKET_LABELS: Record<Bracket, string> = {
  [Bracket.Commercial]: 'Commercial',
  [Bracket.Artisan]: 'Artisan / Indie',
  [Bracket.Documentary]: 'Documentary',
  [Bracket.Animation]: 'Animation',
};

/** Scores are hidden until the user has ranked at least this many movies. */
export const MIN_MOVIES_FOR_SCORES = 10;

/**
 * Sticky-tier tolerance (maximum). Actual tolerance scales down as the list
 * grows: tolerance = MAX_TIER_TOLERANCE × (MIN_MOVIES_FOR_SCORES / totalMovies),
 * capped at MAX_TIER_TOLERANCE. With 10 movies → 2.0, 20 → 1.0, 50 → 0.4, etc.
 */
export const MAX_TIER_TOLERANCE = 2.0;

export const LANDING_FEATURED_IDS = [
  'tmdb_693134',
  'tmdb_496243',
  'tmdb_545611',
  'tmdb_76341',
];

// Initial Seed Data
export const INITIAL_RANKINGS: RankedItem[] = [
  {
    id: 'tmdb_693134',
    title: 'Dune: Part Two',
    year: '2024',
    posterUrl: 'https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg',
    type: 'movie',
    genres: ['Sci-Fi', 'Adventure'],
    director: 'Denis Villeneuve',
    tier: Tier.S,
    rank: 0
  },
  {
    id: 'tmdb_496243',
    title: 'Parasite',
    year: '2019',
    posterUrl: 'https://image.tmdb.org/t/p/w500/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg',
    type: 'movie',
    genres: ['Thriller', 'Drama'],
    director: 'Bong Joon-ho',
    tier: Tier.A,
    rank: 0
  },
  {
    id: 'tmdb_545611',
    title: 'Everything Everywhere All At Once',
    year: '2022',
    posterUrl: 'https://image.tmdb.org/t/p/w500/w3LxiVYdWWRvEVdn5RYq6jIqkb1.jpg',
    type: 'movie',
    genres: ['Sci-Fi', 'Action'],
    tier: Tier.A,
    rank: 1
  },
  {
    id: 'tmdb_446807',
    title: 'Cats',
    year: '2019',
    posterUrl: 'https://image.tmdb.org/t/p/w500/xXBnM6uSTk6qqCf0SRZKXcga9Ba.jpg',
    type: 'movie',
    genres: ['Musical', 'Horror?'],
    tier: Tier.D,
    rank: 0
  },
  {
    id: 'tmdb_76341',
    title: 'Mad Max: Fury Road',
    year: '2015',
    posterUrl: 'https://image.tmdb.org/t/p/w500/8tZYtuWezp8JbcsvHYO0O46tFbo.jpg',
    type: 'movie',
    genres: ['Action', 'Sci-Fi'],
    tier: Tier.S,
    rank: 1
  }
];

export const MOCK_SEARCH_RESULTS: RankedItem[] = [
  {
    id: 'tmdb_238',
    title: 'The Godfather',
    year: '1972',
    posterUrl: 'https://image.tmdb.org/t/p/w500/3bhkrj58Vtu7enYsRolD1fZdja1.jpg',
    type: 'movie',
    genres: ['Crime', 'Drama'],
    tier: Tier.B, // Default placeholder
    rank: 0
  },
  {
    id: 'tmdb_157336',
    title: 'Interstellar',
    year: '2014',
    posterUrl: 'https://image.tmdb.org/t/p/w500/gEU2QniL6C8ztDDXLOx9TpBomvs.jpg',
    type: 'movie',
    genres: ['Sci-Fi', 'Drama'],
    tier: Tier.B,
    rank: 0
  }
];

// ── Journal Constants ───────────────────────────────────────────────────────

export const MOOD_CATEGORIES: { id: MoodCategory; label: string }[] = [
  { id: 'positive', label: 'Positive' },
  { id: 'reflective', label: 'Reflective' },
  { id: 'intense', label: 'Intense' },
  { id: 'light', label: 'Light' },
];

export const MOOD_TAGS: MoodTagDef[] = [
  // Positive
  { id: 'inspired', label: 'Inspired', emoji: '\u2728', category: 'positive' },
  { id: 'joyful', label: 'Joyful', emoji: '\uD83D\uDE04', category: 'positive' },
  { id: 'thrilled', label: 'Thrilled', emoji: '\uD83E\uDD29', category: 'positive' },
  { id: 'moved', label: 'Moved', emoji: '\uD83E\uDEF6', category: 'positive' },
  { id: 'amazed', label: 'Amazed', emoji: '\uD83E\uDD2F', category: 'positive' },
  { id: 'comforted', label: 'Comforted', emoji: '\uD83E\uDEF2', category: 'positive' },
  { id: 'hopeful', label: 'Hopeful', emoji: '\uD83C\uDF1F', category: 'positive' },
  // Reflective
  { id: 'thoughtful', label: 'Thoughtful', emoji: '\uD83E\uDD14', category: 'reflective' },
  { id: 'nostalgic', label: 'Nostalgic', emoji: '\uD83D\uDCF7', category: 'reflective' },
  { id: 'melancholy', label: 'Melancholy', emoji: '\uD83C\uDF27\uFE0F', category: 'reflective' },
  { id: 'haunted', label: 'Haunted', emoji: '\uD83D\uDC7B', category: 'reflective' },
  { id: 'contemplative', label: 'Contemplative', emoji: '\uD83E\uDDD8', category: 'reflective' },
  // Intense
  { id: 'tense', label: 'Tense', emoji: '\uD83D\uDE2C', category: 'intense' },
  { id: 'disturbed', label: 'Disturbed', emoji: '\uD83D\uDE16', category: 'intense' },
  { id: 'heartbroken', label: 'Heartbroken', emoji: '\uD83D\uDC94', category: 'intense' },
  { id: 'angry', label: 'Angry', emoji: '\uD83D\uDE21', category: 'intense' },
  { id: 'overwhelmed', label: 'Overwhelmed', emoji: '\uD83E\uDD75', category: 'intense' },
  { id: 'exhausted', label: 'Exhausted', emoji: '\uD83D\uDE35', category: 'intense' },
  // Light
  { id: 'amused', label: 'Amused', emoji: '\uD83D\uDE02', category: 'light' },
  { id: 'charmed', label: 'Charmed', emoji: '\uD83D\uDE0A', category: 'light' },
  { id: 'entertained', label: 'Entertained', emoji: '\uD83C\uDF7F', category: 'light' },
  { id: 'relaxed', label: 'Relaxed', emoji: '\uD83D\uDE0C', category: 'light' },
  { id: 'satisfied', label: 'Satisfied', emoji: '\uD83D\uDE0C', category: 'light' },
];

export const VIBE_TAGS: VibeTagDef[] = [
  { id: 'solo_watch', label: 'Solo watch', emoji: '\uD83E\uDDD1' },
  { id: 'date_night', label: 'Date night', emoji: '\u2764\uFE0F' },
  { id: 'movie_night', label: 'Movie night', emoji: '\uD83C\uDF7F' },
  { id: 'family_time', label: 'Family time', emoji: '\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66' },
  { id: 'theater', label: 'Theater experience', emoji: '\uD83C\uDFA6' },
  { id: 'cozy_night', label: 'Cozy night in', emoji: '\uD83D\uDECB\uFE0F' },
  { id: 'binge', label: 'Binge session', emoji: '\uD83D\uDCFA' },
  { id: 'rewatch', label: 'Rewatch', emoji: '\uD83D\uDD01' },
  { id: 'blind_watch', label: 'Blind watch', emoji: '\uD83D\uDE48' },
  { id: 'late_night', label: 'Late night', emoji: '\uD83C\uDF19' },
  { id: 'travel', label: 'Travel watch', emoji: '\u2708\uFE0F' },
];

export const PLATFORM_OPTIONS: { id: string; label: string }[] = [
  { id: 'theater', label: 'Theater' },
  { id: 'netflix', label: 'Netflix' },
  { id: 'apple_tv', label: 'Apple TV+' },
  { id: 'max', label: 'Max' },
  { id: 'hulu', label: 'Hulu' },
  { id: 'prime', label: 'Prime Video' },
  { id: 'disney', label: 'Disney+' },
  { id: 'peacock', label: 'Peacock' },
  { id: 'paramount', label: 'Paramount+' },
  { id: 'mubi', label: 'Mubi' },
  { id: 'criterion', label: 'Criterion Channel' },
  { id: 'physical', label: 'Physical media' },
  { id: 'other', label: 'Other' },
];

export const JOURNAL_REVIEW_PROMPTS: Record<Tier, string> = {
  [Tier.S]: 'What makes this an all-time great?',
  [Tier.A]: 'What did you love about this one?',
  [Tier.B]: 'What stood out to you?',
  [Tier.C]: 'What could have been better?',
  [Tier.D]: 'What went wrong for you?',
};

export const JOURNAL_TAKEAWAY_PROMPTS: Record<Tier, string> = {
  [Tier.S]: 'How did this change your perspective?',
  [Tier.A]: 'What will you remember most?',
  [Tier.B]: 'Any thoughts you want to hold onto?',
  [Tier.C]: 'Anything redeeming you want to note?',
  [Tier.D]: 'Any lessons or silver linings?',
};

export const JOURNAL_PHOTO_BUCKET = 'journal-photos';
export const JOURNAL_PHOTO_MAX_BYTES = 5 * 1024 * 1024; // 5MB
export const JOURNAL_MAX_PHOTOS = 6;
export const JOURNAL_MAX_MOMENTS = 5;

// ── Smart Suggestions ─────────────────────────────────────────────────────────

export const TIER_WEIGHTS: Record<Tier, number> = {
  [Tier.S]: 5,
  [Tier.A]: 4,
  [Tier.B]: 3,
  [Tier.C]: 2,
  [Tier.D]: 1,
};

export const ALL_TMDB_GENRES = [
  'Action', 'Adventure', 'Animation', 'Comedy', 'Crime', 'Documentary',
  'Drama', 'Family', 'Fantasy', 'History', 'Horror', 'Music', 'Mystery',
  'Romance', 'Sci-Fi', 'TV Movie', 'Thriller', 'War', 'Western',
];

/** Default slot distribution for the 5-pool suggestion system */
export const DEFAULT_POOL_SLOTS: Record<SuggestionPoolType, number> = {
  similar: 3,
  taste: 4,
  trending: 2,
  variety: 2,
  friend: 1,
};

/** Minimum rankings before switching from generic to smart suggestions */
export const SMART_SUGGESTION_THRESHOLD = 3;
