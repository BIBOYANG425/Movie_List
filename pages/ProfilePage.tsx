import React, { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ArrowLeft,
  Camera,
  Search,
  Upload,
  UserMinus,
  UserPlus,
  Users,
} from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useTranslation } from '../contexts/LanguageContext';
import { FriendProfile, JournalEntry, RankedItem, UserProfileSummary, UserSearchResult } from '../types';
import { ErrorBoundary } from '../components/shared/ErrorBoundary';
import { JournalHomeView } from '../components/journal/JournalHomeView';
import { JournalConversation } from '../components/journal/JournalConversation';
import { Toast } from '../components/shared/Toast';
import { LetterboxdImportModal } from '../components/media/LetterboxdImportModal';
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
  const { t } = useTranslation();
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
  const [journalExistingEntry, setJournalExistingEntry] = useState<JournalEntry | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const [isImportModalOpen, setIsImportModalOpen] = useState(false);

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
      setStatusMessage(t('profile.avatarFormat'));
      return;
    }

    if (nextFile.size > AVATAR_MAX_FILE_BYTES) {
      setStatusMessage(t('profile.avatarSize'));
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
        setStatusMessage(t('profile.uploadFailed'));
        return;
      }
      updatePayload.avatarUrl = upload.avatarUrl;
      updatePayload.avatarPath = upload.avatarPath;
    }

    const ok = await updateMyProfile(user.id, updatePayload);

    if (!ok) {
      setProfileBusy(false);
      setStatusMessage(t('profile.saveFailed'));
      return;
    }

    await refreshProfile();
    await loadProfile();
    setStatusMessage(t('profile.updated'));
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
      <div className="min-h-screen bg-background text-foreground">
        <main className="max-w-4xl mx-auto px-4 py-8">
          <div className="animate-pulse space-y-4 p-6">
            <div className="flex items-center gap-4">
              <div className="w-20 h-20 rounded-full bg-secondary" />
              <div className="space-y-2">
                <div className="h-5 w-32 bg-secondary rounded" />
                <div className="h-4 w-24 bg-secondary rounded" />
              </div>
            </div>
            <div className="flex gap-4">
              <div className="h-8 w-20 bg-secondary rounded-lg" />
              <div className="h-8 w-20 bg-secondary rounded-lg" />
            </div>
            <div className="h-16 w-full bg-secondary rounded-lg" />
          </div>
        </main>
      </div>
    );
  }

  if (notFound || !profile) {
    return (
      <div className="min-h-screen bg-background text-foreground">
        <main className="max-w-4xl mx-auto px-4 py-10 space-y-4">
          <Link
            to="/app"
            className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
          >
            <ArrowLeft size={14} />
            {t('profile.backToApp')}
          </Link>
          <div className="rounded-xl border border-border/30 bg-card/50 p-6">
            <h1 className="text-xl font-bold">{t('profile.notFound')}</h1>
            <p className="text-muted-foreground mt-2">{t('profile.notFoundHint')}</p>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background text-foreground">
      <main className="max-w-4xl mx-auto px-4 py-8 space-y-6">
        <div className="flex items-center justify-between">
          <Link
            to="/app"
            className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
          >
            <ArrowLeft size={14} />
            {t('profile.backToApp')}
          </Link>
        </div>

        <section className="rounded-2xl border border-border/30 bg-card/50 p-6 space-y-5">
          <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-5">
            <div className="flex items-center gap-4">
              <img
                src={avatarPreview}
                alt={profile.username}
                className="w-20 h-20 rounded-2xl object-cover border border-border bg-secondary"
              />
              <div>
                <h1 className="text-2xl font-bold">{profile.displayName ?? profile.username}</h1>
                <p className="text-muted-foreground text-sm mt-0.5">@{profile.username}</p>
                <p className="text-muted-foreground text-sm mt-1">
                  {profile.isSelf
                    ? t('profile.yourProfile')
                    : profile.isMutual
                      ? t('profile.youAreFriends')
                      : profile.isFollowing
                        ? t('profile.following')
                        : t('profile.notConnected')}
                </p>
                <div className="flex items-center gap-3 mt-3 text-sm">
                  <span className="text-muted-foreground">
                    <strong>{profile.followersCount}</strong> {t('profile.followers')}
                  </span>
                  <span className="text-muted-foreground">
                    <strong>{profile.followingCount}</strong> {t('profile.following')}
                  </span>
                </div>
              </div>
            </div>

            {!profile.isSelf && (
              profile.isFollowing ? (
                <button
                  onClick={handleUnfollow}
                  disabled={followBusy}
                  className="inline-flex items-center gap-2 rounded-lg border border-border px-4 py-2 text-sm text-foreground hover:text-red-300 hover:border-red-400 transition-colors disabled:opacity-50"
                >
                  <UserMinus size={14} />
                  {t('profile.unfollow')}
                </button>
              ) : (
                <button
                  onClick={handleFollow}
                  disabled={followBusy}
                  className="inline-flex items-center gap-2 rounded-lg bg-emerald-500 px-4 py-2 text-sm font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                >
                  <UserPlus size={14} />
                  {t('profile.follow')}
                </button>
              )
            )}
          </div>

          {(profile.bio && canSeeFullProfile) && (
            <p className="text-sm text-muted-foreground rounded-lg border border-border/30 bg-background px-3 py-2">{profile.bio}</p>
          )}

          {profile.isSelf && (
            <div className="rounded-xl border border-border/30 bg-background p-4 space-y-4">
              <div className="flex items-center gap-2 text-sm text-muted-foreground">
                <Camera size={14} />
                {t('profile.editProfile')}
              </div>

              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                onChange={(e) => handleAvatarFile(e.target.files?.[0] ?? null)}
                className="block text-xs text-muted-foreground file:mr-3 file:rounded-md file:border-0 file:bg-secondary/80 file:px-3 file:py-1.5 file:text-xs file:font-semibold file:text-foreground hover:file:bg-secondary/60"
              />

              <div className="space-y-1">
                <label className="text-xs font-semibold text-muted-foreground">{t('profile.displayName')}</label>
                <input
                  value={displayNameInput}
                  onChange={(e) => setDisplayNameInput(e.target.value.slice(0, 60))}
                  placeholder={t('profile.displayNameHint')}
                  className="w-full rounded-lg border border-border bg-card px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-muted-foreground">{t('profile.bio')}</label>
                <textarea
                  value={bioInput}
                  onChange={(e) => setBioInput(e.target.value.slice(0, MAX_BIO_LENGTH))}
                  className="w-full h-20 resize-none rounded-lg border border-border bg-card px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
                  placeholder={t('profile.bioHint')}
                />
                <p className="text-[11px] text-muted-foreground text-right">{bioInput.length}/{MAX_BIO_LENGTH}</p>
              </div>

              <div className="flex gap-3">
                <button
                  onClick={handleProfileSave}
                  disabled={profileBusy}
                  className="rounded-lg bg-gold px-4 py-2 text-sm font-semibold text-foreground hover:bg-gold-muted transition-colors disabled:opacity-50"
                >
                  {profileBusy ? t('profile.saving') : t('profile.saveProfile')}
                </button>
                <button
                  onClick={() => setIsImportModalOpen(true)}
                  className="inline-flex items-center gap-2 rounded-lg border border-border px-4 py-2 text-sm text-muted-foreground hover:text-foreground hover:border-border transition-colors"
                >
                  <Upload size={14} />
                  Import from Letterboxd
                </button>
              </div>
            </div>
          )}

          {statusMessage && (
            <p className="text-xs text-muted-foreground rounded-md border border-border/30 bg-background px-3 py-2">{statusMessage}</p>
          )}
        </section>

        {/* Find Friends section (own profile only) */}
        {profile.isSelf && (
          <section className="rounded-xl border border-border/30 bg-card/50 p-4 space-y-3">
            <div className="flex items-center gap-2 text-foreground">
              <Search size={16} />
              <h3 className="font-semibold">{t('profile.findFriends')}</h3>
            </div>
            <form onSubmit={handleFriendSearch} className="flex gap-2">
              <input
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder={t('profile.searchUsername')}
                className="flex-1 rounded-lg border border-border bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
              />
              <button
                type="submit"
                className="rounded-lg bg-gold px-4 py-2 text-sm font-semibold text-foreground hover:bg-gold-muted transition-colors"
              >
                {searching ? t('profile.searching') : t('profile.search')}
              </button>
            </form>

            {searchResults.length > 0 && (
              <div className="space-y-2">
                {searchResults.map((row) => (
                  <div
                    key={row.id}
                    className="flex items-center justify-between rounded-lg border border-border/30 bg-background px-3 py-2"
                  >
                    <Link to={`/profile/${row.id}`} className="flex items-center gap-2 min-w-0">
                      <img
                        src={row.avatarUrl}
                        alt={row.username}
                        className="w-7 h-7 rounded-md object-cover bg-secondary"
                      />
                      <span className="text-sm font-medium truncate">{row.displayName ?? row.username}</span>
                    </Link>
                    {row.isFollowing ? (
                      <button
                        onClick={() => handleSearchUnfollow(row.id)}
                        disabled={searchActionUserId === row.id}
                        className="inline-flex items-center gap-1 rounded-md border border-border px-2.5 py-1 text-xs text-muted-foreground hover:border-red-400 hover:text-red-300 transition-colors disabled:opacity-50"
                      >
                        <UserMinus size={12} />
                        {t('profile.unfollow')}
                      </button>
                    ) : (
                      <button
                        onClick={() => handleSearchFollow(row.id)}
                        disabled={searchActionUserId === row.id}
                        className="inline-flex items-center gap-1 rounded-md bg-emerald-500/90 px-2.5 py-1 text-xs font-semibold text-black hover:bg-emerald-400 transition-colors disabled:opacity-50"
                      >
                        <UserPlus size={12} />
                        {t('profile.follow')}
                      </button>
                    )}
                  </div>
                ))}
              </div>
            )}

            {searchAttempted && !searching && searchResults.length === 0 && (
              <p className="text-xs text-muted-foreground rounded-md border border-border/30 bg-background px-3 py-2">
                {t('profile.noUsersFound')}
              </p>
            )}
          </section>
        )}

        {!canSeeFullProfile && (
          <section className="rounded-xl border border-border/30 bg-card/50 p-6">
            <div className="flex items-center gap-2">
              <Users size={16} className="text-muted-foreground" />
              <h2 className="font-semibold">{t('profile.friendsOnly')}</h2>
            </div>
            <p className="text-muted-foreground text-sm mt-2">
              {t('profile.friendsOnlyHint')}
            </p>
          </section>
        )}

        {canSeeFullProfile && (
          <>
            <section className="grid md:grid-cols-2 gap-4">
              <div className="rounded-xl border border-border/30 bg-card/50 p-4">
                <h2 className="font-semibold mb-3">{t('profile.followers')}</h2>
                {followers.length === 0 ? (
                  <p className="text-sm text-muted-foreground">{t('profile.noFollowers')}</p>
                ) : (
                  <div className="space-y-2">
                    {followers.map((row) => (
                      <Link
                        key={row.id}
                        to={`/profile/${row.id}`}
                        className="flex items-center gap-3 rounded-lg border border-border/30 bg-background px-3 py-2 hover:border-border transition-colors"
                      >
                        <img
                          src={row.avatarUrl}
                          alt={row.username}
                          className="w-8 h-8 rounded-lg object-cover bg-secondary"
                        />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-medium truncate">{row.displayName ?? row.username}</p>
                          <p className="text-xs text-muted-foreground truncate">@{row.username}</p>
                        </div>
                        <p className="text-xs text-muted-foreground">{relativeDate(row.followedAt ?? '')}</p>
                      </Link>
                    ))}
                  </div>
                )}
              </div>

              <div className="rounded-xl border border-border/30 bg-card/50 p-4">
                <h2 className="font-semibold mb-3">{t('profile.following')}</h2>
                {following.length === 0 ? (
                  <p className="text-sm text-muted-foreground">{t('profile.notFollowing')}</p>
                ) : (
                  <div className="space-y-2">
                    {following.map((row) => (
                      <Link
                        key={row.id}
                        to={`/profile/${row.id}`}
                        className="flex items-center gap-3 rounded-lg border border-border/30 bg-background px-3 py-2 hover:border-border transition-colors"
                      >
                        <img
                          src={row.avatarUrl}
                          alt={row.username}
                          className="w-8 h-8 rounded-lg object-cover bg-secondary"
                        />
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-medium truncate">{row.displayName ?? row.username}</p>
                          <p className="text-xs text-muted-foreground truncate">@{row.username}</p>
                        </div>
                        <p className="text-xs text-muted-foreground">{relativeDate(row.followedAt ?? '')}</p>
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            </section>

            {profile && user && (
              <ErrorBoundary>
              <section className="rounded-xl border border-border/30 bg-card/50 p-4">
                <JournalHomeView
                  userId={profile.id}
                  currentUserId={user.id}
                  isOwnProfile={profile.isSelf}
                  onEditEntry={(entry) => {
                    setJournalExistingEntry(entry);
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
              <JournalConversation
                isOpen={!!journalEditEntry}
                item={journalEditEntry}
                userId={user.id}
                existingEntry={journalExistingEntry}
                onDismiss={() => { setJournalEditEntry(null); setJournalExistingEntry(null); }}
                onSaved={() => { setJournalEditEntry(null); setJournalExistingEntry(null); setToastMessage(t('journal.saved')); }}
              />
              </ErrorBoundary>
            )}
          </>
        )}

        {toastMessage && (
          <Toast message={toastMessage} onDone={() => setToastMessage(null)} />
        )}

        {user && (
          <LetterboxdImportModal
            isOpen={isImportModalOpen}
            onClose={() => setIsImportModalOpen(false)}
            userId={user.id}
            onImportComplete={() => { loadProfile(); }}
          />
        )}
      </main>
    </div>
  );
};

export default ProfilePage;
