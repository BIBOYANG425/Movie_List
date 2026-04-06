import React, { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Users, Film, Tv, BookOpen, Lock, UserPlus, Share2, Check } from 'lucide-react';
import { RankedItem, Tier } from '../types';
import { TIER_COLORS, TIER_LABELS, TIERS } from '../constants';
import { getProfileByUsername, PublicProfile } from '../services/profileService';
import { getPublicRankings } from '../services/publicProfileService';
import { useTranslation } from '../contexts/LanguageContext';
import SpoolLogo from '../components/layout/SpoolLogo';

type MediaTab = 'movies' | 'tv' | 'books';

const PublicProfilePage: React.FC = () => {
  const { username } = useParams<{ username: string }>();
  const { t } = useTranslation();
  const [profile, setProfile] = useState<PublicProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [notFound, setNotFound] = useState(false);

  const [movies, setMovies] = useState<RankedItem[]>([]);
  const [tv, setTv] = useState<RankedItem[]>([]);
  const [books, setBooks] = useState<RankedItem[]>([]);
  const [mediaTab, setMediaTab] = useState<MediaTab>('movies');
  const [linkCopied, setLinkCopied] = useState(false);

  const handleShare = async () => {
    const url = `${window.location.origin}/u/${username}`;
    const title = `${profile?.displayName || username} on Spool`;
    try {
      if (navigator.share) {
        await navigator.share({ title, url });
        return;
      }
    } catch { /* user cancelled */ }
    await navigator.clipboard.writeText(url);
    setLinkCopied(true);
    setTimeout(() => setLinkCopied(false), 2000);
  };

  useEffect(() => {
    if (!username) return;
    setLoading(true);
    setNotFound(false);

    getProfileByUsername(username).then(async (p) => {
      if (!p) {
        setNotFound(true);
        setLoading(false);
        return;
      }
      setProfile(p);

      if (p.profileVisibility === 'public') {
        const rankings = await getPublicRankings(p.id);
        setMovies(rankings.movies);
        setTv(rankings.tv);
        setBooks(rankings.books);
      }
      setLoading(false);
    }).catch(() => {
      setNotFound(true);
      setLoading(false);
    });
  }, [username]);

  // OG meta tags for social sharing
  useEffect(() => {
    if (!profile) return;
    const name = profile.displayName || profile.username;
    document.title = `${name} on Spool`;

    const createdMetas: HTMLMetaElement[] = [];
    const setMeta = (property: string, content: string) => {
      let el = document.querySelector(`meta[property="${property}"]`) as HTMLMetaElement | null;
      if (!el) {
        el = document.createElement('meta');
        el.setAttribute('property', property);
        document.head.appendChild(el);
        createdMetas.push(el);
      }
      el.setAttribute('content', content);
    };

    setMeta('og:title', `${name} on Spool`);
    setMeta('og:description', profile.bio || `Check out ${name}'s movie rankings on Spool`);
    if (profile.avatarUrl) setMeta('og:image', profile.avatarUrl);
    setMeta('og:url', window.location.href);
    setMeta('og:type', 'profile');

    return () => {
      document.title = 'Spool';
      createdMetas.forEach((el) => el.remove());
    };
  }, [profile]);

  if (loading) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (notFound || !profile) {
    return (
      <div className="min-h-screen bg-background flex flex-col items-center justify-center gap-4 text-center px-6">
        <SpoolLogo size="md" />
        <h1 className="text-xl font-serif text-foreground">{t('public.notFound')}</h1>
        <p className="text-muted-foreground text-sm">{t('public.notFoundHint')}</p>
        <Link to="/" className="text-accent hover:underline text-sm">{t('public.joinSpool')}</Link>
      </div>
    );
  }

  const isPrivate = profile.profileVisibility === 'private';
  const isFriendsOnly = profile.profileVisibility === 'friends';
  const isPublic = profile.profileVisibility === 'public';

  const activeItems = mediaTab === 'movies' ? movies : mediaTab === 'tv' ? tv : books;
  const totalRankings = movies.length + tv.length + books.length;

  const topPicks = activeItems.filter((i) => i.tier === 'S' || i.tier === 'A').slice(0, 6);
  const itemsByTier = TIERS.reduce((acc, tier) => {
    const tierItems = activeItems.filter((i) => i.tier === tier);
    if (tierItems.length > 0) acc.push({ tier, items: tierItems });
    return acc;
  }, [] as { tier: Tier; items: RankedItem[] }[]);

  return (
    <div className="min-h-screen bg-background">
      {/* Top bar */}
      <div className="sticky top-0 z-10 bg-background/80 backdrop-blur-md border-b border-border/30 px-4 py-3 flex items-center justify-between">
        <Link to="/" className="flex items-center gap-2">
          <SpoolLogo size="sm" />
        </Link>
        <div className="flex items-center gap-3">
          <button
            onClick={handleShare}
            className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground transition-colors"
          >
            {linkCopied ? <Check size={14} className="text-emerald-400" /> : <Share2 size={14} />}
            {linkCopied ? t('profile.linkCopied') : t('profile.shareProfile')}
          </button>
          <Link
            to="/auth"
            className="flex items-center gap-1.5 text-sm font-medium text-accent hover:text-foreground transition-colors"
          >
            <UserPlus size={14} />
            {t('public.joinSpool')}
          </Link>
        </div>
      </div>

      {/* Profile header */}
      <div className="px-6 pt-8 pb-6 flex flex-col items-center text-center">
        <img
          src={profile.avatarUrl}
          alt={profile.username}
          className="w-20 h-20 rounded-full border-2 border-border object-cover"
        />
        <h1 className="mt-3 text-2xl font-serif text-foreground">
          {profile.displayName || profile.username}
        </h1>
        <p className="text-sm text-muted-foreground">@{profile.username}</p>

        {profile.bio && isPublic && (
          <p className="mt-2 text-sm text-muted-foreground max-w-md">{profile.bio}</p>
        )}

        <div className="mt-3 flex items-center gap-4 text-sm text-muted-foreground">
          <span><strong className="text-foreground">{profile.followersCount}</strong> {t('profile.followers').toLowerCase()}</span>
          <span><strong className="text-foreground">{totalRankings}</strong> {t('public.rankings')}</span>
        </div>
      </div>

      {/* Private / Friends-only states */}
      {isPrivate && (
        <div className="px-6 py-16 text-center">
          <Lock size={32} className="mx-auto mb-3 text-muted-foreground/40" />
          <h2 className="font-serif text-lg text-foreground mb-1">{t('public.privateProfile')}</h2>
          <p className="text-sm text-muted-foreground">{t('public.privateHint')}</p>
        </div>
      )}

      {isFriendsOnly && (
        <div className="px-6 py-16 text-center">
          <Users size={32} className="mx-auto mb-3 text-muted-foreground/40" />
          <h2 className="font-serif text-lg text-foreground mb-1">{t('public.friendsOnlyProfile')}</h2>
          <p className="text-sm text-muted-foreground mb-4">{t('public.friendsOnlyHint')}</p>
          <Link
            to="/auth"
            className="inline-flex items-center gap-2 px-4 py-2 bg-gold text-foreground font-medium rounded-xl text-sm hover:bg-gold-muted transition-colors"
          >
            {t('public.signInToFollow')}
          </Link>
        </div>
      )}

      {/* Public rankings */}
      {isPublic && (
        <div className="px-4 pb-16 max-w-2xl mx-auto space-y-6">
          {/* Media tabs */}
          <div className="flex gap-1 bg-card/50 border border-border/30 rounded-xl p-1">
            {([
              { key: 'movies' as MediaTab, label: t('public.movies'), icon: Film, count: movies.length },
              { key: 'tv' as MediaTab, label: t('public.tv'), icon: Tv, count: tv.length },
              { key: 'books' as MediaTab, label: t('public.books'), icon: BookOpen, count: books.length },
            ]).map(({ key, label, icon: Icon, count }) => (
              <button
                key={key}
                onClick={() => setMediaTab(key)}
                className={`flex-1 flex items-center justify-center gap-1.5 py-2 rounded-lg text-sm font-medium transition-colors ${
                  mediaTab === key
                    ? 'bg-background text-foreground shadow-sm'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                <Icon size={14} />
                {label}
                {count > 0 && (
                  <span className="text-xs text-muted-foreground">({count})</span>
                )}
              </button>
            ))}
          </div>

          {activeItems.length === 0 && (
            <p className="text-center text-sm text-muted-foreground py-8">{t('public.noRankingsYet')}</p>
          )}

          {/* Top picks */}
          {topPicks.length > 0 && (
            <div>
              <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-3">
                {t('public.topPicks')}
              </h2>
              <div className="grid grid-cols-3 sm:grid-cols-6 gap-2">
                {topPicks.map((item) => (
                  <div key={item.id} className="group relative">
                    <img
                      src={item.posterUrl}
                      alt={item.title}
                      className="w-full aspect-[2/3] rounded-lg object-cover border border-border/30"
                    />
                    <div className={`absolute top-1 left-1 px-1 py-0.5 rounded text-[9px] font-bold border ${TIER_COLORS[item.tier]}`}>
                      {item.tier}
                    </div>
                    <p className="mt-1 text-[10px] text-muted-foreground truncate">{item.title}</p>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Full tier list */}
          {itemsByTier.length > 0 && (
            <div>
              <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider mb-3">
                {t('public.allRankings')}
              </h2>
              <div className="space-y-3">
                {itemsByTier.map(({ tier, items }) => (
                  <div key={tier} className={`rounded-xl border border-border/30 overflow-hidden`}>
                    <div className={`px-3 py-2 flex items-center gap-2 border-b border-border/20 bg-card/30`}>
                      <span className={`px-1.5 py-0.5 rounded text-[10px] font-bold border ${TIER_COLORS[tier]}`}>
                        {tier}
                      </span>
                      <span className="text-xs font-medium text-foreground">{TIER_LABELS[tier]}</span>
                      <span className="text-xs text-muted-foreground ml-auto">{items.length}</span>
                    </div>
                    <div className="flex gap-1.5 p-2 overflow-x-auto">
                      {items.map((item) => (
                        <div key={item.id} className="flex-shrink-0 w-12">
                          <img
                            src={item.posterUrl}
                            alt={item.title}
                            className="w-12 h-[72px] rounded object-cover border border-border/20"
                          />
                          <p className="text-[8px] text-muted-foreground truncate mt-0.5">{item.title}</p>
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* CTA */}
          <div className="text-center pt-4">
            <Link
              to="/auth"
              className="inline-flex items-center gap-2 px-5 py-2.5 bg-gold text-foreground font-semibold rounded-xl text-sm hover:bg-gold-muted transition-colors"
            >
              {t('public.joinSpool')}
            </Link>
            <p className="text-xs text-muted-foreground mt-2">{t('public.signInToFollow')}</p>
          </div>
        </div>
      )}
    </div>
  );
};

export default PublicProfilePage;
