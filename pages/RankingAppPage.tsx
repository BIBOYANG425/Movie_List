import React, { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ArrowLeft, BarChart2, Bookmark, Compass, LayoutGrid, LogOut, Plus, RotateCcw, UserCircle2, Users, UsersRound } from 'lucide-react';
import { Tier, RankedItem, WatchlistItem, MediaType, Bracket, ComparisonLogEntry } from '../types';
import { TIERS, TIER_SCORE_RANGES, MIN_MOVIES_FOR_SCORES, MAX_TIER_TOLERANCE, BRACKETS, BRACKET_LABELS } from '../constants';
import { computeTierScore } from '../services/rankingAlgorithm';
import { TierRow } from '../components/TierRow';
import { AddMediaModal } from '../components/AddMediaModal';
import { StatsView } from '../components/StatsView';
import { Watchlist } from '../components/Watchlist';
import { FriendsView } from '../components/FriendsView';
import { DiscoverView } from '../components/DiscoverView';
import { WatchPartyView } from '../components/WatchPartyView';
import { GroupRankingView } from '../components/GroupRankingView';
import { MoviePollView } from '../components/MoviePollView';
import { NotificationBell } from '../components/NotificationBell';
import { MovieListView } from '../components/MovieListView';
import { AchievementsView } from '../components/AchievementsView';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import { logRankingActivityEvent } from '../services/friendsService';

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
  const navigate = useNavigate();
  const [items, setItems] = useState<RankedItem[]>([]);
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats' | 'watchlist' | 'friends' | 'discover' | 'groups'>('ranking');
  const [groupSubTab, setGroupSubTab] = useState<'parties' | 'rankings' | 'polls' | 'lists' | 'badges'>('parties');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  const [activeBracket, setActiveBracket] = useState<Bracket | 'all'>('all');
  const [activeGenre, setActiveGenre] = useState<string | null>(null);
  const [migrationState, setMigrationState] = useState<{ item: RankedItem, targetTier: Tier } | null>(null);
  const [preselectedForRank, setPreselectedForRank] = useState<WatchlistItem | null>(null);
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;

    const fetchData = async () => {
      setLoading(true);

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

  // Redirect to movie onboarding if user hasn't reached the threshold
  useEffect(() => {
    if (!loading && items.length < MIN_MOVIES_FOR_SCORES) {
      navigate('/onboarding/movies', { replace: true });
    }
  }, [loading, items.length, navigate]);

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
        bracket: item.bracket,
        notes: item.notes ?? null,
        updated_at: new Date().toISOString(),
      }));
      await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
    }
  };

  const addItem = async (newItem: RankedItem) => {
    if (!user) return;

    setItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier && i.id !== newItem.id)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier && i.id !== newItem.id);

      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      const updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });

    await supabase.from('user_rankings').upsert({
      user_id: user.id,
      tmdb_id: newItem.id,
      title: newItem.title,
      year: newItem.year,
      poster_url: newItem.posterUrl,
      type: newItem.type,
      genres: newItem.genres,
      director: newItem.director ?? null,
      tier: newItem.tier,
      rank_position: newItem.rank,
      notes: newItem.notes ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id,tmdb_id' });

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

  const addToWatchlist = async (item: WatchlistItem) => {
    if (!user) return;
    if (watchlist.some((w) => w.id === item.id)) return;

    setWatchlist((prev) => [item, ...prev]);

    await supabase.from('watchlist_items').upsert({
      user_id: user.id,
      tmdb_id: item.id,
      title: item.title,
      year: item.year,
      poster_url: item.posterUrl,
      type: item.type,
      genres: item.genres,
      director: item.director ?? null,
    }, { onConflict: 'user_id,tmdb_id' });
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

  const scoreMap = useMemo(() => computeScores(filteredItems), [filteredItems]);
  const showScores = filteredItems.length >= MIN_MOVIES_FOR_SCORES;

  if (loading) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 font-sans pb-20">
      <nav className="sticky top-0 z-40 bg-zinc-950/80 backdrop-blur-md border-b border-zinc-800">
        <div className="max-w-5xl mx-auto px-4 h-16 flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Link
              to="/"
              className="inline-flex items-center gap-1 rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-semibold text-zinc-200 hover:border-zinc-500 hover:text-white transition-colors"
            >
              <ArrowLeft size={14} />
              Back to Home
            </Link>
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 bg-indigo-500 rounded-lg flex items-center justify-center font-bold text-white shadow-lg shadow-indigo-500/20">
                M
              </div>
              <span className="font-bold text-xl tracking-tight">Marquee</span>
            </div>
          </div>

          <div className="flex items-center gap-4">
            <div className="hidden md:flex bg-zinc-900 rounded-lg p-1 border border-zinc-800">
              {(['all', 'movie'] as const).map((type) => (
                <button
                  key={type}
                  onClick={() => setFilterType(type)}
                  className={`px-3 py-1.5 rounded-md text-xs font-semibold capitalize transition-all ${filterType === type ? 'bg-zinc-700 text-white shadow' : 'text-zinc-500 hover:text-zinc-300'
                    }`}
                >
                  {type === 'all' ? 'All' : 'Movies'}
                </button>
              ))}
            </div>

            <button
              onClick={() => setIsModalOpen(true)}
              className="bg-white text-black hover:bg-zinc-200 px-4 py-2 rounded-lg font-semibold text-sm flex items-center gap-2 transition-colors"
            >
              <Plus size={16} />
              <span className="hidden sm:inline">Add Item</span>
            </button>

            <button
              onClick={signOut}
              title="Sign out"
              className="p-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-zinc-900 transition-colors"
            >
              <LogOut size={18} />
            </button>
            {user && (
              <Link
                to={`/profile/${user.id}`}
                title="My profile"
                className="p-2 rounded-lg text-zinc-500 hover:text-zinc-300 hover:bg-zinc-900 transition-colors"
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
            <h1 className="text-3xl font-bold mb-2">My Canon</h1>
            <p className="text-zinc-400 text-sm max-w-md">
              Add a movie and rank it head-to-head against your list. Order implies superiority.
            </p>
          </div>

          <div className="flex gap-2">
            <button
              onClick={() => setActiveTab('ranking')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'ranking' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Rankings"
            >
              <LayoutGrid size={20} />
            </button>
            <button
              onClick={() => setActiveTab('watchlist')}
              className={`p-2 rounded-lg transition-colors relative ${activeTab === 'watchlist' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Watch Later"
            >
              <Bookmark size={20} />
              {watchlist.length > 0 && (
                <span className="absolute -top-1 -right-1 w-4 h-4 text-[9px] font-bold rounded-full bg-emerald-500 text-black flex items-center justify-center">
                  {watchlist.length > 9 ? '9+' : watchlist.length}
                </span>
              )}
            </button>
            <button
              onClick={() => setActiveTab('stats')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'stats' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Stats"
            >
              <BarChart2 size={20} />
            </button>
            <button
              onClick={() => setActiveTab('friends')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'friends' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Friends"
            >
              <Users size={20} />
            </button>
            <button
              onClick={() => setActiveTab('discover')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'discover' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Discover"
            >
              <Compass size={20} />
            </button>
            <button
              onClick={() => setActiveTab('groups')}
              className={`p-2 rounded-lg transition-colors ${activeTab === 'groups' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
                }`}
              title="Groups"
            >
              <UsersRound size={20} />
            </button>
            {user && <NotificationBell userId={user.id} />}
            <button
              onClick={handleReset}
              title="Reset rankings"
              className="p-2 rounded-lg text-zinc-600 hover:text-zinc-400 hover:bg-zinc-900 transition-colors"
            >
              <RotateCcw size={18} />
            </button>
          </div>
        </header>

        {activeTab === 'ranking' && (
          <div className="space-y-4">
            <div className="flex bg-zinc-900/50 rounded-lg p-1 overflow-x-auto border border-zinc-800 scrollbar-hide">
              <button
                onClick={() => { setActiveBracket('all'); setActiveGenre(null); }}
                className={`flex-shrink-0 px-4 py-2 rounded-md text-sm font-semibold transition-all ${activeBracket === 'all' ? 'bg-zinc-800 text-white shadow' : 'text-zinc-500 hover:text-zinc-300'}`}
              >
                All Brackets
              </button>
              {BRACKETS.map(bracket => (
                <button
                  key={bracket}
                  onClick={() => { setActiveBracket(bracket); setActiveGenre(null); }}
                  className={`flex-shrink-0 px-4 py-2 rounded-md text-sm font-semibold transition-all ${activeBracket === bracket ? 'bg-zinc-800 text-white shadow' : 'text-zinc-500 hover:text-zinc-300'}`}
                >
                  {BRACKET_LABELS[bracket]}
                </button>
              ))}
            </div>

            {availableGenres.length > 0 && (
              <div className="flex gap-2 overflow-x-auto pb-2 scrollbar-thin scrollbar-thumb-zinc-800">
                <button
                  onClick={() => setActiveGenre(null)}
                  className={`flex-shrink-0 px-3 py-1 rounded-full text-xs font-medium border transition-all ${!activeGenre ? 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30' : 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600'}`}
                >
                  All Genres
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
          <div className="space-y-4">
            {TIERS.map((tier) => (
              <TierRow
                key={tier}
                tier={tier}
                items={filteredItems.filter((i) => i.tier === tier).sort((a, b) => a.rank - b.rank)}
                scoreMap={scoreMap}
                showScores={showScores}
                onDrop={(e, tier) => handleDrop(e, tier)}
                onDropOnItem={handleDropOnItem}
                onDragStart={handleDragStart}
                onDelete={removeItem}
              />
            ))}
          </div>
        )}

        {activeTab === 'watchlist' && (
          <Watchlist items={watchlist} onRemove={removeFromWatchlist} onRank={rankFromWatchlist} />
        )}

        {activeTab === 'stats' && <StatsView items={items} />}

        {activeTab === 'friends' && user && (
          <FriendsView userId={user.id} selfUsername={profile?.username} />
        )}

        {activeTab === 'discover' && user && (
          <DiscoverView userId={user.id} />
        )}

        {activeTab === 'groups' && user && (
          <div className="space-y-4">
            {/* Group sub-tabs */}
            <div className="flex gap-2 bg-zinc-900/60 rounded-xl p-1 border border-zinc-800/50 overflow-x-auto">
              {[
                { key: 'parties' as const, label: 'Parties' },
                { key: 'rankings' as const, label: 'Rankings' },
                { key: 'polls' as const, label: 'Polls' },
                { key: 'lists' as const, label: 'Lists' },
                { key: 'badges' as const, label: 'Badges' },
              ].map(({ key, label }) => (
                <button
                  key={key}
                  onClick={() => setGroupSubTab(key)}
                  className={`flex-1 px-3 py-2 rounded-lg text-sm font-semibold transition-all whitespace-nowrap ${groupSubTab === key
                    ? 'bg-zinc-800 text-white shadow-lg'
                    : 'text-zinc-500 hover:text-zinc-300'
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
      />
    </div>
  );
};

export default RankingAppPage;
