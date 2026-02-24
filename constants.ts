import { Tier, Bracket, RankedItem } from './types';

export const TIERS = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];

export const TIER_COLORS = {
  [Tier.S]: 'text-yellow-400 border-yellow-400/20 bg-yellow-400/5',
  [Tier.A]: 'text-green-400 border-green-400/20 bg-green-400/5',
  [Tier.B]: 'text-blue-400 border-blue-400/20 bg-blue-400/5',
  [Tier.C]: 'text-zinc-400 border-zinc-400/20 bg-zinc-400/5',
  [Tier.D]: 'text-red-400 border-red-400/20 bg-red-400/5',
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
