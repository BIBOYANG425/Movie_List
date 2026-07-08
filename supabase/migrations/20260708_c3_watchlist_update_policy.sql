-- ============================================================================
-- C3 Task 4 — watchlist_items owner UPDATE policy (audit finding B3a)
--
-- Plan:  docs/plans/2026-07-08-c3-web-blocking-fixes.md (Task 4)
-- Audit: docs/plans/audits/2026-07-08-c3-watchlist-discover-web-audit.md (B3, part a)
--
-- ============================================================================
-- WHAT THIS FIXES (B3a): `watchlist_items` ships SELECT/INSERT/DELETE owner
-- policies (supabase_schema.sql:146-148) but NO UPDATE policy, while the tv/book
-- watchlist tables both carry the owner UPDATE policy
-- (supabase_tv_rankings.sql:105-108, supabase_book_rankings.sql). movie is the
-- odd one out. `addToWatchlist` writes with a merge-duplicates UPSERT on
-- (user_id, tmdb_id) (RankingAppPage.tsx:633-642); whenever the client-side
-- pre-check is stale (second device/tab, or B1's dual-format rows), the upsert's
-- ON CONFLICT DO UPDATE path is RLS-denied and the save fails with revert+toast
-- for an item the user legitimately re-added. This policy unblocks that path.
--
-- Prod state verified 2026-07-08: `watchlist_items` has DELETE/INSERT/SELECT but
-- NO UPDATE policy (audit Global Constraints).
--
-- Apply-then-merge safe: purely additive; grants an UPDATE path that the
-- deployed code's upsert already assumes. Runbook order vs the taste-recompute
-- drop does not matter (they touch disjoint objects).
--
-- Policy name + clause form mirror the tv/book tables' owner-UPDATE policy
-- exactly and follow the existing `watchlist_items` policy-name convention
-- ("Users can <verb> own watchlist", supabase_schema.sql:146-148).
-- ============================================================================
-- ROLLBACK (verbatim):
--   DROP POLICY "Users can update own watchlist" ON watchlist_items;
-- ============================================================================

CREATE POLICY "Users can update own watchlist"
  ON watchlist_items FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
