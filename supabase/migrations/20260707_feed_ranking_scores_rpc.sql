-- 20260707_feed_ranking_scores_rpc.sql
--
-- get_feed_ranking_scores: batch live-score lookup for feed cards.
-- Fixes audit finding B1 (docs/plans/audits/2026-07-07-c1-feed-web-audit.md §2):
-- the client-side getRankingScores issued 3 selects per distinct actor plus one
-- count per (actor, table, tier) — ~90–100 serialized queries per 20-card feed
-- page. This RPC answers the same question in one round trip.
--
-- pairs: [{"user_id": "<uuid>", "tmdb_id": "<text>", "media_type": "movie"|"tv_season"|"book"}]
--   (≤ ~40 per call). Only user_id and tmdb_id are read; media_type is accepted
--   and ignored — all three ranking tables are scanned and the tmdb_id formats
--   are disjoint (numeric string / tv_{id}_s{n} / ol_*), so no cross-table
--   collision is possible.
--
-- Returns one row per requested (user_id, tmdb_id) that has a visible ranking
-- row; pairs with no visible ranking produce NO row (callers treat a missing
-- key as "no score" and hide the badge — identical to today's behavior).
--
-- Score parity with services/rankingAlgorithm.ts computeTierScore (pinned by
-- services/__tests__/feedScores.test.ts):
--   * tier ranges: S 9.0–10.0, A 7.0–8.9, B 5.0–6.9, C 3.0–4.9, D 0.1–2.9
--   * single item in tier -> midpoint of range, rounded to 1dp
--   * otherwise linear interpolation: rank_position 0 (best) -> hi,
--     rank_position tier_total-1 (worst) -> lo, rounded to 1dp
--   * tier_total is counted per (table, user, tier) — same per-table semantics
--     as the old client-side counts.
--
-- Rounding: JS uses Math.round(x*10)/10, which rounds exact halves UP.
-- Postgres round(float8) rounds half-to-even (banker's), which would diverge
-- (e.g. A-tier single item: 7.95 -> 7.9 instead of 8.0). round(numeric, 1)
-- rounds half-AWAY-FROM-ZERO, which for these strictly positive scores is
-- identical to half-up, i.e. to Math.round. All operands below are exact
-- decimals (lo/hi have 1dp, counts and positions are integers), so the CASE
-- expression is numeric throughout; the ::numeric cast makes the intent
-- explicit and guards against any operand ever becoming float.
--
-- Known (accepted) divergence vs the legacy JS client, D tier only: for D-tier
-- populations >= 57 (n = tier_total - 1 a multiple of 56: totals 57, 113,
-- 169, ...), exact-half values such as 28.5/10 round UP here (numeric
-- half-away-from-zero — the mathematically correct result), where the old
-- client's float arithmetic landed at e.g. 2.8499999999999996 and rounded
-- DOWN. Up to 4 positions per such large D tier may therefore show a +0.1
-- score-badge shift vs the legacy client (e.g. 2.8 -> 2.9). S/A/B/C never
-- diverge (verified exhaustively over tier totals 1..2000). If a 2.8 -> 2.9
-- style report comes in, this is that — not an RPC bug.
--
-- security invoker: ranking-table RLS stays in force for the caller, so tier
-- totals are computed over exactly the rows the viewer can already see
-- (own / followed / public-profile actors) — identical to the old client-side
-- counts. Strangers' rankings return no rows and the score badge stays hidden.
--
-- Rollback: drop function public.get_feed_ranking_scores(jsonb);

create or replace function public.get_feed_ranking_scores(pairs jsonb)
returns table (user_id uuid, tmdb_id text, score numeric)
language sql
stable
security invoker
set search_path = public
as $$
  with req as (
    select distinct (e->>'user_id')::uuid as user_id, e->>'tmdb_id' as tmdb_id
    from jsonb_array_elements(coalesce(pairs, '[]'::jsonb)) e
  ),
  users as (select distinct user_id from req),
  -- Filter early: only rows for requested users are scanned. All of a user's
  -- rows (not just requested tmdb_ids) must enter the window count, because
  -- the score depends on the full tier population.
  all_rows as (
    select 'm' as src, r.user_id, r.tmdb_id, r.tier, r.rank_position
      from user_rankings r join users u using (user_id)
    union all
    select 'tv', r.user_id, r.tmdb_id, r.tier, r.rank_position
      from tv_rankings r join users u using (user_id)
    union all
    select 'bk', r.user_id, r.tmdb_id, r.tier, r.rank_position
      from book_rankings r join users u using (user_id)
  ),
  counted as (
    select src, user_id, tmdb_id, tier, rank_position,
           count(*) over (partition by src, user_id, tier) as tier_total
    from all_rows
  )
  select c.user_id, c.tmdb_id,
    round(
      (case when c.tier_total <= 1 then (t.lo + t.hi) / 2
            else t.lo + (t.hi - t.lo) * (c.tier_total - 1 - c.rank_position)
                        / (c.tier_total - 1)
       end)::numeric, 1) as score
  from counted c
  join req using (user_id, tmdb_id)
  join (values ('S', 9.0, 10.0),
               ('A', 7.0, 8.9),
               ('B', 5.0, 6.9),
               ('C', 3.0, 4.9),
               ('D', 0.1, 2.9))
       as t(tier, lo, hi) on t.tier = c.tier;
$$;

grant execute on function public.get_feed_ranking_scores(jsonb) to authenticated;
