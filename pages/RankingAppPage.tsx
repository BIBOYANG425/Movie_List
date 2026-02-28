import React, { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ArrowLeft, BarChart2, Bookmark, Compass, LayoutGrid, LogOut, Plus, Rss, RotateCcw, UserCircle2, UsersRound } from 'lucide-react';
import { Tier, RankedItem, WatchlistItem, MediaType, Bracket, ComparisonLogEntry } from '../types';
import { TIERS, TIER_SCORE_RANGES, MIN_MOVIES_FOR_SCORES, MAX_TIER_TOLERANCE, BRACKETS, BRACKET_LABELS } from '../constants';
import { computeTierScore, classifyBracket } from '../services/rankingAlgorithm';
import { TierRow } from '../components/TierRow';
import { AddMediaModal } from '../components/AddMediaModal';
import { StatsView } from '../components/StatsView';
import { Watchlist } from '../components/Watchlist';
import { SocialFeedView } from '../components/SocialFeedView';
import { DiscoverView } from '../components/DiscoverView';
import { WatchPartyView } from '../components/WatchPartyView';
import { GroupRankingView } from '../components/GroupRankingView';
import { MoviePollView } from '../components/MoviePollView';
import { NotificationBell } from '../components/NotificationBell';
import { MovieListView } from '../components/MovieListView';
import { AchievementsView } from '../components/AchievementsView';
import { MediaDetailModal } from '../components/MediaDetailModal';
import { JournalEntrySheet } from '../components/JournalEntrySheet';
import { ErrorBoundary } from '../components/ErrorBoundary';
import { Toast } from '../components/Toast';
import { LanguageToggle } from '../components/LanguageToggle';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import { useTranslation } from '../contexts/LanguageContext';
import { logRankingActivityEvent } from '../services/friendsService';
import { TMDBMovie } from '../services/tmdbService';
import { useLocalizedItems, useLocalizedWatchlist } from '../hooks/useLocalizedItems';

const SCORE_MAX = 10.0;
const SCORE_MIN = 0.1;

/** Determine the "natural" tier for a given score based on equal brackets. */
function getNaturalTier(score: number): Tier {
  for (const tier of TIERS) {
    const range = TIER_SCORE_RANGES[tier];
    if (score >= range.min) return tier;
  }
  return Tier.D;
}

/** Dynamic tolerance: shrinks as the list grows. */
function getTierTolerance(totalItems: number): number {
  return Math.min(MAX_TIER_TOLERANCE, MAX_TIER_TOLERANCE * (MIN_MOVIES_FOR_SCORES / totalItems));
}

function computeScores(items: RankedItem[]): Map<string, number> {
  const scoreMap = new Map<string, number>();

  for (const tier of TIERS) {
    const tierItems = items
      .filter((i) => i.tier === tier)
      .sort((a, b) => a.rank - b.rank);

    const totalInTier = tierItems.length;
    if (totalInTier === 0) continue;

    const range = TIER_SCORE_RANGES[tier];

    tierItems.forEach((item, index) => {
      const score = computeTierScore(index, totalInTier, range.min, range.max);
      scoreMap.set(item.id, Number(score.toFixed(1)));
    });
  }

  return scoreMap;
}

/**
 * Sticky-tier logic: checks each item's computed score against its current
 * tier bracket. If the score has drifted beyond the dynamic tolerance, the
 * item is reassigned to its natural tier.
 * Returns a list of items that need tier updates (empty if none changed).
 */
function computeStickyTiers(
  items: RankedItem[],
  scoreMap: Map<string, number>,
): { id: string; newTier: Tier }[] {
  const total = items.length;
  if (total < MIN_MOVIES_FOR_SCORES) return [];

  const tolerance = getTierTolerance(total);
  const changes: { id: string; newTier: Tier }[] = [];

  for (const item of items) {
    const score = scoreMap.get(item.id);
    if (score === undefined) continue;

    const range = TIER_SCORE_RANGES[item.tier];
    const lowerBound = range.min - tolerance;
    const upperBound = range.max + tolerance;

    if (score < lowerBound || score > upperBound) {
      const naturalTier = getNaturalTier(score);
      if (naturalTier !== item.tier) {
        changes.push({ id: item.id, newTier: naturalTier });
      }
    }
  }

  return changes;
}

