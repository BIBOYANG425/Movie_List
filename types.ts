export enum Tier {
  S = 'S',
  A = 'A',
  B = 'B',
  C = 'C',
  D = 'D'
}

export enum Bracket {
  Commercial = 'Commercial',
  Artisan = 'Artisan',
  Documentary = 'Documentary',
  Animation = 'Animation',
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
  bracket?: Bracket;
  globalScore?: number; // TMDb vote_average (0–10), used to seed comparisons
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

// ── Phase 3: Group Experiences ──────────────────────────────────────────────

export type RsvpStatus = 'pending' | 'going' | 'maybe' | 'not_going';
export type PartyStatus = 'upcoming' | 'active' | 'completed' | 'cancelled';

export interface WatchParty {
  id: string;
  hostId: string;
  hostUsername?: string;
  hostAvatar?: string;
  title: string;
  movieTmdbId?: string;
  movieTitle?: string;
  moviePosterUrl?: string;
  scheduledAt: string;
  location?: string;
  notes?: string;
  status: PartyStatus;
  createdAt: string;
  memberCount?: number;
  goingCount?: number;
}

export interface WatchPartyMember {
  partyId: string;
  userId: string;
  username: string;
  displayName?: string;
  avatarUrl?: string;
  rsvp: RsvpStatus;
  respondedAt?: string;
}

export interface GroupRanking {
  id: string;
  name: string;
  createdBy: string;
  creatorUsername?: string;
  description?: string;
  createdAt: string;
  memberCount?: number;
  entryCount?: number;
}

export interface GroupRankingEntry {
  id: string;
  groupId: string;
  userId: string;
  username?: string;
  tmdbId: string;
  title: string;
  posterUrl?: string;
  year?: string;
  genres: string[];
  tier: Tier;
  createdAt: string;
}

export interface GroupRankingConsensus {
  tmdbId: string;
  title: string;
  posterUrl?: string;
  year?: string;
  tiers: { userId: string; username: string; tier: Tier }[];
  consensusTier: Tier;
  avgTierNumeric: number;
  divergenceScore: number; // 0 = agreement, higher = more spread
}

export interface MoviePoll {
  id: string;
  createdBy: string;
  creatorUsername?: string;
  question: string;
  expiresAt?: string;
  isClosed: boolean;
  createdAt: string;
  options?: MoviePollOption[];
  totalVotes?: number;
  viewerVoteOptionId?: string;
}

export interface MoviePollOption {
  id: string;
  pollId: string;
  tmdbId: string;
  title: string;
  posterUrl?: string;
  position: number;
  voteCount?: number;
  isWinner?: boolean;
}

export interface MoviePollVote {
  pollId: string;
  userId: string;
  optionId: string;
  createdAt: string;
}

// ── Phase 4: Content & Engagement ───────────────────────────────────────────

export type NotificationType =
  | 'new_follower'
  | 'review_like'
  | 'party_invite'
  | 'party_rsvp'
  | 'poll_vote'
  | 'poll_closed'
  | 'list_like'
  | 'badge_unlock'
  | 'group_invite'
  | 'ranking_comment'
  | 'journal_tag';

export interface AppNotification {
  id: string;
  userId: string;
  type: NotificationType;
  title: string;
  body?: string;
  actorId?: string;
  actorUsername?: string;
  actorAvatar?: string;
  referenceId?: string;
  isRead: boolean;
  createdAt: string;
}

export interface MovieList {
  id: string;
  createdBy: string;
  creatorUsername?: string;
  creatorAvatar?: string;
  title: string;
  description?: string;
  isPublic: boolean;
  coverUrl?: string;
  likeCount: number;
  itemCount?: number;
  createdAt: string;
  updatedAt: string;
  isLikedByViewer?: boolean;
  items?: MovieListItem[];
}

export interface MovieListItem {
  id: string;
  listId: string;
  tmdbId: string;
  title: string;
  posterUrl?: string;
  year?: string;
  position: number;
  note?: string;
  addedAt: string;
}

export interface BadgeDefinition {
  key: string;
  name: string;
  description: string;
  icon: string;      // emoji
  category: 'milestone' | 'social' | 'taste' | 'special';
  requirement: string;
}

export interface UserAchievement {
  badgeKey: string;
  unlockedAt: string;
}

// ── Journal Entries ─────────────────────────────────────────────────────────

export type MoodCategory = 'positive' | 'reflective' | 'intense' | 'light';

export interface MoodTagDef {
  id: string;
  label: string;
  emoji: string;
  category: MoodCategory;
}

export interface VibeTagDef {
  id: string;
  label: string;
  emoji: string;
}

export interface StandoutPerformance {
  personId: number;
  name: string;
  character?: string;
  profilePath?: string;
}

export type JournalVisibility = 'public' | 'friends' | 'private';

export interface JournalEntry {
  id: string;
  userId: string;
  tmdbId: string;
  title: string;
  posterUrl?: string;
  ratingTier?: Tier;
  reviewText?: string;
  containsSpoilers: boolean;
  moodTags: string[];
  vibeTags: string[];
  favoriteMoments: string[];
  standoutPerformances: StandoutPerformance[];
  watchedDate?: string;
  watchedLocation?: string;
  watchedWithUserIds: string[];
  watchedPlatform?: string;
  isRewatch: boolean;
  rewatchNote?: string;
  personalTakeaway?: string;
  photoPaths: string[];
  visibilityOverride?: JournalVisibility;
  likeCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface JournalEntryCard extends JournalEntry {
  username: string;
  displayName?: string;
  avatarUrl?: string;
}

export interface JournalStats {
  totalEntries: number;
  entriesWithReview: number;
  mostCommonMood?: string;
  mostTaggedFriendId?: string;
  currentStreak: number;
  longestStreak: number;
}

export interface JournalFilters {
  mood?: string;
  vibe?: string;
  tier?: Tier;
  platform?: string;
  dateFrom?: string;
  dateTo?: string;
  searchQuery?: string;
}

// ── Spool: Comparison Logging ───────────────────────────────────────────────

export interface ComparisonLogEntry {
  sessionId: string;
  movieAId: string;
  movieBId: string;
  winner: 'a' | 'b' | 'skip';
  round: number;
}

// ── Phase 9: Full Movie Card (Detail View) ───────────────────────────────────

export interface StreamingProvider {
  providerId: number;
  providerName: string;
  logoUrl?: string; // Full URL to TMDB image
}

export interface StreamingAvailability {
  link?: string;
  flatrate?: StreamingProvider[];
  rent?: StreamingProvider[];
  buy?: StreamingProvider[];
  free?: StreamingProvider[];
}

export interface MoodTag {
  emoji: string;
  label: string;
  count: number;
}

export interface MovieSocialStats {
  movieId: string; // The TMDB ID string format e.g. "tmdb_123"
  timesRanked: number;
  friendsWatched: number;
  friendAvatars: string[];
  avgFriendRankPosition?: number;
  globalAvgRankPosition?: number;
  topFriendReview?: {
    userId: string;
    username: string;
    avatarUrl?: string;
    body: string;
    rankPosition: number;
    tier: Tier;
  };
  tasteMatchReview?: {
    userId: string;
    username: string;
    avatarUrl?: string;
    matchScore: number;
    rankPosition: number;
    tier: Tier;
  };
  moodConsensus: MoodTag[];
  divisiveMatchup?: {
    movieBTitle: string;
    winPercent: number; // e.g. 52 for 52/48 split
  };
  recentActivity?: FriendActivityItem[];
}

export interface FriendActivityItem {
  id: string; // the activity event id
  userId: string;
  username: string;
  avatarUrl?: string;
  action: 'ranked' | 'reviewed' | 'bookmarked';
  tier?: Tier;
  timestamp: string;
}

// ── Phase 5: Social Feed ────────────────────────────────────────────────────

export type FeedCardType = 'ranking' | 'review' | 'milestone' | 'list';

export type ReactionType = 'fire' | 'agree' | 'disagree' | 'want_to_watch' | 'love';

export interface FeedCard {
  id: string;
  userId: string;
  username: string;
  displayName?: string;
  avatarUrl?: string;
  cardType: FeedCardType;
  createdAt: string;
  // Media fields (ranking & review cards)
  mediaTmdbId?: string;
  mediaTitle?: string;
  mediaPosterUrl?: string;
  mediaTier?: Tier;
  bracket?: string;
  // Review fields
  reviewBody?: string;
  containsSpoilers?: boolean;
  // Milestone fields
  badgeKey?: string;
  badgeIcon?: string;
  milestoneDescription?: string;
  // List fields
  listId?: string;
  listTitle?: string;
  listPosterUrls?: string[];
  listItemCount?: number;
  // Engagement
  reactionCounts: Record<ReactionType, number>;
  commentCount: number;
  myReactions: ReactionType[];
}

export interface FeedComment extends ActivityComment {
  parentCommentId?: string;
  replies?: FeedComment[];
}

export interface FeedFilters {
  tab: 'friends' | 'explore';
  bracket?: Bracket | 'all';
  tier?: Tier | 'all';
  cardType?: FeedCardType | 'all';
  timeRange?: '24h' | '7d' | '30d' | 'all';
}

export interface FeedMute {
  id: string;
  muteType: 'user' | 'movie';
  targetId: string;
}
