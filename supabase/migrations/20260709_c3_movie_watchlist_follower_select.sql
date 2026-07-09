-- ============================================================================
-- C3-iOS Part A, Task 1 — movie watchlist FOLLOWER-VISIBLE SELECT (Q2)
--
-- Plan:  docs/plans/2026-07-09-c3-ios-part-a.md (Task 1)
-- Audit: docs/plans/audits/2026-07-08-c3-watchlist-discover-web-audit.md (C3 RLS
--        asymmetry — the three-table watchlist SELECT split)
-- Verify: docs/plans/audits/2026-07-09-c3-ios-verification.md (controller probes)
--
-- ============================================================================
-- OWNER ADJUDICATION (Q2, 2026-07-09): the movie watchlist becomes
-- FOLLOWER-VISIBLE, aligning it with the tv/book watchlists.
--
-- WHY:
--   1. Twin exclusion (iOS): TasteRepository must read a *friend's* movie
--      watchlist to exclude already-watchlisted titles from Twin suggestions.
--      Today `watchlist_items` ships an owner-ONLY combined SELECT policy
--      (supabase_schema.sql:146), so a follower reading a followee's movie
--      watchlist gets 0 rows — the exclusion silently no-ops on iOS.
--   2. tv/book parity: `tv_watchlist_items`
--      (supabase_tv_rankings.sql:88-99) and `book_watchlist_items`
--      (supabase_book_rankings.sql:92-103) each carry TWO SELECT policies —
--      an owner SELECT plus a "view followed users … watchlist" follower
--      SELECT. movie is the odd table out. This closes the documented
--      three-table RLS asymmetry.
--
-- WHAT THIS DOES: drops the movie owner-only combined SELECT policy and
-- recreates the tv/book two-policy shape VERBATIM in structure:
--   * an owner SELECT (same name/clause as before), plus
--   * a follower SELECT keyed on friend_follows (the follows table), joined
--     `follower_id = auth.uid() AND following_id = watchlist_items.user_id`
--     — identical join direction to tv/book.
-- Postgres OR-combines multiple permissive SELECT policies, so owner rows AND
-- followee rows are both visible, exactly as on tv/book.
--
-- SCOPE: SELECT policies only. The owner INSERT
-- (supabase_schema.sql:147), owner DELETE (supabase_schema.sql:148), and owner
-- UPDATE (supabase/migrations/20260708_c3_watchlist_update_policy.sql) policies
-- are UNTOUCHED — followers still cannot write another user's watchlist.
--
-- Prod state verified 2026-07-08 (audit Global Constraints): `watchlist_items`
-- carried owner-only SELECT/INSERT/DELETE; the owner UPDATE policy landed via
-- 20260708_c3_watchlist_update_policy.sql. This migration touches ONLY the
-- SELECT surface and must not clobber that UPDATE policy.
--
-- Apply-then-merge safe: purely additive on the read surface (broadens SELECT
-- to followers, mirroring two already-deployed tables); no write path changes.
-- ============================================================================
-- ROLLBACK (verbatim — restores the exact original owner-only combined SELECT):
--   DROP POLICY "Users can view followed users watchlist" ON watchlist_items;
--   DROP POLICY "Users can view own watchlist" ON watchlist_items;
--   CREATE POLICY "Users can view own watchlist" ON watchlist_items FOR SELECT USING (auth.uid() = user_id);
-- ============================================================================

-- Drop the current owner-only combined SELECT policy (exact original name).
DROP POLICY "Users can view own watchlist" ON watchlist_items;

-- Recreate the owner SELECT (unchanged clause; mirrors tv/book own-SELECT).
CREATE POLICY "Users can view own watchlist"
  ON watchlist_items FOR SELECT
  USING (auth.uid() = user_id);

-- Add the follower SELECT (mirrors tv/book follower-SELECT verbatim in
-- structure: friend_follows join, follower_id = auth.uid(),
-- following_id = <table>.user_id).
CREATE POLICY "Users can view followed users watchlist"
  ON watchlist_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = watchlist_items.user_id
    )
  );
