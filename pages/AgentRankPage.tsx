// pages/AgentRankPage.tsx
//
// The /agent-rank route (P3-B, task B1) — the rank ceremony that opens INSIDE
// iMessage via a Photon mini-app card, authenticated by a short-TTL JWT carried
// in the URL fragment.
//
// Flow (all data + writes ride the token-scoped client, never the app session):
//   1. Read location.hash → { token, mediaId } via parseRankFragment, then
//      history.replaceState away the hash so the token never lingers.
//   2. Build a token-scoped supabase client (createTokenClientFromEnv) and
//      validate it by reading the user's own profile row (a cheap RLS read).
//      401/expired → friendly "ask chris for a fresh one" state.
//   3. Fetch the movie via the tmdb-proxy under the same token; load the user's
//      existing MOVIE tier list through the tokened client.
//   4. Run the EXISTING ceremony (RankingFlowModal: tier → notes → H2H →
//      placement). Already-ranked → show current placement + re-rank affordance.
//   5. On placement, persist via the SAME contract path the app uses — a
//      user_rankings upsert of the placed row + set_tier_order RPC + stub +
//      ranking_add/ranking_move event — every call through the tokened client.
//   6. Completion screen: "placed. {title} sits in {tier}. go tell chris."
//
// Reuse, not fork: RankingFlowModal + TierPicker/NotesStep/ComparisonStep +
// RankingSession are the app's own ceremony; setTierOrder / logRankingActivityEvent
// / createStub are the app's own writers (each gained an optional client arg
// defaulting to the module supabase, so normal app behavior is unchanged).
//
// H2H 1:1 parity (owner, 2026-07-13): every comparison choice writes the same
// comparison_logs row the main webapp writes (tokened client), the row mapper
// is the shared services/agentRankRows one (a local copy dropped
// watched_with_user_ids and the upsert wiped companions on re-rank), and a
// re-rank seed carries watchedWithUserIds through the ceremony.
//
// Header last reviewed: 2026-07-13

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { RankedItem, Tier, ComparisonLogEntry } from '../types';
import { classifyBracket } from '../services/rankingAlgorithm';
import { setTierOrder } from '../services/tierOrder';
import { logRankingActivityEvent } from '../services/activityService';
import { createStub } from '../services/stubService';
import { RankingFlowModal } from '../components/media/RankingFlowModal';
import { createTokenClientFromEnv } from '../lib/agentSupabase';
import { parseRankFragment } from '../services/agentRankFragment';
import { fetchAgentRankMovie } from '../services/agentRankMovie';
import { rowToRankedItem } from '../services/agentRankRows';
import { useTranslation } from '../contexts/LanguageContext';

type Phase =
  | { kind: 'loading' }
  | { kind: 'error'; reason: 'nolink' | 'expired' | 'unsupported' | 'notfound' }
  | { kind: 'ready' }
  | { kind: 'ceremony' }
  | { kind: 'done'; title: string; tier: Tier };

interface SeededState {
  client: SupabaseClient;
  userId: string;
  movie: RankedItem;
  items: RankedItem[];
  existing: RankedItem | null; // the movie's current rank, if already placed
}

const Spinner = () => (
  <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
);

const FullScreen: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div className="min-h-screen bg-background text-foreground flex items-center justify-center p-6">
    <div className="w-full max-w-sm text-center flex flex-col items-center gap-4">
      {children}
    </div>
  </div>
);

