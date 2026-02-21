import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Activity, Search, UserMinus, UserPlus, Users } from 'lucide-react';
import { FriendFeedItem, FriendProfile, UserSearchResult } from '../types';
import {
  followUser,
  getFollowerProfiles,
  getFollowingProfiles,
  getFriendFeed,
  searchUsers,
  unfollowUser,
} from '../services/friendsService';

interface FriendsViewProps {
  userId: string;
}

function relativeDate(iso: string): string {
  try {
    const delta = Date.now() - new Date(iso).getTime();
    const minutes = Math.floor(delta / 60000);
    if (minutes < 1) return 'just now';
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return `${days}d ago`;
  } catch {
    return '';
  }
}

export const FriendsView: React.FC<FriendsViewProps> = ({ userId }) => {
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [actionUserId, setActionUserId] = useState<string | null>(null);
  const [results, setResults] = useState<UserSearchResult[]>([]);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [feed, setFeed] = useState<FriendFeedItem[]>([]);

  const followingSet = useMemo(() => new Set(following.map((user) => user.id)), [following]);

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
    if (!query.trim()) {
      setResults([]);
      return;
    }
    setSearching(true);
    const nextResults = await searchUsers(userId, query);
    setResults(nextResults);
    setSearching(false);
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
      <div className="flex items-center justify-center py-20">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div className="grid sm:grid-cols-3 gap-3">
        <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
          <p className="text-zinc-500 text-xs uppercase tracking-wide">Following</p>
          <p className="text-3xl font-bold mt-2">{following.length}</p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
          <p className="text-zinc-500 text-xs uppercase tracking-wide">Followers</p>
          <p className="text-3xl font-bold mt-2">{followers.length}</p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
          <p className="text-zinc-500 text-xs uppercase tracking-wide">Feed Events</p>
          <p className="text-3xl font-bold mt-2">{feed.length}</p>
        </div>
      </div>

      <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 space-y-3">
        <div className="flex items-center gap-2 text-zinc-200">
          <Search size={16} />
          <h3 className="font-semibold">Find Friends</h3>
        </div>
        <form onSubmit={handleSearch} className="flex gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search username..."
            className="flex-1 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/40"
          />
          <button
            type="submit"
            className="rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-400 transition-colors"
          >
            {searching ? 'Searching...' : 'Search'}
          </button>
        </form>

        {results.length > 0 && (
          <div className="space-y-2">
            {results.map((row) => {
              const isFollowing = row.isFollowing || followingSet.has(row.id);
              const isWorking = actionUserId === row.id;

              return (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-zinc-800"
                    />
                    <span className="text-sm font-medium truncate">{row.username}</span>
                  </Link>
                  {isFollowing ? (
                    <button
                      onClick={() => handleUnfollow(row.id)}
                      disabled={isWorking}
                      className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2.5 py-1 text-xs text-zinc-300 hover:border-red-400 hover:text-red-300 transition-colors disabled:opacity-50"
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
      </section>

      <div className="grid md:grid-cols-2 gap-4">
        <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
          <h3 className="font-semibold mb-3">Following</h3>
          {following.length === 0 ? (
            <p className="text-sm text-zinc-500">You are not following anyone yet.</p>
          ) : (
            <div className="space-y-2">
              {following.map((row) => (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-zinc-800"
                    />
                    <span className="text-sm truncate">{row.username}</span>
                  </Link>
                  <button
                    onClick={() => handleUnfollow(row.id)}
                    disabled={actionUserId === row.id}
                    className="text-xs text-zinc-400 hover:text-red-300 transition-colors disabled:opacity-50"
                  >
                    Unfollow
                  </button>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
          <h3 className="font-semibold mb-3">Followers</h3>
          {followers.length === 0 ? (
            <p className="text-sm text-zinc-500">No followers yet.</p>
          ) : (
            <div className="space-y-2">
              {followers.map((row) => (
                <div
                  key={row.id}
                  className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2"
                >
                  <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                    <img
                      src={row.avatarUrl}
                      alt={row.username}
                      className="w-7 h-7 rounded-md object-cover bg-zinc-800"
                    />
                    <span className="text-sm truncate">{row.username}</span>
                  </Link>
                  <span className="text-xs text-zinc-500">{relativeDate(row.followedAt ?? '')}</span>
                </div>
              ))}
            </div>
          )}
        </section>
      </div>

      <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="flex items-center gap-2 mb-3">
          <Activity size={16} className="text-indigo-300" />
          <h3 className="font-semibold">Friend Activity</h3>
        </div>
        {feed.length === 0 ? (
          <p className="text-sm text-zinc-500">Follow people to see their ranking activity.</p>
        ) : (
          <div className="space-y-2">
            {feed.map((item) => (
              <div
                key={item.id}
                className="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2"
              >
                {item.posterUrl ? (
                  <img
                    src={item.posterUrl}
                    alt={item.title}
                    className="w-10 h-14 rounded object-cover bg-zinc-800"
                  />
                ) : (
                  <div className="w-10 h-14 rounded bg-zinc-800" />
                )}
                <div className="flex-1 min-w-0">
                  <p className="text-sm truncate">
                    <Link
                      to={`/profile/${item.userId}`}
                      className="text-indigo-300 font-semibold hover:text-indigo-200"
                    >
                      {item.username}
                    </Link>{' '}
                    ranked{' '}
                    <span className="font-medium text-zinc-100">{item.title}</span>
                  </p>
                  <p className="text-xs text-zinc-500 mt-0.5">
                    Tier {item.tier} • {relativeDate(item.rankedAt)}
                  </p>
                </div>
                <span className="text-xs font-bold rounded-md px-2 py-1 bg-zinc-800 text-zinc-200">
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
