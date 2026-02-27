import React, { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ArrowLeft,
  Camera,
  Search,
  UserMinus,
  UserPlus,
  Users,
} from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { FriendProfile, RankedItem, UserProfileSummary, UserSearchResult } from '../types';
import { ErrorBoundary } from '../components/ErrorBoundary';
import { JournalHomeView } from '../components/JournalHomeView';
import { JournalEntrySheet } from '../components/JournalEntrySheet';
import { Toast } from '../components/Toast';
import {
  AVATAR_ACCEPTED_MIME_TYPES,
  AVATAR_MAX_FILE_BYTES,
  followUser,
  getFollowerProfilesForUser,
  getFollowingProfilesForUser,
  getProfileSummary,
  searchUsers,
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

const ProfilePage = () => {
  const { user, refreshProfile } = useAuth();
  const { profileId } = useParams();

  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);
  const [followBusy, setFollowBusy] = useState(false);
  const [profileBusy, setProfileBusy] = useState(false);

  const [displayNameInput, setDisplayNameInput] = useState('');
  const [bioInput, setBioInput] = useState('');
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);

  // Friend search state (own profile only)
  const [searchQuery, setSearchQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<UserSearchResult[]>([]);
  const [searchAttempted, setSearchAttempted] = useState(false);
  const [searchActionUserId, setSearchActionUserId] = useState<string | null>(null);

  const [profile, setProfile] = useState<UserProfileSummary | null>(null);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [journalEditEntry, setJournalEditEntry] = useState<RankedItem | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);

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
      setLoading(false);
      return;
    }

    setProfile(summary);
    setDisplayNameInput(summary.displayName ?? summary.username);
    setBioInput(summary.bio ?? '');
    setAvatarFile(null);

    if (summary.isSelf || summary.isMutual) {
      const [nextFollowers, nextFollowing] = await Promise.all([
        getFollowerProfilesForUser(profileId),
        getFollowingProfilesForUser(profileId),
      ]);
      setFollowers(nextFollowers);
      setFollowing(nextFollowing);
    } else {
      setFollowers([]);
      setFollowing([]);
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

            {profile && user && (
              <ErrorBoundary>
              <section className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
                <JournalHomeView
                  userId={profile.id}
                  currentUserId={user.id}
                  isOwnProfile={profile.isSelf}
                  onEditEntry={(entry) => {
                    setJournalEditEntry({
                      id: entry.tmdbId,
                      title: entry.title,
                      posterUrl: entry.posterUrl ?? '',
                      year: '',
                      type: 'movie',
                      genres: [],
                      tier: entry.ratingTier!,
                      rank: 0,
                    });
                  }}
                />
              </section>
              </ErrorBoundary>
            )}

            {/* Journal edit sheet */}
            {journalEditEntry && user && (
              <ErrorBoundary>
              <JournalEntrySheet
                isOpen={!!journalEditEntry}
                item={journalEditEntry}
                userId={user.id}
                onDismiss={() => setJournalEditEntry(null)}
                onSaved={() => { setJournalEditEntry(null); setToastMessage('Journal entry saved'); }}
              />
              </ErrorBoundary>
            )}
          </>
        )}

        {toastMessage && (
          <Toast message={toastMessage} onDone={() => setToastMessage(null)} />
        )}
      </main>
    </div>
  );
};

export default ProfilePage;
