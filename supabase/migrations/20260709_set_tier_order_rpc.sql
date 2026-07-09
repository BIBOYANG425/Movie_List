-- 20260709_set_tier_order_rpc.sql
--
-- set_tier_order: the single positions-only, delete-aware tier-order primitive.
-- Foundation for the C4 blocking fixes (docs/plans/2026-07-09-c4-blocking-fixes-plan.md,
-- Q4 adjudication) — every web/iOS reorder, cross-tier move, and delete-compaction
-- routes through this one function so the position-integrity invariant is enforced
-- in ONE place instead of by convention across a dozen client write paths.
--
-- ── Position-integrity invariant (the contract this RPC enforces) ────────────
-- Within each (user_id, tier) and per media table, rank_position is contiguous
-- 0..n-1 with no duplicates (0 = best). Nothing else in the DB enforces it (the
-- only constraint is UNIQUE(user_id, tmdb_id)); consumers that do arithmetic on
-- the raw column break loudly when it is violated (get_feed_ranking_scores emits
-- out-of-range scores on a gap; iOS H2H ordering is nondeterministic on a dup —
-- audit findings B1/B2/B5). This function recomputes positions server-side from
-- row_number() so its output is ALWAYS invariant-compliant regardless of the
-- (possibly corrupt) positions it read.
--
-- ── FULL-MEMBERSHIP caller contract (READ THIS — partial arrays corrupt) ─────
-- p_tmdb_ids MUST be the tier's ENTIRE intended membership, in the desired
-- order. This function only touches rows whose tmdb_id appears in the array;
-- rows of the same user+tier that are NOT in the array are left UNTOUCHED at
-- their old positions. So a partial array does NOT "insert a few" — it ORPHANS
-- the unlisted rows' positions (they keep stale indices, re-creating the very
-- gap/dup corruption this RPC exists to prevent). Callers moving an item BETWEEN
-- tiers must call TWICE: once for the source tier (its membership minus the
-- departed id) and once for the target tier (its membership plus the arriving
-- id). See Task 2/Task 3 of the C4 plan.
--
-- ── Delete-aware compaction ──────────────────────────────────────────────────
-- Positions are assigned by row_number() OVER (ORDER BY ordinality) - 1 computed
-- over ONLY the ids in the array that ACTUALLY EXIST as the caller's rows. Ids in
-- the array with no matching row (deleted/never-ranked) are silently skipped, so
-- the surviving rows still compact to a contiguous 0..k-1. A caller can therefore
-- pass a stale membership snapshot that names a since-deleted id and the result is
-- still gap-free.
--
-- ── Duplicate ids: deduped on FIRST occurrence ───────────────────────────────
-- If p_tmdb_ids lists the same id more than once (realistic input: an iOS
-- same-tier re-rank splices an id into a membership array that already contains
-- it — C4 Task 4), the id is ranked at its FIRST occurrence and later
-- occurrences are ignored: ['a','a','b'] behaves exactly like ['a','b']
-- (a -> 0, b -> 1, returns 2). Without the dedup (the min(ord) GROUP BY in each
-- branch), a doubled id would yield two candidate positions for one row and
-- UPDATE..FROM would pick one arbitrarily — silently gapping the tier.
--
-- ── Why UPDATE-only (resurrect-proof — fixes B6) ─────────────────────────────
-- This function performs a single UPDATE per media branch and is STRUCTURALLY
-- INCAPABLE of INSERT: it can only move rows that already exist. The old client
-- write shape re-sent full rows upserted on (user_id, tmdb_id) from an in-memory
-- snapshot, so a device with a stale snapshot could RE-INSERT a row another device
-- had just deleted (upsert = insert-or-update), undoing the delete (audit B6). An
-- UPDATE that joins to existing rows cannot resurrect a deleted one — a deleted id
-- simply matches nothing and is skipped. (INSERTs of genuinely new rows — ceremony
-- adds — stay on the client's own upsert path; this RPC never creates a row.)
--
-- ── Tier value validation ────────────────────────────────────────────────────
-- All three tables declare CHECK (tier IN ('S','A','B','C','D')). An invalid
-- p_tier therefore fails the table CHECK constraint naturally on the UPDATE — no
-- extra guard is added here, and none is needed.
--
-- ── Signature / semantics ────────────────────────────────────────────────────
--   set_tier_order(p_media text, p_tier text, p_tmdb_ids text[]) returns integer
--   * p_media: 'movie' -> user_rankings, 'tv' -> tv_rankings, 'book' -> book_rankings.
--       Three STATIC branches (no dynamic SQL). Any other value RAISEs with
--       errcode 22023 (invalid_parameter_value).
--   * p_tier: the tier all listed rows are set to (enables cross-tier moves —
--       the same call both re-tiers AND repositions).
--   * p_tmdb_ids: full intended membership, ordered best-first (index 0 -> pos 0).
--       NULL or empty array is a no-op returning 0 (no rows read or written).
--   * returns: the number of rows actually updated (missing ids not counted).
--
-- security invoker: runs as the caller. The own-rows UPDATE RLS policies on all
-- three tables already gate the write to auth.uid()'s rows —
--   user_rankings  "Users can update own rankings"      (supabase_schema.sql:142)
--   tv_rankings    "Users can update own tv rankings"   (supabase_tv_rankings.sql:54-57)
--   book_rankings  "Users can update own book rankings" (supabase_book_rankings.sql:56-59)
-- (existence re-confirmed by C3's migration verification, which UPDATEs
-- user_rankings under a set-role authenticated JWT). The explicit
-- `user_id = auth.uid()` predicate in each branch is belt-and-suspenders: it
-- makes the intent legible and lets the join prune to the caller's rows even in
-- any bypass context, while RLS is the actual authority under invoker.
--
-- volatile: this function WRITES. It is left VOLATILE (the default) — do NOT mark
-- it STABLE/IMMUTABLE (a STABLE function may not modify the database and the
-- planner may skip re-executing it).
--
-- Rollback: drop function public.set_tier_order(text, text, text[]);

create or replace function public.set_tier_order(
  p_media text,
  p_tier text,
  p_tmdb_ids text[]
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_updated integer := 0;
begin
  -- Empty / NULL membership -> no-op. Nothing is read or written.
  if p_tmdb_ids is null or cardinality(p_tmdb_ids) = 0 then
    return 0;
  end if;

  if p_media = 'movie' then
    with ordered as (
      -- Dedup repeated ids on their FIRST occurrence (min(ord)), then join the
      -- requested order to the caller's EXISTING rows only. Ids that match no
      -- row drop out here, so the row_number() over the surviving set compacts
      -- to a contiguous 0..k-1 (delete-aware, duplicate-safe).
      select r.id,
             (row_number() over (order by d.ord) - 1) as new_pos
        from (
          select u.tmdb_id, min(u.ord) as ord
            from unnest(p_tmdb_ids) with ordinality as u(tmdb_id, ord)
           group by u.tmdb_id
        ) d
        join user_rankings r
          on r.tmdb_id = d.tmdb_id
         and r.user_id = auth.uid()
    )
    update user_rankings r
       set tier = p_tier,
           rank_position = o.new_pos,
           updated_at = now()
      from ordered o
     where r.id = o.id;
    get diagnostics v_updated = row_count;

  elsif p_media = 'tv' then
    with ordered as (
      select r.id,
             (row_number() over (order by d.ord) - 1) as new_pos
        from (
          select u.tmdb_id, min(u.ord) as ord
            from unnest(p_tmdb_ids) with ordinality as u(tmdb_id, ord)
           group by u.tmdb_id
        ) d
        join tv_rankings r
          on r.tmdb_id = d.tmdb_id
         and r.user_id = auth.uid()
    )
    update tv_rankings r
       set tier = p_tier,
           rank_position = o.new_pos,
           updated_at = now()
      from ordered o
     where r.id = o.id;
    get diagnostics v_updated = row_count;

  elsif p_media = 'book' then
    with ordered as (
      select r.id,
             (row_number() over (order by d.ord) - 1) as new_pos
        from (
          select u.tmdb_id, min(u.ord) as ord
            from unnest(p_tmdb_ids) with ordinality as u(tmdb_id, ord)
           group by u.tmdb_id
        ) d
        join book_rankings r
          on r.tmdb_id = d.tmdb_id
         and r.user_id = auth.uid()
    )
    update book_rankings r
       set tier = p_tier,
           rank_position = o.new_pos,
           updated_at = now()
      from ordered o
     where r.id = o.id;
    get diagnostics v_updated = row_count;

  else
    raise exception 'set_tier_order: unknown p_media %, expected one of movie|tv|book', p_media
      using errcode = '22023';  -- invalid_parameter_value
  end if;

  return v_updated;
end;
$$;

grant execute on function public.set_tier_order(text, text, text[]) to authenticated;

-- Hygiene: functions are executable by PUBLIC by default; this is a write
-- primitive, so restrict execution to authenticated only. (Consequence for
-- anon is nil anyway — auth.uid() is NULL so the join matches nothing — but
-- prod primitives should not be PUBLIC-executable on posture alone.)
revoke all on function public.set_tier_order(text, text, text[]) from public;
