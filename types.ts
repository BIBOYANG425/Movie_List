export enum Tier {
  S = 'S',
  A = 'A',
  B = 'B',
  C = 'C',
  D = 'D'
}

export type MediaType = 'movie';

export interface MediaItem {
  id: string;
  title: string;
  year: string;
  posterUrl: string;
  type: MediaType;
  genres: string[];
  director?: string;
}

export interface RankedItem extends MediaItem {
  tier: Tier;
  rank: number; // 0-based index within the tier
  notes?: string;
}

export interface StatsData {
  name: string;
  value: number;
  fill: string;
}

