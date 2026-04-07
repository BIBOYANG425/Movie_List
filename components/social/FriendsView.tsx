import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Activity, Search, UserMinus, UserPlus, Users } from 'lucide-react';
import { FriendFeedItem, FriendProfile, UserSearchResult } from '../../types';
import {
  followUser,
  getFollowerProfiles,
  getFollowingProfiles,
  getFriendFeed,
  searchUsers,
  unfollowUser,
} from '../../services/friendsService';
import { SkeletonList } from '../shared/SkeletonCard';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

interface FriendsViewProps {
  userId: string;
  selfUsername?: string;
}

function feedActionText(eventType?: FriendFeedItem['eventType']): string {
  if (eventType === 'ranking_move') return 'reranked';
  if (eventType === 'ranking_remove') return 'removed';
  return 'ranked';
}

export const FriendsView: React.FC<FriendsViewProps> = ({ userId, selfUsername }) => {
  const { t } = useTranslation();
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [actionUserId, setActionUserId] = useState<string | null>(null);
  const [results, setResults] = useState<UserSearchResult[]>([]);
  const [searchAttempted, setSearchAttempted] = useState(false);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [feed, setFeed] = useState<FriendFeedItem[]>([]);

  const followingSet = useMemo(() => new Set(following.map((user) => user.id)), [following]);
  const normalizedQuery = query.trim().replace(/^@+/, '').toLowerCase();
  const isSearchingForSelf = Boolean(selfUsername)
    && normalizedQuery.length > 0
    && normalizedQuery === selfUsername.toLowerCase();

  const loadSocialData = async () => {
    setLoading(true);
    const [nextFollowing, nextFollowers, nextFeed] = await Promise.all([
      getFollowingProfiles(userId),
      getFollowerProfiles(userId),
      getFriendFeed(userId),
    ]);
    setFollowing(nextFollowing);
    setFollowers(nextFollowers);
    setFeed(nextFeed);
    setLoading(false);
  };

  useEffect(() => {
    loadSocialData();
  }, [userId]);

  const handleSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    setSearchError(null);
    if (!query.trim()) {
      setResults([]);
      setSearchAttempted(false);
      return;
    }
    try {
      setSearching(true);
      setSearchAttempted(true);
      const nextResults = await searchUsers(userId, query);
      setResults(nextResults);
    } catch (error) {
      console.error('Friend search failed:', error);
      setResults([]);
      setSearchError('Search failed. Please try again.');
    } finally {
      setSearching(false);
    }
  };

  const refreshFollowingAndFeed = async () => {
    const [nextFollowing, nextFeed] = await Promise.all([
      getFollowingProfiles(userId),
      getFriendFeed(userId),
    ]);
    setFollowing(nextFollowing);
    setFeed(nextFeed);
  };

  const handleFollow = async (targetUserId: string) => {
    setActionUserId(targetUserId);
    const ok = await followUser(userId, targetUserId);
    if (ok) {
      await refreshFollowingAndFeed();
      setResults((prev) =>
        prev.map((row) => (row.id === targetUserId ? { ...row, isFollowing: true } : row)),
      );
    }
    setActionUserId(null);
  };

  const handleUnfollow = async (targetUserId: string) => {
    setActionUserId(targetUserId);
    const ok = await unfollowUser(userId, targetUserId);
    if (ok) {
      await refreshFollowingAndFeed();
      setResults((prev) =>
        prev.map((row) => (row.id === targetUserId ? { ...row, isFollowing: false } : row)),
      );
    }
    setActionUserId(null);
  };

  if (loading) {
    return (
      <div className="space-y-6">
        <div className="grid sm:grid-cols-3 gap-3">
          {Array.from({ length: 3 }, (_, i) => (
            <div key={i} className="rounded-xl border border-border bg-card/50 p-4 animate-pulse">
              <div className="h-3 w-16 bg-secondary rounded" />
              <div className="h-8 w-12 bg-secondary rounded mt-2" />
            </div>
          ))}
        </div>
        <div className="grid md:grid-cols-2 gap-4">
          <div className="rounded-xl border border-border bg-card/50 p-4 space-y-2">
            <div className="h-4 w-20 bg-secondary rounded mb-3" />
            <SkeletonList count={3} variant="profile" />
          </div>
          <div className="rounded-xl border border-border bg-card/50 p-4 space-y-2">
            <div className="h-4 w-20 bg-secondary rounded mb-3" />
            <SkeletonList count={3} variant="profile" />
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="grid sm:grid-cols-3 gap-3">
        <div className="rounded-xl border border-border bg-card/50 p-4">
          <p className="text-muted-foreground text-xs uppercase tracking-wide">Following</p>
          <p className="text-3xl font-bold mt-2">{following.length}</p>
        </div>
        <div className="rounded-xl border border-border bg-card/50 p-4">
          <p className="text-muted-foreground text-xs uppercase tracking-wide">Followers</p>
          <p className="text-3xl font-bold mt-2">{followers.length}</p>
        </div>
        <div className="rounded-xl border border-border bg-card/50 p-4">
          <p className="text-muted-foreground text-xs uppercase tracking-wide">Feed Events</p>
          <p className="text-3xl font-bold mt-2">{feed.length}</p>
        </div>
      </div>

      <section className="rounded-xl border border-border bg-card/50 p-4 space-y-3">
        <div className="flex items-center gap-2 text-foreground">
          <Search size={16} />
          <h3 className="font-semibold">Find Friends</h3>
        </div>
        <form onSubmit={handleSearch} className="flex gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search username..."
            className="flex-1 rounded-lg border border-border bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
          />
          <button
            type="submit"
            className="rounded-lg bg-gold px-4 py-2 text-sm font-semibold text-foreground hover:bg-gold-muted transition-colors"
          >
            {searching ? 'Searching...' : 'Search'}
          </button>
        </form>

        {results.length > 0 && (
          <div className="space-y-2" role="list" aria-label="Search results">
            {results.map((row) => {
              const isFollowing = row.isFollowing || followingSet.has(row.id);
              const isWorking = actionUserId === row.id;

              return (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-border bg-background px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-secondary"
                    />
                    <span className="text-sm font-medium truncate">{row.displayName ?? row.username}</span>
                  </Link>
                  {isFollowing ? (
                    <button
                      onClick={() => handleUnfollow(row.id)}
                      disabled={isWorking}
                      className="inline-flex items-center gap-1 rounded-md border border-border px-2.5 py-1 text-xs text-muted-foreground hover:border-red-400 hover:text-red-300 transition-colors disabled:opacity-50"
                    >
                      <UserMinus size={12} />
                      Unfollow
                    </button>
                  ) : (
                    <button
                      onClick={() => handleFollow(row.id)}
                      disabled={isWorking}
                      className="inline-flex items-center gap-1 rounded-md bg-emerald-500/90 px-2.5 py-1 text-xs font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                    >
                      <UserPlus size={12} />
                      Follow
                    </button>
                  )}
                </div>
              );
            })}
          </div>
        )}

        {searchAttempted && !searching && results.length === 0 && (
          <p className="text-xs text-muted-foreground rounded-md border border-border bg-background px-3 py-2">
            {isSearchingForSelf
              ? 'That is your account. Friend search only shows other users.'
              : 'No users found. Try username/display name. Your own account is hidden from friend search.'}
          </p>
        )}

        {searchError && (
          <p className="text-xs text-red-300 rounded-md border border-red-900 bg-red-950/40 px-3 py-2">
            {searchError}
          </p>
        )}
      </section>

      <div className="grid md:grid-cols-2 gap-4">
        <section className="rounded-xl border border-border bg-card/50 p-4">
          <h3 className="font-semibold mb-3">Following</h3>
          {following.length === 0 ? (
            <p className="text-sm text-muted-foreground">You are not following anyone yet.</p>
          ) : (
            <div className="space-y-2" role="list" aria-label="Following">
              {following.map((row) => (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-border bg-background px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-secondary"
                    />
                    <span className="text-sm truncate">{row.displayName ?? row.username}</span>
                  </Link>
                  <button
                    onClick={() => handleUnfollow(row.id)}
                    disabled={actionUserId === row.id}
                    className="text-xs text-muted-foreground hover:text-red-300 transition-colors disabled:opacity-50"
                  >
                    Unfollow
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-xl border border-border bg-card/50 p-4">
          <h3 className="font-semibold mb-3">Followers</h3>
          {followers.length === 0 ? (
            <p className="text-sm text-muted-foreground">No followers yet.</p>
          ) : (
            <div className="space-y-2" role="list" aria-label="Followers">
              {followers.map((row) => (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-border bg-background px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-secondary"
                    />
                    <span className="text-sm truncate">{row.displayName ?? row.username}</span>
                  </Link>
                  {row.followedAt && <span className="text-xs text-muted-foreground">{relativeDate(row.followedAt, t)}</span>}
                </div>
              ))}
            </div>
          )}
        </section>
      </div>

      <section className="rounded-xl border border-border bg-card/50 p-4">
        <div className="flex items-center gap-2 mb-3">
          <Activity size={16} className="text-accent" />
          <h3 className="font-semibold">Friend Activity</h3>
        </div>
        {feed.length === 0 ? (
          <p className="text-sm text-muted-foreground">Follow people to see their ranking activity.</p>
        ) : (
          <div className="space-y-2">
            {feed.map((item) => (
              <div
                key={item.id}
                className="flex items-center gap-3 rounded-lg border border-border bg-background px-3 py-2"
              >
                {item.posterUrl ? (
                  <img
                    src={item.posterUrl}
                    alt={item.title}
                    className="w-10 h-14 rounded object-cover bg-secondary"
                  />
                ) : (
                  <div className="w-10 h-14 rounded bg-secondary" />
                )}
                <div className="flex-1 min-w-0">
                  <p className="text-sm truncate">
                    <Link
                      to={`/profile/${item.userId}`}
                      className="text-accent font-semibold hover:text-accent"
                    >
                      {item.username}
                    </Link>{' '}
                    {feedActionText(item.eventType)}{' '}
                    <span className="font-medium text-foreground">{item.title}</span>
                  </p>
                  <p className="text-xs text-muted-foreground mt-0.5">
                    Tier {item.tier} • {relativeDate(item.rankedAt, t)}
                  </p>
                </div>
                <span className="text-xs font-bold rounded-md px-2 py-1 bg-secondary text-foreground">
                  {item.tier}
                </span>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
};