const AgentRankPage: React.FC = () => {
  const { t, locale } = useTranslation();
  const [phase, setPhase] = useState<Phase>({ kind: 'loading' });
  const [seed, setSeed] = useState<SeededState | null>(null);

  const tmdbLanguage = useMemo(() => (locale === 'zh' ? 'zh-CN' : 'en-US'), [locale]);

  // ── Bootstrap: parse fragment, strip it, auth, fetch movie + tier list ──────
  useEffect(() => {
    let cancelled = false;

    (async () => {
      const parsed = parseRankFragment(window.location.hash);

      // Strip the fragment from the address bar so the token never lingers,
      // regardless of whether it parsed (a bad token should still not sit in
      // history). Guarded so tests / non-browser contexts don't throw.
      try {
        if (window.location.hash) {
          window.history.replaceState(
            null,
            '',
            window.location.pathname + window.location.search,
          );
        }
      } catch {
        /* no-op */
      }

      if (!parsed) {
        if (!cancelled) setPhase({ kind: 'error', reason: 'nolink' });
        return;
      }

      if (parsed.kind !== 'movie') {
        // B1 ceremony reuses the movie flow (user_rankings). TV is a follow-up.
        if (!cancelled) setPhase({ kind: 'error', reason: 'unsupported' });
        return;
      }

      const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
      const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
      const client = createTokenClientFromEnv(parsed.token);

      // Validate the token with a cheap RLS read of the caller's own profile.
      const { data: userData, error: userError } = await client.auth.getUser();
      if (userError || !userData?.user) {
        if (!cancelled) setPhase({ kind: 'error', reason: 'expired' });
        return;
      }
      const userId = userData.user.id;

      // Fetch the movie (tmdb-proxy under the same token) + the user's existing
      // movie tier list, in parallel.
      const [movie, rankingsRes] = await Promise.all([
        fetchAgentRankMovie(supabaseUrl, anonKey, parsed.token, parsed.tmdbNumericId, tmdbLanguage),
        client
          .from('user_rankings')
          .select('*')
          .eq('user_id', userId)
          .order('rank_position', { ascending: true }),
      ]);

      if (rankingsRes.error) {
        // An RLS/auth failure on the read means the token is no good.
        if (!cancelled) setPhase({ kind: 'error', reason: 'expired' });
        return;
      }

      if (!movie) {
        if (!cancelled) setPhase({ kind: 'error', reason: 'notfound' });
        return;
      }

      const items = (rankingsRes.data ?? []).map(rowToRankedItem);
      const existing = items.find((i) => i.id === movie.id) ?? null;

      if (!cancelled) {
        setSeed({ client, userId, movie, items, existing });
        setPhase({ kind: 'ready' });
      }
    })();

    return () => {
      cancelled = true;
    };
    // Intentionally run once on mount — the fragment is read a single time.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Persist the placed film via the app's contract path (tokened client) ────
  const persistPlacement = useCallback(
    async (placed: RankedItem): Promise<boolean> => {
      if (!seed) return false;
      const { client, userId, items, existing } = seed;
      const isReRank = Boolean(existing);
      const eventType: 'ranking_add' | 'ranking_move' = isReRank ? 'ranking_move' : 'ranking_add';

      // Compute the placed row's target tier membership (mirrors addItem).
      const tierItems = items
        .filter((i) => i.tier === placed.tier && i.id !== placed.id)
        .sort((a, b) => a.rank - b.rank);
      const newTierList = [...tierItems];
      newTierList.splice(placed.rank, 0, placed);
      const targetOrder = newTierList.map((i) => i.id);
      const newRankPosition = targetOrder.indexOf(placed.id);

      // 1. Upsert ONLY the placed row (insert-or-replace on user_id,tmdb_id).
      const { error: rowError } = await client.from('user_rankings').upsert(
        {
          user_id: userId,
          tmdb_id: placed.id,
          title: placed.title,
          year: placed.year,
          poster_url: placed.posterUrl,
          type: placed.type,
          genres: placed.genres,
          director: placed.director ?? null,
          tier: placed.tier,
          rank_position: newRankPosition,
          bracket: placed.bracket ?? classifyBracket(placed.genres),
          primary_genre: placed.genres[0] ?? null,
          notes: placed.notes ?? null,
          watched_with_user_ids: placed.watchedWithUserIds ?? [],
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'user_id,tmdb_id' },
      );
      if (rowError) {
        console.error('agent-rank: failed to save ranking:', rowError);
        return false;
      }

      // 2. Compact the target tier's positions via the RPC (tokened client).
      if (targetOrder.length > 0) {
        const { error } = await setTierOrder('movie', placed.tier, targetOrder, client);
        if (error) {
          console.error('agent-rank: failed to set tier order:', error);
          return false;
        }
      }

      // 3. Activity event (add vs move) — tokened client.
      await logRankingActivityEvent(
        userId,
        {
          id: placed.id,
          title: placed.title,
          tier: placed.tier,
          posterUrl: placed.posterUrl,
          notes: placed.notes,
          year: placed.year,
          watchedWithUserIds: eventType === 'ranking_move' ? undefined : placed.watchedWithUserIds,
        },
        eventType,
        client,
      );

      // 4. Ticket stub (fire-and-forget) — tokened client.
      createStub(
        userId,
        {
          mediaType: 'movie',
          tmdbId: placed.id,
          title: placed.title,
          posterPath: placed.posterUrl,
          tier: placed.tier,
        },
        client,
      ).catch(() => {});

      return true;
    },
    [seed],
  );

  // ── Comparison log — the SAME per-choice row the main webapp writes ─────────
  // RankingAppPage.handleCompareLog inserts one comparison_logs row per H2H
  // choice; the agent ceremony must too (RLS: insert own rows — the fragment
  // JWT is a real user token, so auth.uid() = user_id passes). Fire-and-forget:
  // a log failure never blocks the ceremony.
  const handleCompareLog = useCallback(
    async (log: ComparisonLogEntry) => {
      if (!seed) return;
      try {
        await seed.client.from('comparison_logs').insert({
          user_id: seed.userId,
          session_id: log.sessionId,
          movie_a_tmdb_id: log.movieAId,
          movie_b_tmdb_id: log.movieBId,
          winner: log.winner,
          round: log.round,
          phase: log.phase,
          question_text: log.questionText,
        });
      } catch (err) {
        console.error('agent-rank: failed to log comparison:', err);
      }
    },
    [seed],
  );

  const handleAdd = useCallback(
    (placed: RankedItem) => {
      const title = placed.title;
      const tier = placed.tier;
      // Optimistically show the completion screen; persistence runs in the
      // background. A failure logs but keeps the friendly screen — the agent's
      // ~20-min rank-check reads the real DB state.
      setPhase({ kind: 'done', title, tier });
      void persistPlacement(placed).then((ok) => {
        if (!ok) {
          // Keep the seed's items so a retry (re-rank) recomputes from a fresh
          // read next time; here we just surface nothing louder than the log.
        } else if (seed) {
          // Update local seed so a subsequent re-rank sees this placement.
          setSeed({
            ...seed,
            items: [
              ...seed.items.filter((i) => i.id !== placed.id),
              placed,
            ],
            existing: placed,
          });
        }
      });
    },
    [persistPlacement, seed],
  );

  // ── Render ──────────────────────────────────────────────────────────────────
  if (phase.kind === 'loading') {
    return (
      <FullScreen>
        <Spinner />
        <p className="text-muted-foreground text-sm">{t('agentRank.loading')}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'error') {
    const message =
      phase.reason === 'expired'
        ? t('agentRank.expired')
        : phase.reason === 'unsupported'
          ? t('agentRank.unsupported')
          : phase.reason === 'notfound'
            ? t('agentRank.notFound')
            : t('agentRank.noLink');
    return (
      <FullScreen>
        <h1 className="text-xl font-bold">{t('agentRank.title')}</h1>
        <p className="text-muted-foreground">{message}</p>
      </FullScreen>
    );
  }

  if (phase.kind === 'done') {
    return (
      <FullScreen>
        <h1 className="text-2xl font-bold">{t('agentRank.placedTitle')}</h1>
        <p className="text-foreground">
          {t('agentRank.placedBody')
            .replace('{title}', phase.title)
            .replace('{tier}', phase.tier)}
        </p>
        <p className="text-muted-foreground text-sm">{t('agentRank.closeHint')}</p>
      </FullScreen>
    );
  }

  // ready / ceremony — seed is guaranteed non-null here.
  if (!seed) {
    return (
      <FullScreen>
        <Spinner />
      </FullScreen>
    );
  }

  const { movie, items, existing } = seed;

  // Already-ranked (and not yet in an active ceremony) → show current placement
  // + a re-rank affordance that opens the SAME ceremony.
  if (existing && phase.kind === 'ready') {
    return (
      <FullScreen>
        <h1 className="text-xl font-bold">{t('agentRank.title')}</h1>
        {movie.posterUrl && (
          <img
            src={movie.posterUrl}
            alt={movie.title}
            className="w-32 aspect-[2/3] object-cover rounded-xl shadow-lg"
          />
        )}
        <p className="text-foreground">
          {t('agentRank.alreadyRanked')
            .replace('{title}', existing.title)
            .replace('{tier}', existing.tier)}
        </p>
        <button
          onClick={() => setPhase({ kind: 'ceremony' })}
          className="mt-2 px-6 py-3 rounded-full bg-gold text-black font-semibold active:scale-[0.97] transition-transform"
        >
          {t('agentRank.reRank')}
        </button>
      </FullScreen>
    );
  }

  // Fresh rank OR re-rank in progress → run the ceremony. Seed the modal with
  // the movie and the user's existing movie tier list. A re-rank seed carries
  // the row's watchedWithUserIds — the placement upsert writes
  // `watched_with_user_ids: placed.watchedWithUserIds ?? []`, so dropping them
  // here would wipe the user's companions on every card re-rank.
  const seedItem: RankedItem = existing
    ? {
        ...movie,
        tier: existing.tier,
        rank: existing.rank,
        notes: existing.notes,
        watchedWithUserIds: existing.watchedWithUserIds,
      }
    : movie;

  return (
    <div className="min-h-screen bg-background">
      <RankingFlowModal
        isOpen
        onClose={() => {
          // Closing the ceremony without placing → fall back to a friendly
          // full-screen so the sheet isn't left blank.
          if (existing) {
            setPhase({ kind: 'ready' });
          } else {
            setPhase({ kind: 'error', reason: 'nolink' });
          }
        }}
        onAdd={handleAdd}
        selectedItem={seedItem}
        currentItems={items}
        onCompare={handleCompareLog}
      />
    </div>
  );
};

export default AgentRankPage;
