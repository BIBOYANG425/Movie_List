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

export interface WatchlistItem extends MediaItem {
  addedAt: string; // ISO date string
}

export interface StatsData {
  name: string;
  value: number;
  fill: string;
}

export interface FriendProfile {
  id: string;
  username: string;
  avatarUrl?: string;
  followedAt?: string;
}

export interface UserSearchResult extends FriendProfile {
  isFollowing: boolean;
}

export interface UserProfileSummary extends FriendProfile {
  followersCount: number;
  followingCount: number;
  isSelf: boolean;
  isFollowing: boolean;
  isFollowedBy: boolean;
  isMutual: boolean;
}

export interface FriendFeedItem {
  id: string;
  userId: string;
  username: string;
  title: string;
  tier: Tier;
  rankedAt: string;
  posterUrl?: string;
}

export interface ProfileActivityItem {
  id: string;
  title: string;
  tier: Tier;
  notes?: string;
  updatedAt: string;
  posterUrl?: string;
}
