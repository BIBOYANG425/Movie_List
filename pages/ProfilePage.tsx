import React, { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { ArrowLeft, Camera, UserMinus, UserPlus, Users } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { FriendProfile, ProfileActivityItem, UserProfileSummary } from '../types';
import {
  followUser,
  getFollowerProfilesForUser,
  getFollowingProfilesForUser,
  getProfileSummary,
  getRecentProfileActivity,
  unfollowUser,
  updateProfileAvatar,
} from '../services/friendsService';

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

const ProfilePage = () => {
  const { user } = useAuth();
  const { profileId } = useParams();

  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [busy, setBusy] = useState(false);
  const [avatarInput, setAvatarInput] = useState('');

  const [profile, setProfile] = useState<UserProfileSummary | null>(null);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [activity, setActivity] = useState<ProfileActivityItem[]>([]);

  const canSeeFullProfile = useMemo(() => {
    if (!profile) return false;
    return profile.isSelf || profile.isMutual;
  }, [profile]);

  const loadProfile = async () => {
    if (!user) return;
    if (!profileId) {
      setNotFound(true);
      setLoading(false);
      return;
    }
    setLoading(true);
    setNotFound(false);

    const summary = await getProfileSummary(user.id, profileId);
    if (!summary) {
      setNotFound(true);
      setProfile(null);
      setFollowers([]);
      setFollowing([]);
      setActivity([]);
      setLoading(false);
      return;
    }

    setProfile(summary);
    setAvatarInput(summary.avatarUrl ?? '');

    if (summary.isSelf || summary.isMutual) {
      const [nextFollowers, nextFollowing, nextActivity] = await Promise.all([
        getFollowerProfilesForUser(profileId),
        getFollowingProfilesForUser(profileId),
        getRecentProfileActivity(profileId),
      ]);
      setFollowers(nextFollowers);
      setFollowing(nextFollowing);
      setActivity(nextActivity);
    } else {
      setFollowers([]);
      setFollowing([]);
      setActivity([]);
    }

    setLoading(false);
  };

  useEffect(() => {
    loadProfile();
  }, [user?.id, profileId]);

  const handleFollow = async () => {
    if (!user || !profile || busy) return;
    setBusy(true);
    const ok = await followUser(user.id, profile.id);
    if (ok) await loadProfile();
    setBusy(false);
  };

  const handleUnfollow = async () => {
    if (!user || !profile || busy) return;
    setBusy(true);
    const ok = await unfollowUser(user.id, profile.id);
    if (ok) await loadProfile();
    setBusy(false);
  };

  const handleAvatarSave = async () => {
    if (!user || !profile || !profile.isSelf || busy) return;
    setBusy(true);
    const ok = await updateProfileAvatar(user.id, avatarInput);
    if (ok) await loadProfile();
    setBusy(false);
  };

  if (!user) return null;

  if (loading) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (notFound || !profile) {
    return (
      <div className="min-h-screen bg-zinc-950 text-zinc-100">
        <main className="max-w-4xl mx-auto px-4 py-10 space-y-4">
          <Link
            to="/app"
            className="inline-flex items-center gap-2 text-sm text-zinc-300 hover:text-white"
          >
            <ArrowLeft size={14} />
            Back to App
          </Link>
          <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-6">
            <h1 className="text-xl font-bold">Profile not found</h1>
            <p className="text-zinc-400 mt-2">This user does not exist or is unavailable.</p>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      <main className="max-w-4xl mx-auto px-4 py-8 space-y-6">
        <div className="flex items-center justify-between">
          <Link
            to="/app"
            className="inline-flex items-center gap-2 text-sm text-zinc-300 hover:text-white"
          >
            <ArrowLeft size={14} />
            Back to App
          </Link>
        </div>

        <section className="rounded-2xl border border-zinc-800 bg-zinc-900/70 p-6">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-5">
            <div className="flex items-center gap-4">
              <img
                src={profile.avatarUrl}
                alt={profile.username}
                className="w-20 h-20 rounded-2xl object-cover border border-zinc-700 bg-zinc-800"
              />
              <div>
                <h1 className="text-2xl font-bold">@{profile.username}</h1>
                <p className="text-zinc-400 text-sm mt-1">
                  {profile.isSelf
                    ? 'Your profile'
                    : profile.isMutual
                      ? 'You are friends'
                      : profile.isFollowing
                        ? 'Following'
                        : 'Not connected'}
                </p>
                <div className="flex items-center gap-3 mt-3 text-sm">
                  <span className="text-zinc-300">
                    <strong>{profile.followersCount}</strong> Followers
                  </span>
                  <span className="text-zinc-300">
                    <strong>{profile.followingCount}</strong> Following
                  </span>
                </div>
              </div>
            </div>

            {!profile.isSelf && (
              profile.isFollowing ? (
                <button
                  onClick={handleUnfollow}
                  disabled={busy}
                  className="inline-flex items-center gap-2 rounded-lg border border-zinc-700 px-4 py-2 text-sm text-zinc-200 hover:text-red-300 hover:border-red-400 transition-colors disabled:opacity-50"
                >
                  <UserMinus size={14} />
                  Unfollow
                </button>
              ) : (
                <button
                  onClick={handleFollow}
                  disabled={busy}
                  className="inline-flex items-center gap-2 rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                >
                  <UserPlus size={14} />
                  Follow
                </button>
              )
            )}
          </div>

          {profile.isSelf && (
            <div className="mt-5 rounded-xl border border-zinc-800 bg-zinc-950 p-4 space-y-3">
              <div className="flex items-center gap-2 text-sm text-zinc-300">
                <Camera size={14} />
                Profile Picture URL
              </div>
              <div className="flex gap-2">
                <input
                  value={avatarInput}
                  onChange={(e) => setAvatarInput(e.target.value)}
                  placeholder="https://example.com/avatar.jpg"
                  className="flex-1 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/40"
                />
                <button
                  onClick={handleAvatarSave}
                  disabled={busy}
                  className="rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-400 transition-colors disabled:opacity-50"
                >
                  Save
                </button>
              </div>
            </div>
          )}
        </section>

        {!canSeeFullProfile && (
          <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-6">
            <div className="flex items-center gap-2">
              <Users size={16} className="text-zinc-400" />
              <h2 className="font-semibold">Friends-only profile details</h2>
            </div>
            <p className="text-zinc-400 text-sm mt-2">
              Follow each other to unlock followers/following lists and recent activity.
            </p>
          </section>
        )}

        {canSeeFullProfile && (
          <>
            <section className="grid md:grid-cols-2 gap-4">
              <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
                <h2 className="font-semibold mb-3">Followers</h2>
                {followers.length === 0 ? (
                  <p className="text-sm text-zinc-500">No followers yet.</p>
                ) : (
                  <div className="space-y-2">
                    {followers.map((row) => (
                      <Link
                        key={row.id}
                        to={`/profile/${row.id}`}
                        className="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2 hover:border-zinc-600 transition-colors"
                      >
                        <img
                          src={row.avatarUrl}
                          alt={row.username}
                          className="w-8 h-8 rounded-lg object-cover bg-zinc-800"
                        />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-medium truncate">{row.username}</p>
                          <p className="text-xs text-zinc-500">{relativeDate(row.followedAt ?? '')}</p>
                        </div>
                      </Link>
                    ))}
                  </div>
                )}
              </div>

              <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
                <h2 className="font-semibold mb-3">Following</h2>
                {following.length === 0 ? (
                  <p className="text-sm text-zinc-500">Not following anyone yet.</p>
                ) : (
                  <div className="space-y-2">
                    {following.map((row) => (
                      <Link
                        key={row.id}
                        to={`/profile/${row.id}`}
                        className="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2 hover:border-zinc-600 transition-colors"
                      >
                        <img
                          src={row.avatarUrl}
                          alt={row.username}
                          className="w-8 h-8 rounded-lg object-cover bg-zinc-800"
                        />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-medium truncate">{row.username}</p>
                          <p className="text-xs text-zinc-500">{relativeDate(row.followedAt ?? '')}</p>
                        </div>
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            </section>

            <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
              <h2 className="font-semibold mb-3">Recent Activity</h2>
              {activity.length === 0 ? (
                <p className="text-sm text-zinc-500">No recent ranking activity.</p>
              ) : (
                <div className="space-y-2">
                  {activity.map((item) => (
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
                          Ranked <span className="font-semibold">{item.title}</span> in tier {item.tier}
                        </p>
                        <p className="text-xs text-zinc-500 mt-0.5">{relativeDate(item.updatedAt)}</p>
                        {item.notes && (
                          <p className="text-xs text-zinc-300 mt-1">
                            {item.notes}
                          </p>
                        )}
                      </div>
                      <span className="text-xs font-bold rounded-md px-2 py-1 bg-zinc-800 text-zinc-200">
                        {item.tier}
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </section>
          </>
        )}
      </main>
    </div>
  );
};

export default ProfilePage;
