import React, { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  ArrowLeft,
  Camera,
  Check,
  ChevronDown,
  Globe,
  Pencil,
  Share2,
  Upload,
  UserMinus,
  UserPlus,
  Users,
} from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { useTranslation } from '../contexts/LanguageContext';
import { FriendProfile, JournalEntry, RankedItem, UserProfileSummary } from '../types';
import { ErrorBoundary } from '../components/shared/ErrorBoundary';
import { CalendarView } from '../components/stubs/CalendarView';
import { StubCollectionView } from '../components/stubs/StubCollectionView';
import { JournalHomeView } from '../components/journal/JournalHomeView';
import { JournalConversation } from '../components/journal/JournalConversation';
import { MovieListView } from '../components/social/MovieListView';
import { AchievementsView } from '../components/social/AchievementsView';
import { Toast } from '../components/shared/Toast';
import { LetterboxdImportModal } from '../components/media/LetterboxdImportModal';
import {
  AVATAR_ACCEPTED_MIME_TYPES,
  AVATAR_MAX_FILE_BYTES,
  followUser,
  getFollowerProfilesForUser,
  getFollowingProfilesForUser,
  getProfileSummary,
  unfollowUser,
  updateMyProfile,
  uploadAvatarPhoto,
} from '../services/friendsService';
import type { ProfileVisibility } from '../services/profileService';
import { getJournalStats } from '../services/journalService';
import { shareOrCopyLink } from '../utils/shareLink';
import { relativeDate } from '../utils/relativeDate';

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
  const [visibilityInput, setVisibilityInput] = useState<ProfileVisibility>('friends');
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [isEditing, setIsEditing] = useState(false);
  const [expandedList, setExpandedList] = useState<'followers' | 'following' | null>(null);

  const [profile, setProfile] = useState<UserProfileSummary | null>(null);
  const [followers, setFollowers] = useState<FriendProfile[]>([]);
  const [following, setFollowing] = useState<FriendProfile[]>([]);
  const [journalEditEntry, setJournalEditEntry] = useState<RankedItem | null>(null);
  const [journalExistingEntry, setJournalExistingEntry] = useState<JournalEntry | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const [isImportModalOpen, setIsImportModalOpen] = useState(false);
  const [streakStats, setStreakStats] = useState<{ currentStreak: number; longestStreak: number }>({ currentStreak: 0, longestStreak: 0 });
  const [linkCopied, setLinkCopied] = useState(false);
  const [profileTab, setProfileTab] = useState<'journal' | 'memories' | 'lists' | 'achievements'>('journal');

  const handleShareProfile = async () => {
    if (!profile) return;
    const url = `${window.location.origin}/u/${profile.username}`;
    const title = `${profile.displayName || profile.username} on Spool`;
    const copied = await shareOrCopyLink(title, url);
    if (copied) {
      setLinkCopied(true);
      setTimeout(() => setLinkCopied(false), 2000);
    }
  };

  const canSeeFullProfile = useMemo(() => {
    if (!profile) return false;
    return profile.isSelf || profile.isMutual || profile.profileVisibility === 'public';
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

    // Load visibility setting + journal stats for own profile
    if (summary.isSelf) {
      const [visResult, journalStats] = await Promise.all([
        supabase
          .from('profiles')
          .select('profile_visibility')
          .eq('id', profileId)
          .single(),
        getJournalStats(profileId).catch(() => null),
      ]);
      if (visResult.data?.profile_visibility) {
        setVisibilityInput(visResult.data.profile_visibility as ProfileVisibility);
      }
      if (journalStats) {
        setStreakStats({ currentStreak: journalStats.currentStreak, longestStreak: journalStats.longestStreak });
      }
    }

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
      profileVisibility: ProfileVisibility;
      avatarUrl?: string | null;
      avatarPath?: string | null;
    } = {
      displayName: displayNameInput,
      bio: bioInput,
      onboardingCompleted: true,
      profileVisibility: visibilityInput,
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

  if (!user) return null;

  if (loading) {
    return (
      <div className="min-h-screen bg-background text-foreground">
        <main className="max-w-4xl mx-auto px-4 py-8">
          <div className="animate-pulse space-y-5 py-6">
            <div className="flex items-center gap-4">
              <div className="w-[72px] h-[72px] rounded-full bg-secondary" />
              <div className="space-y-2">
                <div className="h-5 w-36 bg-secondary rounded-full" />
                <div className="h-4 w-24 bg-secondary rounded-full" />
              </div>
            </div>
            <div className="flex gap-2">
              <div className="h-8 w-28 bg-secondary rounded-full" />
              <div className="h-8 w-28 bg-secondary rounded-full" />
            </div>
            <div className="flex gap-1.5">
              <div className="h-9 w-20 bg-secondary rounded-full" />
              <div className="h-9 w-24 bg-secondary rounded-full" />
              <div className="h-9 w-16 bg-secondary rounded-full" />
              <div className="h-9 w-28 bg-secondary rounded-full" />
            </div>
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
      <main className="max-w-4xl mx-auto px-4 pt-6 pb-10">
        <Link
          to="/app"
          className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground transition-colors mb-6"
        >
          <ArrowLeft size={14} />
          {t('profile.backToApp')}
        </Link>

        {/* ── Profile Header ──────────────────────────────────────────── */}
        <section className="mb-10">
          {/* Identity: avatar + name + actions */}
          <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-5 mb-5">
            <div className="flex items-center gap-4">
              {/* Round avatar with gradient ring */}
              <div className="relative flex-shrink-0">
                <div className="w-[72px] h-[72px] rounded-full p-[2.5px] bg-gradient-to-br from-[var(--tier-s)] via-[var(--tier-a)] to-[var(--tier-b)]">
                  <img
                    src={avatarPreview}
                    alt={profile.username}
                    className="w-full h-full rounded-full object-cover bg-background"
                  />
                </div>
                {profile.isSelf && streakStats.currentStreak > 0 && (
                  <div className="absolute -bottom-1 -right-1 flex items-center gap-0.5 bg-orange-500 text-white text-[10px] font-bold px-1.5 py-0.5 rounded-full shadow-lg">
                    🔥 {streakStats.currentStreak}
                  </div>
                )}
              </div>

              <div>
                <h1 className="text-xl font-bold tracking-tight">{profile.displayName ?? profile.username}</h1>
                <p className="text-muted-foreground text-sm">@{profile.username}</p>
                {!profile.isSelf && (
                  <div className="mt-1.5">
                    {profile.isMutual ? (
                      <span className="inline-flex items-center gap-1 text-[11px] font-semibold bg-[var(--tier-b)]/15 text-[var(--tier-b)] rounded-full px-2 py-0.5">
                        <Users size={10} /> {t('profile.youAreFriends')}
                      </span>
                    ) : profile.isFollowing ? (
                      <span className="inline-flex items-center gap-1 text-[11px] font-semibold bg-accent/15 text-accent rounded-full px-2 py-0.5">
                        <Check size={10} /> {t('profile.following')}
                      </span>
                    ) : null}
                  </div>
                )}
              </div>
            </div>

            <div className="flex items-center gap-2">
              {profile.isSelf && visibilityInput !== 'private' && (
                <button
                  onClick={handleShareProfile}
                  className="p-2 rounded-full text-muted-foreground hover:text-foreground hover:bg-secondary/50 transition-colors"
                  title={t('profile.shareProfile')}
                >
                  {linkCopied ? <Check size={16} className="text-[var(--tier-b)]" /> : <Share2 size={16} />}
                </button>
              )}
              {profile.isSelf && (
                <button
                  onClick={() => setIsEditing(!isEditing)}
                  className={`inline-flex items-center gap-1.5 rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${
                    isEditing
                      ? 'bg-secondary text-foreground'
                      : 'border border-border text-muted-foreground hover:text-foreground hover:border-foreground/30'
                  }`}
                >
                  <Pencil size={13} />
                  {t('profile.editProfile')}
                </button>
              )}
              {!profile.isSelf && (
                profile.isFollowing ? (
                  <button
                    onClick={handleUnfollow}
                    disabled={followBusy}
                    className="inline-flex items-center gap-2 rounded-full border border-border px-4 py-1.5 text-sm font-medium text-foreground hover:text-red-300 hover:border-red-400/50 transition-colors disabled:opacity-50"
                  >
                    <UserMinus size={14} />
                    {t('profile.unfollow')}
                  </button>
                ) : (
                  <button
                    onClick={handleFollow}
                    disabled={followBusy}
                    className="inline-flex items-center gap-2 rounded-full bg-gradient-to-r from-[var(--tier-s)] to-[var(--tier-a)] px-5 py-1.5 text-sm font-bold text-white shadow-lg shadow-[var(--tier-s)]/20 hover:shadow-[var(--tier-s)]/30 transition-all disabled:opacity-50"
                  >
                    <UserPlus size={14} />
                    {t('profile.follow')}
                  </button>
                )
              )}
            </div>
          </div>

          {/* Stats row — pill-style chips */}
          <div className="flex flex-wrap items-center gap-2 mb-3">
            <button
              onClick={() => setExpandedList(expandedList === 'followers' ? null : 'followers')}
              className="inline-flex items-center gap-1.5 rounded-full bg-secondary/60 px-3 py-1.5 text-sm hover:bg-secondary transition-colors"
            >
              <strong>{profile.followersCount}</strong>
              <span className="text-muted-foreground">{t('profile.followers')}</span>
            </button>
            <button
              onClick={() => setExpandedList(expandedList === 'following' ? null : 'following')}
              className="inline-flex items-center gap-1.5 rounded-full bg-secondary/60 px-3 py-1.5 text-sm hover:bg-secondary transition-colors"
            >
              <strong>{profile.followingCount}</strong>
              <span className="text-muted-foreground">{t('profile.following')}</span>
            </button>
            {profile.isSelf && streakStats.longestStreak > 0 && streakStats.currentStreak === 0 && (
              <div className="inline-flex items-center gap-1 rounded-full bg-secondary/40 px-3 py-1.5 text-xs text-muted-foreground">
                🔥 {t('streak.longest').replace('{n}', String(streakStats.longestStreak))}
              </div>
            )}
          </div>

          {(profile.bio && canSeeFullProfile) && (
            <p className="text-sm text-muted-foreground max-w-lg leading-relaxed">{profile.bio}</p>
          )}

          {/* Expanded followers/following list */}
          {expandedList && canSeeFullProfile && (
            <div className="mt-4 rounded-2xl border border-border/30 bg-card/50 p-3 animate-fade-in-up">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-semibold">
                  {expandedList === 'followers' ? t('profile.followers') : t('profile.following')}
                </h3>
                <button onClick={() => setExpandedList(null)} className="text-muted-foreground hover:text-foreground p-1">
                  <ChevronDown size={14} className="rotate-180" />
                </button>
              </div>
              {(expandedList === 'followers' ? followers : following).length === 0 ? (
                <p className="text-xs text-muted-foreground py-2">
                  {expandedList === 'followers' ? t('profile.noFollowers') : t('profile.notFollowing')}
                </p>
              ) : (
                <div className="space-y-0.5 max-h-48 overflow-y-auto">
                  {(expandedList === 'followers' ? followers : following).map((row) => (
                    <Link
                      key={row.id}
                      to={`/profile/${row.id}`}
                      className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-secondary/30 transition-colors"
                    >
                      <img src={row.avatarUrl} alt={row.username} className="w-7 h-7 rounded-full object-cover bg-secondary" />
                      <span className="text-sm font-medium truncate flex-1">{row.displayName ?? row.username}</span>
                      <span className="text-[11px] text-muted-foreground">{relativeDate(row.followedAt ?? '', t)}</span>
                    </Link>
                  ))}
                </div>
              )}
            </div>
          )}
        </section>

        {/* ── Edit Profile (collapsed by default) ─────────────────────── */}
        {profile.isSelf && isEditing && (
          <section className="rounded-xl border border-border/30 bg-card/50 p-4 space-y-4 animate-fade-in-up mb-8">
            <div className="flex items-center gap-3">
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                onChange={(e) => handleAvatarFile(e.target.files?.[0] ?? null)}
                className="block text-xs text-muted-foreground file:mr-3 file:rounded-md file:border-0 file:bg-secondary/80 file:px-3 file:py-1.5 file:text-xs file:font-semibold file:text-foreground hover:file:bg-secondary/60"
              />
            </div>

            <div className="grid sm:grid-cols-2 gap-4">
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
                <label className="text-xs font-semibold text-muted-foreground flex items-center gap-1.5">
                  <Globe size={12} />
                  {t('public.profileVisibility')}
                </label>
                <select
                  value={visibilityInput}
                  onChange={(e) => setVisibilityInput(e.target.value as ProfileVisibility)}
                  className="w-full rounded-lg border border-border bg-card px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
                >
                  <option value="public">{t('public.visibilityPublic')}</option>
                  <option value="friends">{t('public.visibilityFriends')}</option>
                  <option value="private">{t('public.visibilityPrivate')}</option>
                </select>
              </div>
            </div>

            <div className="space-y-1">
              <label className="text-xs font-semibold text-muted-foreground">{t('profile.bio')}</label>
              <textarea
                value={bioInput}
                onChange={(e) => setBioInput(e.target.value.slice(0, MAX_BIO_LENGTH))}
                className="w-full h-16 resize-none rounded-lg border border-border bg-card px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-accent/40"
                placeholder={t('profile.bioHint')}
              />
              <p className="text-xs text-muted-foreground text-right">{bioInput.length}/{MAX_BIO_LENGTH}</p>
            </div>

            <div className="flex items-center gap-3">
              <button
                onClick={handleProfileSave}
                disabled={profileBusy}
                className="rounded-lg bg-gold px-4 py-1.5 text-sm font-semibold text-primary-foreground hover:bg-gold-muted transition-colors disabled:opacity-50"
              >
                {profileBusy ? t('profile.saving') : t('profile.saveProfile')}
              </button>
              <button
                onClick={() => setIsImportModalOpen(true)}
                className="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors"
              >
                <Upload size={12} />
                Import from Letterboxd
              </button>
            </div>

            {statusMessage && (
              <p className="text-xs text-muted-foreground rounded-md border border-border/30 bg-background px-3 py-2">{statusMessage}</p>
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
            {/* Sub-tab navigation — pill style */}
            <nav className="flex items-center gap-1.5 mb-6 overflow-x-auto scrollbar-hide">
              {(['journal', 'memories', 'lists', 'achievements'] as const).map((tab) => (
                <button
                  key={tab}
                  onClick={() => setProfileTab(tab)}
                  className={`flex-shrink-0 px-4 py-2 rounded-full text-sm font-semibold transition-all duration-[var(--duration-normal)] ${
                    profileTab === tab
                      ? 'bg-foreground text-background'
                      : 'bg-secondary/50 text-muted-foreground hover:text-foreground hover:bg-secondary'
                  }`}
                >
                  {t(`profile.tab${tab.charAt(0).toUpperCase() + tab.slice(1)}` as any)}
                </button>
              ))}
            </nav>

            {/* Tab content — no card wrappers, views own their structure */}
            {profileTab === 'journal' && profile && user && (
              <ErrorBoundary>
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
              </ErrorBoundary>
            )}

            {profileTab === 'memories' && profile && (
              <ErrorBoundary>
              <div className="space-y-6">
                <CalendarView
                  userId={profile.id}
                  isOwnProfile={profile.isSelf}
                  currentStreak={streakStats.currentStreak}
                  longestStreak={streakStats.longestStreak}
                  username={profile.username}
                  displayName={profile.displayName}
                />
                <StubCollectionView userId={profile.id} isOwnProfile={profile.isSelf} />
              </div>
              </ErrorBoundary>
            )}

            {profileTab === 'lists' && user && (
              <ErrorBoundary>
                <MovieListView userId={user.id} />
              </ErrorBoundary>
            )}

            {profileTab === 'achievements' && user && (
              <ErrorBoundary>
                <AchievementsView userId={user.id} isOwnProfile={profile.isSelf} />
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
