import React, { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ArrowLeft,
  BookmarkPlus,
  Camera,
  Heart,
  ListPlus,
  MessageCircle,
  Search,
  Share2,
  UserMinus,
  UserPlus,
  Users,
} from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { ActivityComment, FriendProfile, ProfileActivityItem, UserProfileSummary, UserSearchResult } from '../types';
import {
  addActivityComment,
  AVATAR_ACCEPTED_MIME_TYPES,
  AVATAR_MAX_FILE_BYTES,
  followUser,
  getActivityEngagement,
  getFollowerProfilesForUser,
  getFollowingProfilesForUser,
  getProfileSummary,
  getRecentProfileActivity,
  listActivityComments,
  rankActivityMovie,
  saveActivityMovieToWatchlist,
  searchUsers,
  toggleActivityLike,
  unfollowUser,
  updateMyProfile,
  uploadAvatarPhoto,
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

const MAX_BIO_LENGTH = 280;

function activityActionLabel(eventType?: ProfileActivityItem['eventType']): string {
  if (eventType === 'ranking_move') return 'Reranked';
  if (eventType === 'ranking_remove') return 'Removed';
  return 'Ranked';
}

const ProfilePage = () => {
  const { user, refreshProfile } = useAuth();
  const { profileId } = useParams();

  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [followBusy, setFollowBusy] = useState(false);
  const [profileBusy, setProfileBusy] = useState(false);
  const [activityBusyId, setActivityBusyId] = useState<string | null>(null);
  const [likeBusyId, setLikeBusyId] = useState<string | null>(null);
  const [commentBusyId, setCommentBusyId] = useState<string | null>(null);
  const [commentLoadingId, setCommentLoadingId] = useState<string | null>(null);

  const [displayNameInput, setDisplayNameInput] = useState('');
  const [bioInput, setBioInput] = useState('');
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [likedActivityIds, setLikedActivityIds] = useState<Set<string>>(new Set());
  const [likeCounts, setLikeCounts] = useState<Record<string, number>>({});
  const [commentCounts, setCommentCounts] = useState<Record<string, number>>({});
  const [openCommentIds, setOpenCommentIds] = useState<Set<string>>(new Set());
  const [commentDrafts, setCommentDrafts] = useState<Record<string, string>>({});
  const [commentsByActivityId, setCommentsByActivityId] = useState<Record<string, ActivityComment[]>>({});

  // Friend search state (own profile only)
  const [searchQuery, setSearchQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<UserSearchResult[]>([]);
  const [searchAttempted, setSearchAttempted] = useState(false);
  const [searchActionUserId, setSearchActionUserId] = useState<string | null>(null);

  const [profile, setProfile] = useState<UserProfileSummary | null>(null);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [activity, setActivity] = useState<ProfileActivityItem[]>([]);

  const canSeeFullProfile = useMemo(() => {
    if (!profile) return false;
    return profile.isSelf || profile.isMutual;
  }, [profile]);

  const avatarPreview = useMemo(() => {
    if (!avatarFile) return profile?.avatarUrl;
    return URL.createObjectURL(avatarFile);
  }, [avatarFile, profile?.avatarUrl]);

  useEffect(() => () => {
    if (avatarPreview?.startsWith('blob:')) URL.revokeObjectURL(avatarPreview);
  }, [avatarPreview]);

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
      setLikedActivityIds(new Set());
      setLikeCounts({});
      setCommentCounts({});
      setOpenCommentIds(new Set());
      setCommentDrafts({});
      setCommentsByActivityId({});
      setLoading(false);
      return;
    }

    setProfile(summary);
    setDisplayNameInput(summary.displayName ?? summary.username);
    setBioInput(summary.bio ?? '');
    setAvatarFile(null);

    if (summary.isSelf || summary.isMutual) {
      const [nextFollowers, nextFollowing, nextActivity] = await Promise.all([
        getFollowerProfilesForUser(profileId),
        getFollowingProfilesForUser(profileId),
        getRecentProfileActivity(profileId),
      ]);
      setFollowers(nextFollowers);
      setFollowing(nextFollowing);
      setActivity(nextActivity);

      const engagement = await getActivityEngagement(user.id, nextActivity.map((item) => item.id));
      setLikedActivityIds(engagement.likedByMe);
      setLikeCounts(engagement.likeCounts);
      setCommentCounts(engagement.commentCounts);
      setOpenCommentIds(new Set());
      setCommentDrafts({});
      setCommentsByActivityId({});
    } else {
      setFollowers([]);
      setFollowing([]);
      setActivity([]);
      setLikedActivityIds(new Set());
      setLikeCounts({});
      setCommentCounts({});
      setOpenCommentIds(new Set());
      setCommentDrafts({});
      setCommentsByActivityId({});
    }

    setLoading(false);
  };

  useEffect(() => {
    loadProfile();
  }, [user?.id, profileId]);

  const handleFollow = async () => {
    if (!user || !profile || followBusy) return;
    setFollowBusy(true);
    const ok = await followUser(user.id, profile.id);
    if (ok) await loadProfile();
    setFollowBusy(false);
  };

  const handleUnfollow = async () => {
    if (!user || !profile || followBusy) return;
    setFollowBusy(true);
    const ok = await unfollowUser(user.id, profile.id);
    if (ok) await loadProfile();
    setFollowBusy(false);
  };

  const handleAvatarFile = (nextFile: File | null) => {
    if (!nextFile) {
      setAvatarFile(null);
      return;
    }

    if (!AVATAR_ACCEPTED_MIME_TYPES.includes(nextFile.type)) {
      setStatusMessage('Use JPG, PNG, WEBP, or GIF for your avatar.');
      return;
    }

    if (nextFile.size > AVATAR_MAX_FILE_BYTES) {
      setStatusMessage('Avatar must be 5MB or smaller.');
      return;
    }

    setAvatarFile(nextFile);
    setStatusMessage(null);
  };

  const handleProfileSave = async () => {
    if (!user || !profile || !profile.isSelf || profileBusy) return;
    setProfileBusy(true);
    setStatusMessage(null);

    const updatePayload: {
      displayName: string;
      bio: string;
      onboardingCompleted: boolean;
      avatarUrl?: string | null;
      avatarPath?: string | null;
    } = {
      displayName: displayNameInput,
      bio: bioInput,
      onboardingCompleted: true,
    };

    if (avatarFile) {
      const upload = await uploadAvatarPhoto(user.id, avatarFile);
      if (!upload) {
        setProfileBusy(false);
        setStatusMessage('Avatar upload failed. Try a different photo.');
        return;
      }
      updatePayload.avatarUrl = upload.avatarUrl;
      updatePayload.avatarPath = upload.avatarPath;
    }

    const ok = await updateMyProfile(user.id, updatePayload);

    if (!ok) {
      setProfileBusy(false);
      setStatusMessage('Could not save profile changes.');
      return;
    }

    await refreshProfile();
    await loadProfile();
    setStatusMessage('Profile updated.');
    setProfileBusy(false);
  };

  const handleToggleLike = async (activityId: string) => {
    if (!user) return;
    const shouldLike = !likedActivityIds.has(activityId);

    setLikeBusyId(activityId);
    const ok = await toggleActivityLike(user.id, activityId, shouldLike);
    if (!ok) {
      setStatusMessage('Could not update reaction right now.');
      setLikeBusyId(null);
      return;
    }

    setLikedActivityIds((prev) => {
      const next = new Set(prev);
      if (shouldLike) next.add(activityId);
      else next.delete(activityId);
      return next;
    });
    setLikeCounts((prev) => ({
      ...prev,
      [activityId]: Math.max(0, (prev[activityId] ?? 0) + (shouldLike ? 1 : -1)),
    }));
    setLikeBusyId(null);
  };

  const loadCommentsForActivity = async (activityId: string) => {
    setCommentLoadingId(activityId);
    const nextComments = await listActivityComments(activityId);
    setCommentsByActivityId((prev) => ({
      ...prev,
      [activityId]: nextComments,
    }));
    setCommentCounts((prev) => ({
      ...prev,
      [activityId]: nextComments.length,
    }));
    setCommentLoadingId(null);
  };

  const handleToggleComments = async (activityId: string) => {
    const wasOpen = openCommentIds.has(activityId);
    setOpenCommentIds((prev) => {
      const next = new Set(prev);
      if (wasOpen) next.delete(activityId);
      else next.add(activityId);
      return next;
    });

    if (!wasOpen && !commentsByActivityId[activityId]) {
      await loadCommentsForActivity(activityId);
    }
  };

  const handleSubmitComment = async (activityId: string) => {
    if (!user) return;
    const draft = (commentDrafts[activityId] ?? '').trim();
    if (!draft) return;

    setCommentBusyId(activityId);
    const ok = await addActivityComment(user.id, activityId, draft);
    if (!ok) {
      setStatusMessage('Could not add comment right now.');
      setCommentBusyId(null);
      return;
    }

    setCommentDrafts((prev) => ({ ...prev, [activityId]: '' }));
    await loadCommentsForActivity(activityId);
    setCommentBusyId(null);
  };

  const handleShare = async (item: ProfileActivityItem) => {
    if (!profile) return;

    const shareText = `${profile.displayName ?? profile.username} ranked ${item.title} in tier ${item.tier} on Marquee.`;
    try {
      if (navigator.share) {
        await navigator.share({
          text: shareText,
          url: window.location.href,
        });
      } else {
        await navigator.clipboard.writeText(`${shareText} ${window.location.href}`);
      }
      setStatusMessage('Shared to clipboard.');
    } catch {
      setStatusMessage('Could not share right now.');
    }
  };

  const handleSaveToWatchlist = async (item: ProfileActivityItem) => {
    if (!user || !profile || profile.isSelf) return;

    setActivityBusyId(item.id);
    const ok = await saveActivityMovieToWatchlist(user.id, item);
    setStatusMessage(ok ? `Saved "${item.title}" to your watchlist.` : 'Could not save to watchlist.');
    setActivityBusyId(null);
  };

  const handleRankFromActivity = async (item: ProfileActivityItem) => {
    if (!user || !profile || profile.isSelf) return;

    setActivityBusyId(item.id);
    const ok = await rankActivityMovie(user.id, item);
    setStatusMessage(ok ? `Ranked "${item.title}" in tier ${item.tier}.` : 'Could not rank this movie.');
    setActivityBusyId(null);
  };

  // ── Friend Search (own profile) ──────────────────────────────────────────

  const handleFriendSearch = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!user || !searchQuery.trim()) {
      setSearchResults([]);
      setSearchAttempted(false);
      return;
    }
    setSearching(true);
    setSearchAttempted(true);
    try {
      const results = await searchUsers(user.id, searchQuery);
      setSearchResults(results);
    } catch {
      setSearchResults([]);
    } finally {
      setSearching(false);
    }
  };

  const handleSearchFollow = async (targetUserId: string) => {
    if (!user) return;
    setSearchActionUserId(targetUserId);
    const ok = await followUser(user.id, targetUserId);
    if (ok) {
      setSearchResults(prev =>
        prev.map(r => r.id === targetUserId ? { ...r, isFollowing: true } : r),
      );
      await loadProfile();
    }
    setSearchActionUserId(null);
  };

  const handleSearchUnfollow = async (targetUserId: string) => {
    if (!user) return;
    setSearchActionUserId(targetUserId);
    const ok = await unfollowUser(user.id, targetUserId);
    if (ok) {
      setSearchResults(prev =>
        prev.map(r => r.id === targetUserId ? { ...r, isFollowing: false } : r),
      );
      await loadProfile();
    }
    setSearchActionUserId(null);
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

        <section className="rounded-2xl border border-zinc-800 bg-zinc-900/70 p-6 space-y-5">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-5">
            <div className="flex items-center gap-4">
              <img
                src={avatarPreview}
                alt={profile.username}
                className="w-20 h-20 rounded-2xl object-cover border border-zinc-700 bg-zinc-800"
              />
              <div>
                <h1 className="text-2xl font-bold">{profile.displayName ?? profile.username}</h1>
                <p className="text-zinc-400 text-sm mt-0.5">@{profile.username}</p>
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
                  disabled={followBusy}
                  className="inline-flex items-center gap-2 rounded-lg border border-zinc-700 px-4 py-2 text-sm text-zinc-200 hover:text-red-300 hover:border-red-400 transition-colors disabled:opacity-50"
                >
                  <UserMinus size={14} />
                  Unfollow
                </button>
              ) : (
                <button
                  onClick={handleFollow}
                  disabled={followBusy}
                  className="inline-flex items-center gap-2 rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                >
                  <UserPlus size={14} />
                  Follow
                </button>
              )
            )}
          </div>

          {(profile.bio && canSeeFullProfile) && (
            <p className="text-sm text-zinc-300 rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2">{profile.bio}</p>
          )}

          {profile.isSelf && (
            <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-4 space-y-4">
              <div className="flex items-center gap-2 text-sm text-zinc-300">
                <Camera size={14} />
                Edit profile
              </div>

              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                onChange={(e) => handleAvatarFile(e.target.files?.[0] ?? null)}
                className="block text-xs text-zinc-400 file:mr-3 file:rounded-md file:border-0 file:bg-zinc-700 file:px-3 file:py-1.5 file:text-xs file:font-semibold file:text-white hover:file:bg-zinc-600"
              />

              <div className="space-y-1">
                <label className="text-xs font-semibold text-zinc-400">Display Name</label>
                <input
                  value={displayNameInput}
                  onChange={(e) => setDisplayNameInput(e.target.value.slice(0, 60))}
                  placeholder="How friends should see your name"
                  className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/40"
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-zinc-400">Bio</label>
                <textarea
                  value={bioInput}
                  onChange={(e) => setBioInput(e.target.value.slice(0, MAX_BIO_LENGTH))}
                  className="w-full h-20 resize-none rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500/40"
                  placeholder="Tell people what kinds of movies you rank"
                />
                <p className="text-[11px] text-zinc-500 text-right">{bioInput.length}/{MAX_BIO_LENGTH}</p>
              </div>

              <button
                onClick={handleProfileSave}
                disabled={profileBusy}
                className="rounded-lg bg-indigo-500 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-400 transition-colors disabled:opacity-50"
              >
                {profileBusy ? 'Saving...' : 'Save Profile'}
              </button>
            </div>
          )}

          {statusMessage && (
            <p className="text-xs text-zinc-300 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2">{statusMessage}</p>
          )}
        </section>

        {/* Find Friends section (own profile only) */}
        {profile.isSelf && (
          <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 space-y-3">
            <div className="flex items-center gap-2 text-zinc-200">
              <Search size={16} />
              <h3 className="font-semibold">Find Friends</h3>
            </div>
            <form onSubmit={handleFriendSearch} className="flex gap-2">
              <input
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
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

            {searchResults.length > 0 && (
              <div className="space-y-2">
                {searchResults.map((row) => (
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
                      <span className="text-sm font-medium truncate">{row.displayName ?? row.username}</span>
                    </Link>
                    {row.isFollowing ? (
                      <button
                        onClick={() => handleSearchUnfollow(row.id)}
                        disabled={searchActionUserId === row.id}
                        className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2.5 py-1 text-xs text-zinc-300 hover:border-red-400 hover:text-red-300 transition-colors disabled:opacity-50"
                      >
                        <UserMinus size={12} />
                        Unfollow
                      </button>
                    ) : (
                      <button
                        onClick={() => handleSearchFollow(row.id)}
                        disabled={searchActionUserId === row.id}
                        className="inline-flex items-center gap-1 rounded-md bg-emerald-500/90 px-2.5 py-1 text-xs font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                      >
                        <UserPlus size={12} />
                        Follow
                      </button>
                    )}
                  </div>
                ))}
              </div>
            )}

            {searchAttempted && !searching && searchResults.length === 0 && (
              <p className="text-xs text-zinc-500 rounded-md border border-zinc-800 bg-zinc-950 px-3 py-2">
                No users found. Try a different username or display name.
              </p>
            )}
          </section>
        )}

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
                          <p className="text-sm font-medium truncate">{row.displayName ?? row.username}</p>
                          <p className="text-xs text-zinc-500 truncate">@{row.username}</p>
                        </div>
                        <p className="text-xs text-zinc-500">{relativeDate(row.followedAt ?? '')}</p>
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
                          <p className="text-sm font-medium truncate">{row.displayName ?? row.username}</p>
                          <p className="text-xs text-zinc-500 truncate">@{row.username}</p>
                        </div>
                        <p className="text-xs text-zinc-500">{relativeDate(row.followedAt ?? '')}</p>
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
                  {activity.map((item) => {
                    const liked = likedActivityIds.has(item.id);
                    const itemBusy = activityBusyId === item.id;
                    const likeBusy = likeBusyId === item.id;
                    const commentBusy = commentBusyId === item.id;
                    const commentLoading = commentLoadingId === item.id;
                    const commentsOpen = openCommentIds.has(item.id);
                    const comments = commentsByActivityId[item.id] ?? [];
                    const likeCount = likeCounts[item.id] ?? 0;
                    const commentCount = commentCounts[item.id] ?? 0;

                    return (
                      <div
                        key={item.id}
                        className="rounded-lg border border-zinc-800 bg-zinc-950 px-3 py-2 space-y-2"
                      >
                        <div className="flex items-center gap-3">
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
                              {activityActionLabel(item.eventType)} <span className="font-semibold">{item.title}</span> in tier {item.tier}
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

                        <div className="flex flex-wrap items-center gap-2 text-xs">
                          <button
                            onClick={() => handleToggleLike(item.id)}
                            disabled={likeBusy}
                            className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 transition-colors ${
                              liked
                                ? 'border-rose-500 text-rose-300 bg-rose-950/40'
                                : 'border-zinc-700 text-zinc-300 hover:border-zinc-500'
                            } disabled:opacity-50`}
                          >
                            <Heart size={12} />
                            {liked ? 'Liked' : 'Like'} {likeCount > 0 ? `(${likeCount})` : ''}
                          </button>

                          <button
                            onClick={() => handleToggleComments(item.id)}
                            className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2 py-1 text-zinc-300 hover:border-zinc-500 transition-colors"
                          >
                            <MessageCircle size={12} />
                            Comment {commentCount > 0 ? `(${commentCount})` : ''}
                          </button>

                          <button
                            onClick={() => handleShare(item)}
                            className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2 py-1 text-zinc-300 hover:border-zinc-500 transition-colors"
                          >
                            <Share2 size={12} />
                            Share
                          </button>

                          {!profile.isSelf && (
                            <>
                              <button
                                onClick={() => handleRankFromActivity(item)}
                                disabled={itemBusy}
                                className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2 py-1 text-zinc-300 hover:border-indigo-400 hover:text-indigo-300 transition-colors disabled:opacity-50"
                              >
                                <ListPlus size={12} />
                                Rank
                              </button>
                              <button
                                onClick={() => handleSaveToWatchlist(item)}
                                disabled={itemBusy}
                                className="inline-flex items-center gap-1 rounded-md border border-zinc-700 px-2 py-1 text-zinc-300 hover:border-emerald-400 hover:text-emerald-300 transition-colors disabled:opacity-50"
                              >
                                <BookmarkPlus size={12} />
                                Save
                              </button>
                            </>
                          )}
                        </div>

                        {commentsOpen && (
                          <div className="rounded-md border border-zinc-800 bg-zinc-900/70 p-2 space-y-2">
                            {commentLoading ? (
                              <p className="text-xs text-zinc-500">Loading comments...</p>
                            ) : comments.length === 0 ? (
                              <p className="text-xs text-zinc-500">No comments yet.</p>
                            ) : (
                              <div className="space-y-1.5">
                                {comments.map((comment) => (
                                  <div key={comment.id} className="text-xs text-zinc-300 rounded-md bg-zinc-950 border border-zinc-800 px-2 py-1.5">
                                    <span className="font-semibold text-zinc-200">
                                      {comment.displayName ?? comment.username}
                                    </span>{' '}
                                    <span className="text-zinc-500">{relativeDate(comment.createdAt)}</span>
                                    <p className="mt-1 text-zinc-300 whitespace-pre-wrap">{comment.body}</p>
                                  </div>
                                ))}
                              </div>
                            )}

                            <div className="flex gap-2">
                              <input
                                value={commentDrafts[item.id] ?? ''}
                                onChange={(e) => setCommentDrafts((prev) => ({ ...prev, [item.id]: e.target.value }))}
                                maxLength={500}
                                placeholder="Write a comment..."
                                className="flex-1 rounded-md border border-zinc-700 bg-zinc-950 px-2 py-1.5 text-xs text-zinc-100 focus:outline-none focus:ring-2 focus:ring-indigo-500/40"
                              />
                              <button
                                onClick={() => handleSubmitComment(item.id)}
                                disabled={commentBusy}
                                className="rounded-md border border-zinc-700 px-2 py-1.5 text-xs text-zinc-300 hover:border-zinc-500 disabled:opacity-50"
                              >
                                Post
                              </button>
                            </div>
                          </div>
                        )}
                      </div>
                    );
                  })}
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