function rowToRankedItem(row: any): RankedItem {
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: row.type as MediaType,
    genres: row.genres ?? [],
    director: row.director,
    tier: row.tier as Tier,
    rank: row.rank_position,
    bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
    notes: row.notes,
  };
}

function rowToWatchlistItem(row: any): WatchlistItem {
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: row.type as MediaType,
    genres: row.genres ?? [],
    director: row.director,
    addedAt: row.added_at,
  };
}

const RankingAppPage = () => {
  const { user, profile, signOut } = useAuth();
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [items, setItems] = useState<RankedItem[]>([]);
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats' | 'watchlist' | 'feed' | 'discover' | 'groups'>('ranking');
  const [groupSubTab, setGroupSubTab] = useState<'parties' | 'rankings' | 'polls' | 'lists' | 'badges'>('parties');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  const [activeBracket, setActiveBracket] = useState<Bracket | 'all'>('all');
  const [activeGenre, setActiveGenre] = useState<string | null>(null);
  const [migrationState, setMigrationState] = useState<{ item: RankedItem, targetTier: Tier } | null>(null);
  const [preselectedForRank, setPreselectedForRank] = useState<WatchlistItem | TMDBMovie | null>(null);
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);
  const [journalSheetItem, setJournalSheetItem] = useState<RankedItem | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const linkedMovieId = searchParams.get('movieId');

  useEffect(() => {
    if (!user) return;

    const fetchData = async () => {
      setLoading(true);

      // Migrate onboarding picks from localStorage if present
      const ONBOARDING_KEY = 'spool_onboarding_picks';
      const stored = localStorage.getItem(ONBOARDING_KEY);
      if (stored) {
        try {
          const picks: RankedItem[] = JSON.parse(stored);
          if (picks.length > 0) {
            const rows = picks.map(item => ({
              user_id: user.id,
              tmdb_id: item.id,
              title: item.title,
              year: item.year,
              poster_url: item.posterUrl,
              type: item.type,
              genres: item.genres,
              director: item.director ?? null,
              tier: item.tier,
              rank_position: item.rank,
              bracket: item.bracket,
              notes: item.notes ?? null,
              updated_at: new Date().toISOString(),
            }));
            await supabase.from('user_rankings').upsert(rows, { onConflict: 'user_id,tmdb_id' });
          }
        } catch { /* ignore */ }
        localStorage.removeItem(ONBOARDING_KEY);
      }

      const [rankingsRes, watchlistRes] = await Promise.all([
        supabase
          .from('user_rankings')
          .select('*')
          .eq('user_id', user.id)
          .order('tier')
          .order('rank_position'),
        supabase
          .from('watchlist_items')
          .select('*')
          .eq('user_id', user.id)
          .order('added_at', { ascending: false }),
      ]);

      if (rankingsRes.data) setItems(rankingsRes.data.map(rowToRankedItem));
      if (watchlistRes.data) setWatchlist(watchlistRes.data.map(rowToWatchlistItem));

      setLoading(false);
    };

    fetchData();
  }, [user]);

  // Note: previously redirected to /onboarding/movies when items < MIN_MOVIES_FOR_SCORES,
  // but this caused redirect loops. Users can access onboarding via the normal flow instead.

  const handleReset = async () => {
    if (!user) return;
    if (!window.confirm('Reset your list? This cannot be undone.')) return;

    await supabase.from('user_rankings').delete().eq('user_id', user.id);
    setItems([]);
  };

  const handleDragStart = (e: React.DragEvent, id: string) => {
    setDraggedItemId(id);
    e.dataTransfer.effectAllowed = 'move';
  };

  const handleDrop = async (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId || !user) return;

    const droppedId = draggedItemId;
    const movedItem = items.find((i) => i.id === droppedId);
    setDraggedItemId(null);

    if (!movedItem) return;

    if (movedItem.tier !== targetTier) {
      // Trigger Spool tier migration comparison flow
      setMigrationState({ item: movedItem, targetTier });
      setIsModalOpen(true);
      return;
    }

    // Compute new rank from current items snapshot (before state update)
    const others = items.filter((i) => i.id !== droppedId);
    const newRank = others.filter((i) => i.tier === targetTier).length;

    setItems((prev) => {
      const movedItem = prev.find((i) => i.id === droppedId);
      if (!movedItem) return prev;

      const rest = prev.filter((i) => i.id !== droppedId);
      const newItem = { ...movedItem, tier: targetTier, rank: newRank };

      return [...rest, newItem].sort((a, b) => {
        if (a.tier === b.tier) return a.rank - b.rank;
        return 0;
      });
    });

    await supabase
      .from('user_rankings')
      .update({ tier: targetTier, rank_position: newRank, updated_at: new Date().toISOString() })
      .eq('user_id', user.id)
      .eq('tmdb_id', droppedId);

    if (movedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: movedItem.id,
          title: movedItem.title,
          tier: targetTier,
          posterUrl: movedItem.posterUrl,
          notes: movedItem.notes,
          year: movedItem.year,
        },
        'ranking_move',
      );
    }
  };

  const handleDropOnItem = async (e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    e.stopPropagation();
    if (!draggedItemId || !user || draggedItemId === targetId) return;

    const droppedId = draggedItemId;
    const movedItem = items.find((i) => i.id === droppedId);
    const targetItem = items.find((i) => i.id === targetId);
    setDraggedItemId(null);

    if (!movedItem || !targetItem) return;

    if (movedItem.tier !== targetItem.tier) {
      // Trigger Spool tier migration comparison flow, target is targetItem.tier
      setMigrationState({ item: movedItem, targetTier: targetItem.tier });
      setIsModalOpen(true);
      return;
    }

    // Move within the SAME tier
    let updatedTierList: RankedItem[] = [];
    setItems((prev) => {
      const tierItems = prev.filter(i => i.tier === targetItem.tier).sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter(i => i.tier !== targetItem.tier);

      // Find indices
      const oldIndex = tierItems.findIndex(i => i.id === droppedId);
      const newIndex = tierItems.findIndex(i => i.id === targetId);

      if (oldIndex === -1 || newIndex === -1) return prev;

      // Reorder array
      const [removed] = tierItems.splice(oldIndex, 1);
      tierItems.splice(newIndex, 0, removed);

      // Reassign ranks
      updatedTierList = tierItems.map((item, idx) => ({ ...item, rank: idx }));

      return [...otherItems, ...updatedTierList];
    });

    if (updatedTierList.length > 0) {
      const rowsToUpdate = updatedTierList.map(item => ({
        user_id: user.id,
        tmdb_id: item.id,
        title: item.title,
        year: item.year,
        poster_url: item.posterUrl,
        type: item.type,
        genres: item.genres,
        director: item.director ?? null,
        tier: item.tier,
        rank_position: item.rank,
        bracket: item.bracket ?? classifyBracket(item.genres),
        notes: item.notes ?? null,
        updated_at: new Date().toISOString(),
      }));
      const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
      if (error) console.error('Failed to save ranking:', error);
    }
  };

  const addItem = async (newItem: RankedItem) => {
    if (!user) return;

    let updatedTierList: RankedItem[] = [];

    setItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier && i.id !== newItem.id)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier && i.id !== newItem.id);

      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });

    if (updatedTierList.length > 0) {
      const rowsToUpdate = updatedTierList.map(item => ({
        user_id: user.id,
        tmdb_id: item.id,
        title: item.title,
        year: item.year,
        poster_url: item.posterUrl,
        type: item.type,
        genres: item.genres,
        director: item.director ?? null,
        tier: item.tier,
        rank_position: item.rank,
        bracket: item.bracket ?? classifyBracket(item.genres),
        notes: item.notes ?? null,
        updated_at: new Date().toISOString(),
      }));
      const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
      if (error) console.error('Failed to save ranking:', error);
    }

    await logRankingActivityEvent(
      user.id,
      {
        id: newItem.id,
        title: newItem.title,
        tier: newItem.tier,
        posterUrl: newItem.posterUrl,
        notes: newItem.notes,
        year: newItem.year,
      },
      'ranking_add',
    );
  };

  const removeItem = async (id: string) => {
    if (!user) return;
    const removedItem = items.find((item) => item.id === id);

    setItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      const tiers = new Set(without.map((i) => i.tier));
      let result: RankedItem[] = [];

      tiers.forEach((tier) => {
        const tierItems = without
          .filter((i) => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
      });

      return result;
    });

    await supabase
      .from('user_rankings')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);

    if (removedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: removedItem.id,
          title: removedItem.title,
          tier: removedItem.tier,
          posterUrl: removedItem.posterUrl,
          notes: removedItem.notes,
          year: removedItem.year,
        },
        'ranking_remove',
      );
    }
  };

  const addToWatchlist = async (item: WatchlistItem | TMDBMovie) => {
    if (!user) return;
    if (watchlist.some((w) => w.id === item.id)) return;

    const watchItem: WatchlistItem = {
      ...item,
      addedAt: 'addedAt' in item ? item.addedAt : new Date().toISOString(),
      type: 'movie',
      director: 'director' in item ? item.director : undefined,
    };

    setWatchlist((prev) => [watchItem, ...prev]);

    await supabase.from('watchlist_items').upsert({
      user_id: user.id,
      tmdb_id: watchItem.id,
      title: watchItem.title,
      year: watchItem.year,
      poster_url: watchItem.posterUrl,
      type: watchItem.type,
      genres: watchItem.genres,
      director: watchItem.director ?? null,
    }, { onConflict: 'user_id,tmdb_id' });

    setToastMessage(t('toast.movieSaved'));
  };

  const removeFromWatchlist = async (id: string) => {
    if (!user) return;

    setWatchlist((prev) => prev.filter((w) => w.id !== id));

    await supabase
      .from('watchlist_items')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);
  };

  const rankFromWatchlist = (item: WatchlistItem) => {
    setPreselectedForRank(item);
    setIsModalOpen(true);
  };

  const handleAddItem = async (newItem: RankedItem) => {
    await addItem(newItem);
    if (preselectedForRank) {
      await removeFromWatchlist(preselectedForRank.id);
      setPreselectedForRank(null);
    }
    if (migrationState) {
      setMigrationState(null);
    }
    setJournalSheetItem(newItem);
  };

  const handleCompareLog = async (log: ComparisonLogEntry) => {
    if (!user) return;
    try {
      await supabase.from('comparison_logs').insert({
        user_id: user.id,
        session_id: log.sessionId,
        movie_a_tmdb_id: log.movieAId,
        movie_b_tmdb_id: log.movieBId,
        winner: log.winner,
        round: log.round,
      });
    } catch (err) {
      console.error('Failed to log comparison:', err);
    }
  };

  const watchlistIds = useMemo(() => new Set(watchlist.map((w) => w.id)), [watchlist]);

  const bracketCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    items.forEach(i => {
      const b = i.bracket ?? 'Commercial';
      counts[b] = (counts[b] ?? 0) + 1;
    });
    return counts;
  }, [items]);

  const availableGenres = useMemo(() => {
    const genres = new Set<string>();
    items.forEach(i => {
      if (activeBracket === 'all' || i.bracket === activeBracket) {
        i.genres.forEach(g => genres.add(g));
      }
    });
    return Array.from(genres).sort();
  }, [items, activeBracket]);

  const filteredItems = useMemo(() => {
    let filtered = filterType === 'all' ? items : items.filter((i) => i.type === filterType);
    if (activeBracket !== 'all') {
      filtered = filtered.filter(i => i.bracket === activeBracket);
    }
    if (activeGenre) {
      filtered = filtered.filter(i => i.genres.includes(activeGenre));
    }
    return filtered;
  }, [items, filterType, activeBracket, activeGenre]);

  const localizedItems = useLocalizedItems(filteredItems);
  const localizedWatchlist = useLocalizedWatchlist(watchlist);

  const scoreMap = useMemo(() => computeScores(localizedItems), [localizedItems]);
  const showScores = localizedItems.length >= MIN_MOVIES_FOR_SCORES;

  if (loading) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-bg text-text font-sans pb-20">
      <nav className="sticky top-0 z-40 h-14 px-8 flex items-center justify-between bg-bg/80 backdrop-blur-[24px] saturate-[1.4] border-b border-border transition-all duration-350">
        <div className="flex items-center gap-7">
          <Link
            to="/"
            className="flex items-center gap-2"
          >
            <div className="w-[22px] h-[22px] rounded-full bg-[conic-gradient(from_180deg,#A855F7,#3B82F6,#10B981,#F59E0B,#EF4444,#A855F7)] flex items-center justify-center shadow-[0_0_13.2px_rgba(168,85,247,0.15)]">
              <div className="w-[8.8px] h-[8.8px] rounded-full bg-bg" />
            </div>
            <span className="font-serif text-[19px] text-cream tracking-[-0.03em]">spool</span>
          </Link>

          <div className="flex items-center gap-6">
            <div className="hidden md:flex bg-card rounded-lg p-1 border border-border">
              {(['all', 'movie'] as const).map((type) => (
                <button
                  key={type}
                  onClick={() => setFilterType(type)}
                  className={`px-3 py-1.5 rounded-md text-xs font-semibold capitalize transition-all ${filterType === type ? 'bg-elevated text-cream shadow' : 'text-dim hover:text-muted'
                    }`}
                >
                  {type === 'all' ? t('nav.all') : t('nav.movies')}
                </button>
              ))}
            </div>

            <button
              onClick={() => setIsModalOpen(true)}
              className="bg-cream text-bg px-4 py-2 rounded-lg font-semibold text-sm flex items-center gap-2 hover:opacity-90 transition-opacity"
            >
              <Plus size={16} />
              <span className="hidden sm:inline">{t('nav.addItem')}</span>
            </button>

            <button
              onClick={signOut}
              title="Sign out"
              className="text-text hover:text-cream text-[13px] font-medium transition-colors"
            >
              {t('nav.logOut')}
            </button>
            <LanguageToggle />
            {user && (
              <Link
                to={`/profile/${user.id}`}
                title={t('nav.myProfile')}
                className="text-text hover:text-cream transition-colors"
              >
                <UserCircle2 size={18} />
              </Link>
            )}
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-8 space-y-8">
        <header className="flex flex-col md:flex-row md:items-end justify-between gap-4">
          <div>
            <h1 className="text-4xl font-serif text-cream mb-2 tracking-[-0.02em]">{t('ranking.myCanon')}</h1>
            <p className="text-dim text-sm max-w-md">
              {t('ranking.subtitle')}
            </p>
          </div>

          <div className="flex gap-2">
            <button
              onClick={() => setActiveTab('ranking')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'ranking' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.rankings')}
            >
              <LayoutGrid size={20} />
            </button>
            <button
              onClick={() => setActiveTab('watchlist')}
              className={`p-2 rounded-lg transition-colors relative ${activeTab === 'watchlist' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.watchlist')}
            >
              <Bookmark size={20} />
              {watchlist.length > 0 && (
                <span className="absolute -top-1 -right-1 w-4 h-4 text-[9px] font-bold rounded-full bg-emerald-500 text-bg flex items-center justify-center">
                  {watchlist.length > 9 ? '9+' : watchlist.length}
                </span>
              )}
            </button>
            <button
              onClick={() => setActiveTab('stats')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'stats' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.stats')}
            >
              <BarChart2 size={20} />
            </button>
            <button
              onClick={() => setActiveTab('feed')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'feed' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.feed')}
            >
              <Rss size={20} />
            </button>
            <button
              onClick={() => setActiveTab('discover')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'discover' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.discover')}
            >
              <Compass size={20} />
            </button>
            <button
              onClick={() => setActiveTab('groups')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'groups' ? 'bg-elevated text-cream' : 'text-dim hover:bg-card'
                }`}
              title={t('tab.groups')}
            >
              <UsersRound size={20} />
            </button>
            {user && <NotificationBell userId={user.id} />}
            <button
              onClick={handleReset}
              title={t('tab.resetRankings')}
              className="p-2 rounded-lg text-muted hover:text-dim hover:bg-card transition-colors"
            >
              <RotateCcw size={18} />
            </button>
          </div>
        </header>

        {activeTab === 'ranking' && (
          <div className="space-y-4">
            <div className="flex bg-card rounded-lg p-1 overflow-x-auto border border-border scrollbar-hide">
              <button
                onClick={() => { setActiveBracket('all'); setActiveGenre(null); }}
                className={`flex-shrink-0 px-4 py-2 rounded-md text-sm font-semibold transition-all ${activeBracket === 'all' ? 'bg-elevated text-cream shadow' : 'text-dim hover:text-muted'}`}
              >
                All
                <span className="ml-1.5 text-[10px] opacity-50">{items.length}</span>
              </button>
              {BRACKETS.map(bracket => {
                const count = bracketCounts[bracket] ?? 0;
                return (
                  <button
                    key={bracket}
                    onClick={() => { setActiveBracket(bracket); setActiveGenre(null); }}
                    className={`flex-shrink-0 px-4 py-2 rounded-md text-sm font-semibold transition-all ${activeBracket === bracket ? 'bg-elevated text-cream shadow' : 'text-dim hover:text-muted'} ${count === 0 ? 'opacity-40' : ''}`}
                  >
                    {BRACKET_LABELS[bracket]}
                    <span className="ml-1.5 text-[10px] opacity-50">{count}</span>
                  </button>
                );
              })}
            </div>

            {availableGenres.length > 0 && (
              <div className="flex gap-2 overflow-x-auto pb-2 scrollbar-thin scrollbar-thumb-zinc-800">
                <button
                  onClick={() => setActiveGenre(null)}
                  className={`flex-shrink-0 px-3 py-1 rounded-full text-xs font-medium border transition-all ${!activeGenre ? 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30' : 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600'}`}
                >
                  {t('ranking.allGenres')}
                </button>
                {availableGenres.map(genre => (
                  <button
                    key={genre}
                    onClick={() => setActiveGenre(genre === activeGenre ? null : genre)}
                    className={`flex-shrink-0 px-3 py-1 rounded-full text-xs font-medium border transition-all ${genre === activeGenre ? 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30' : 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600'}`}
                  >
                    {genre}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        {/* --- Tab Content --- */}
        {activeTab === 'ranking' && (
          <ErrorBoundary>
          <div className="space-y-4">
            {TIERS.map((tier) => (
              <TierRow
                key={tier}
                tier={tier}
                items={localizedItems.filter((i) => i.tier === tier).sort((a, b) => a.rank - b.rank)}
                scoreMap={scoreMap}
                showScores={showScores}
                onDrop={(e, tier) => handleDrop(e, tier)}
                onDropOnItem={handleDropOnItem}
                onDragStart={handleDragStart}
                onDelete={removeItem}
              />
            ))}
          </div>
          </ErrorBoundary>
        )}

        {activeTab === 'watchlist' && (
          <Watchlist items={localizedWatchlist} onRemove={removeFromWatchlist} onRank={rankFromWatchlist} />
        )}

        {activeTab === 'stats' && user && <StatsView items={localizedItems} userId={user.id} />}

        {activeTab === 'feed' && user && (
          <SocialFeedView userId={user.id} />
        )}

        {activeTab === 'discover' && user && (
          <DiscoverView
            userId={user.id}
            onMovieClick={(id) => setSearchParams({ movieId: id })}
            onSaveForLater={(movie) => {
              void addToWatchlist(movie);
            }}
          />
        )}

        {activeTab === 'groups' && user && (
          <div className="space-y-4">
            {/* Group sub-tabs */}
            <div className="flex gap-2 bg-card rounded-xl p-1 border border-border overflow-x-auto">
              {[
                { key: 'parties' as const, label: t('groups.parties') },
                { key: 'rankings' as const, label: t('groups.rankings') },
                { key: 'polls' as const, label: t('groups.polls') },
                { key: 'lists' as const, label: t('groups.lists') },
                { key: 'badges' as const, label: t('groups.badges') },
              ].map(({ key, label }) => (
                <button
                  key={key}
                  onClick={() => setGroupSubTab(key)}
                  className={`flex-1 px-3 py-2 rounded-lg text-sm font-semibold transition-all whitespace-nowrap ${groupSubTab === key
                    ? 'bg-elevated text-cream shadow-lg'
                    : 'text-dim hover:text-muted'
                    }`}
                >
                  {label}
                </button>
              ))}
            </div>
            {groupSubTab === 'parties' && <WatchPartyView userId={user.id} />}
            {groupSubTab === 'rankings' && <GroupRankingView userId={user.id} />}
            {groupSubTab === 'polls' && <MoviePollView userId={user.id} />}
            {groupSubTab === 'lists' && <MovieListView userId={user.id} />}
            {groupSubTab === 'badges' && <AchievementsView userId={user.id} />}
          </div>
        )}
      </main>

      <ErrorBoundary>
      <AddMediaModal
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setPreselectedForRank(null);
          setMigrationState(null);
        }}
        onAdd={handleAddItem}
        onSaveForLater={addToWatchlist}
        currentItems={items}
        watchlistIds={watchlistIds}
        preselectedItem={migrationState ? migrationState.item : preselectedForRank}
        preselectedTier={migrationState ? migrationState.targetTier : undefined}
        onCompare={handleCompareLog}
        onMovieInfoClick={(id) => setSearchParams({ movieId: id })}
      />
      </ErrorBoundary>

      {/* Deep linked Movie Modal */}
      {linkedMovieId && (() => {
        const foundItem = items.find(i => i.id === linkedMovieId);
        return (
          <MediaDetailModal
            tmdbId={linkedMovieId}
            onClose={() => {
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
            }}
            onSaveForLater={(movie) => {
              addToWatchlist(movie);
              // Close the modal
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
            }}
            onStartRanking={(movie) => {
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
              setPreselectedForRank(movie);
              setIsModalOpen(true);
            }}
            onOpenJournal={(movieId) => {
              // Find or create a RankedItem to open journal
              const ranked = items.find(i => i.id === movieId);
              if (ranked) {
                const newParams = new URLSearchParams(searchParams);
                newParams.delete('movieId');
                setSearchParams(newParams);
                setJournalSheetItem(ranked);
              }
            }}
            {...(foundItem ? { initialItem: foundItem } : {})}
          />
        );
      })()}

      {/* Journal Entry Sheet (after ranking) */}
      {journalSheetItem && user && (
        <ErrorBoundary>
        <JournalEntrySheet
          isOpen={!!journalSheetItem}
          item={journalSheetItem}
          userId={user.id}
          onDismiss={() => setJournalSheetItem(null)}
          onSaved={() => { setJournalSheetItem(null); setToastMessage(t('journal.saved')); }}
        />
        </ErrorBoundary>
      )}

      {toastMessage && (
        <Toast message={toastMessage} onDone={() => setToastMessage(null)} />
      )}
    </div>
  );
};

export default RankingAppPage;
