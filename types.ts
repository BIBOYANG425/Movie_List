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
  displayName?: string;
  avatarUrl?: string;
  followedAt?: string;
}

export interface UserSearchResult extends FriendProfile {
  isFollowing: boolean;
}

export interface UserProfileSummary extends FriendProfile {
  bio?: string;
  onboardingCompleted?: boolean;
  followersCount: number;
  followingCount: number;
  isSelf: boolean;
  isFollowing: boolean;
  isFollowedBy: boolean;
  isMutual: boolean;
}

export interface AppProfile {
  id: string;
  username: string;
  displayName?: string;
  bio?: string;
  avatarUrl?: string;
  avatarPath?: string;
  onboardingCompleted: boolean;
}

export interface FriendFeedItem {
  id: string;
  userId: string;
  username: string;
  title: string;
  tier: Tier;
  rankedAt: string;
  posterUrl?: string;
  eventType?: 'ranking_add' | 'ranking_move' | 'ranking_remove';
}

export interface ProfileActivityItem {
  id: string;
  title: string;
  tier: Tier;
  notes?: string;
  year?: string;
  updatedAt: string;
  posterUrl?: string;
  eventType?: 'ranking_add' | 'ranking_move' | 'ranking_remove';
}

export interface ActivityComment {
  id: string;
  eventId: string;
  userId: string;
  username: string;
  displayName?: string;
  avatarUrl?: string;
  body: string;
  createdAt: string;
}

// ── Phase 1: Movie Reviews ──────────────────────────────────────────────────

export interface MovieReview {
  id: string;
  userId: string;
  username: string;
  displayName?: string;
  avatarUrl?: string;
  mediaItemId: string;
  mediaTitle: string;
  body: string;
  ratingTier?: Tier;
  containsSpoilers: boolean;
  likeCount: number;
  isLikedByViewer: boolean;
  createdAt: string;
  updatedAt: string;
}

// ── Phase 1: Taste Compatibility ────────────────────────────────────────────

export interface SharedMovieComparison {
  mediaItemId: string;
  mediaTitle: string;
  posterUrl?: string;
  viewerTier: string;
  viewerScore: number;
  targetTier: string;
  targetScore: number;
  tierDifference: number;
}

export interface TasteCompatibility {
  targetUserId: string;
  targetUsername: string;
  score: number; // 0-100
  sharedCount: number;
  agreements: number;
  nearAgreements: number;
  disagreements: number;
  topShared: SharedMovieComparison[];
  biggestDivergences: SharedMovieComparison[];
}

// ── Phase 1: Shared Watchlists ──────────────────────────────────────────────

export interface SharedWatchlistMember {
  userId: string;
  username: string;
  displayName?: string;
  avatarUrl?: string;
  joinedAt: string;
}

export interface SharedWatchlistItem {
  id: string;
  mediaItemId: string;
  mediaTitle: string;
  posterUrl?: string;
  releaseYear?: number;
  addedByUsername: string;
  voteCount: number;
  viewerHasVoted: boolean;
  addedAt: string;
}

export interface SharedWatchlist {
  id: string;
  name: string;
  createdBy: string;
  creatorUsername: string;
  memberCount: number;
  itemCount: number;
  createdAt: string;
  members?: SharedWatchlistMember[];
  items?: SharedWatchlistItem[];
}

// ── Phase 1: Ranking Comparison ─────────────────────────────────────────────

export interface RankingComparisonItem {
  mediaItemId: string;
  mediaTitle: string;
  posterUrl?: string;
  viewerTier?: string;
  viewerScore?: number;
  viewerRankPosition?: number;
  targetTier?: string;
  targetScore?: number;
  targetRankPosition?: number;
  isShared: boolean;
}

export interface RankingComparison {
  targetUserId: string;
  targetUsername: string;
  viewerTotal: number;
  targetTotal: number;
  sharedCount: number;
  items: RankingComparisonItem[];
}

// ── Phase 2: Discovery & Recommendations ────────────────────────────────────

export interface FriendRecommendation {
  tmdbId: string;
  title: string;
  posterUrl?: string;
  year?: string;
  genres: string[];
  avgTier: string;
  avgTierNumeric: number;
  friendCount: number;
  friendAvatars: string[];
  friendUsernames: string[];
  topTier: string;
}

export interface TrendingMovie {
  tmdbId: string;
  title: string;
  posterUrl?: string;
  year?: string;
  genres: string[];
  rankerCount: number;
  avgTier: string;
  avgTierNumeric: number;
  recentRankers: string[];
}

export interface GenreProfileItem {
  genre: string;
  count: number;
  percentage: number;
  avgTier: string;
  avgTierNumeric: number;
}

export interface GenreProfile {
  userId: string;
  username: string;
  totalRanked: number;
  genres: GenreProfileItem[];
}

export interface GenreComparison {
  viewerId: string;
  viewerUsername: string;
  targetId: string;
  targetUsername: string;
  viewerGenres: GenreProfileItem[];
  targetGenres: GenreProfileItem[];
  sharedTopGenres: string[];
}
