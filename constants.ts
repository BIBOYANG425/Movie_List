import { Tier, RankedItem } from './types';

export const TIERS = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];

export const TIER_COLORS = {
  [Tier.S]: 'text-yellow-400 border-yellow-400/20 bg-yellow-400/5',
  [Tier.A]: 'text-green-400 border-green-400/20 bg-green-400/5',
  [Tier.B]: 'text-blue-400 border-blue-400/20 bg-blue-400/5',
  [Tier.C]: 'text-zinc-400 border-zinc-400/20 bg-zinc-400/5',
  [Tier.D]: 'text-red-400 border-red-400/20 bg-red-400/5',
};

export const TIER_LABELS = {
  [Tier.S]: 'Masterpiece (God Tier)',
  [Tier.A]: 'Great',
  [Tier.B]: 'Good',
  [Tier.C]: 'Fine',
  [Tier.D]: 'Bad',
};

export const TIER_SCORE_RANGES = {
  [Tier.S]: { min: 9.5, max: 10.0 },
  [Tier.A]: { min: 8.0, max: 9.4 },
  [Tier.B]: { min: 6.0, max: 7.9 },
  [Tier.C]: { min: 4.0, max: 5.9 },
  [Tier.D]: { min: 1.0, max: 3.9 },
};

// Initial Seed Data
export const INITIAL_RANKINGS: RankedItem[] = [
  {
    id: '1',
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
    id: '2',
    title: 'Hamilton',
    year: '2015',
    posterUrl: 'https://upload.wikimedia.org/wikipedia/en/8/83/Hamilton-poster.jpg',
    type: 'theater',
    genres: ['Musical', 'History'],
    director: 'Thomas Kail',
    tier: Tier.S,
    rank: 1
  },
  {
    id: '3',
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
    id: '4',
    title: 'Everything Everywhere All At Once',
    year: '2022',
    posterUrl: 'https://image.tmdb.org/t/p/w500/w3LxiVYdWWRvEVdn5RYq6jIqkb1.jpg',
    type: 'movie',
    genres: ['Sci-Fi', 'Action'],
    tier: Tier.A,
    rank: 1
  },
  {
    id: '5',
    title: 'Cats',
    year: '2019',
    posterUrl: 'https://image.tmdb.org/t/p/w500/xXBnM6uSTk6qqCf0SRZKXcga9Ba.jpg',
    type: 'movie',
    genres: ['Musical', 'Horror?'],
    tier: Tier.D,
    rank: 0
  },
    {
    id: '6',
    title: 'Mad Max: Fury Road',
    year: '2015',
    posterUrl: 'https://image.tmdb.org/t/p/w500/8tZYtuWezp8JbcsvHYO0O46tFbo.jpg',
    type: 'movie',
    genres: ['Action', 'Sci-Fi'],
    tier: Tier.S,
    rank: 2
  }
];

export const MOCK_SEARCH_RESULTS: RankedItem[] = [
  {
    id: '101',
    title: 'The Godfather',
    year: '1972',
    posterUrl: 'https://image.tmdb.org/t/p/w500/3bhkrj58Vtu7enYsRolD1fZdja1.jpg',
    type: 'movie',
    genres: ['Crime', 'Drama'],
    tier: Tier.B, // Default placeholder
    rank: 0
  },
  {
    id: '102',
    title: 'Wicked',
    year: '2003',
    posterUrl: 'https://upload.wikimedia.org/wikipedia/en/b/b4/Wicked-poster.jpg',
    type: 'theater',
    genres: ['Musical', 'Fantasy'],
    tier: Tier.B,
    rank: 0
  },
  {
    id: '103',
    title: 'Interstellar',
    year: '2014',
    posterUrl: 'https://image.tmdb.org/t/p/w500/gEU2QniL6C8ztDDXLOx9TpBomvs.jpg',
    type: 'movie',
    genres: ['Sci-Fi', 'Drama'],
    tier: Tier.B,
    rank: 0
  }
];
