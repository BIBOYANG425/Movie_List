-- ============================================================================
-- C7 B2/B3 — Move achievement granting server-side
-- ============================================================================
-- Audit: docs/plans/audits/2026-07-11-c7-smalls-web-audit.md §1.1, B2, B3, D3
--
-- B2: `user_achievements` INSERT RLS was `WITH CHECK (true)` — ANY authenticated
--     user could grant ANY badge to ANY user (supabase_phase4_engagement.sql:149-150).
-- B3: `checkAndGrantBadges` (achievementService.ts) evaluated rules client-side,
--     inserted unchecked (no onConflict), and fired milestone activity events
--     REGARDLESS of whether a grant actually happened.
-- D3: review badges counted the DEAD `movie_reviews` table; reviews have lived in
--     `journal_entries.review_text` since C2 (reviewService.ts:83-88) — corrected
--     here to count non-empty `journal_entries.review_text` rows.
--
-- Fix: drop the client INSERT path entirely (SELECT stays public). Granting moves
-- to a SECURITY DEFINER RPC `grant_achievements()` that recomputes every threshold
-- from auth.uid()'s OWN rows, inserts ON CONFLICT DO NOTHING, writes ONE
-- `badge_unlock` notification per NEW grant only, and returns the newly-granted
-- badge keys. iOS calls the same RPC — client rule math is never ported.
--
-- Table shape (supabase_phase4_engagement.sql:138-143):
--   user_achievements (user_id uuid, badge_key text, unlocked_at timestamptz,
--                      PRIMARY KEY (user_id, badge_key))
-- The PK already provides UNIQUE(user_id, badge_key) — no extra unique index needed
-- (the brief's "UNIQUE(user_id, badge_id)" maps to this existing composite PK;
--  the column is `badge_key`, not `badge_id`). Verified below with a guard.
-- ============================================================================

-- ── 1. Lock down user_achievements RLS ──────────────────────────────────────
-- Drop the wide-open INSERT policy (B2). Clients get NO insert path; the only
-- writer is grant_achievements() (SECURITY DEFINER, runs as owner, bypasses RLS).
DROP POLICY IF EXISTS "System can grant achievements" ON user_achievements;

-- SELECT stays public (badges are publicly visible on profiles — unchanged).
-- No UPDATE/DELETE policies exist on user_achievements, so with the INSERT policy
-- dropped, authenticated/anon clients can only SELECT. Nothing further to lock.
-- (Belt-and-suspenders: drop any UPDATE/DELETE policy that might have been added
--  out-of-band so the table stays read-only to clients.)
DROP POLICY IF EXISTS "Users update own achievements" ON user_achievements;
DROP POLICY IF EXISTS "Users delete own achievements" ON user_achievements;

-- ── 2. Ensure UNIQUE(user_id, badge_key) exists ─────────────────────────────
-- The composite PK already enforces this; assert it so ON CONFLICT is safe. If a
-- future edit ever dropped the PK, add a backing unique index defensively.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.user_achievements'::regclass
      AND contype = 'p'
  ) AND NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'user_achievements'
      AND indexname = 'uq_user_achievements_user_badge'
  ) THEN
    CREATE UNIQUE INDEX uq_user_achievements_user_badge
      ON public.user_achievements (user_id, badge_key);
  END IF;
END $$;

-- ── 3. Verify notifications.type CHECK includes 'badge_unlock' ───────────────
-- Audit D4/§1.1: `badge_unlock` IS in the CHECK (20260325_drop_parties_polls_groups.sql:23)
-- but was NEVER written — createNotification() had zero callers. This RPC becomes
-- its first writer. Guard: if 'badge_unlock' is somehow absent from the CHECK, add
-- it (idempotent) so the notification INSERT below cannot violate the constraint.
DO $$
DECLARE
  check_src text;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'notifications') THEN
    SELECT pg_get_constraintdef(oid) INTO check_src
    FROM pg_constraint
    WHERE conrelid = 'public.notifications'::regclass
      AND conname = 'notifications_type_check';

    IF check_src IS NULL OR position('badge_unlock' in check_src) = 0 THEN
      ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
      ALTER TABLE notifications ADD CONSTRAINT notifications_type_check CHECK (
        type IN ('new_follower','review_like','list_like','badge_unlock','ranking_comment','journal_tag')
      );
    END IF;
  END IF;
END $$;

-- ── 4. grant_achievements() SECURITY DEFINER RPC ────────────────────────────
-- No args — evaluates for auth.uid(). RAISEs if unauthenticated.
-- Ports EVERY grantable rule from services/achievementService.ts (16-badge catalog,
-- 15 grantable; `early_adopter` has no rule — D1, permanently locked, not granted).
-- Rule-by-rule (client source: services/achievementService.ts):
--   MILESTONE (rankCount = user_rankings + tv_rankings + book_rankings, :32):
--     first_rank  >= 1    (:40)
--     rank_10     >= 10   (:41)
--     rank_25     >= 25   (:42)
--     rank_50     >= 50   (:43)
--     rank_100    >= 100  (:44)
--   REVIEW (CORRECTED — D3: client :24/:33 counted dead `movie_reviews`; count
--           journal_entries with NON-EMPTY review_text instead, per reviewService.ts:83-88):
--     first_review >= 1   (:45, corrected source table)
--     review_10    >= 10  (:46, corrected source table)
--   SOCIAL (friend_follows, :25-26,50-53):
--     first_follow  followingCount >= 1  (:50; followingCount = follower_id = me, :25)
--     followers_10  followerCount  >= 10 (:51; followerCount  = following_id = me, :26)
--     followers_50  followerCount  >= 50 (:52)
--     first_list    listCount      >= 1  (:53; movie_lists.created_by = me, :27)
--   TASTE — genre (distinct trimmed non-empty genres across user_rankings.genres, :63-73):
--     genre_5   distinct genres >= 5   (:71)
--     genre_10  distinct genres >= 10  (:72)
--   TASTE — tier (user_rankings.tier, movie-only, :76-85):
--     s_tier_10  tier='S' count >= 10  (:83)
--     d_tier_5   tier='D' count >= 5   (:84)
-- Insert new grants ON CONFLICT DO NOTHING; write one `badge_unlock` notification
-- per NEW grant only; RETURN the newly-granted badge keys (text[]).
CREATE OR REPLACE FUNCTION public.grant_achievements()
RETURNS text[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  uid uuid := auth.uid();
  rank_count int;
  review_count int;
  following_count int;
  follower_count int;
  list_count int;
  genre_count int;
  s_count int;
  d_count int;
  earned text[];
  newly_granted text[];
  k text;
  badge_label text;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'grant_achievements: not authenticated';
  END IF;

  -- ── Counts (mirror achievementService.ts:22-36) ──
  -- rankCount = movies + tv + books (achievementService.ts:32)
  SELECT
    (SELECT count(*) FROM user_rankings WHERE user_id = uid)
    + (SELECT count(*) FROM tv_rankings   WHERE user_id = uid)
    + (SELECT count(*) FROM book_rankings WHERE user_id = uid)
  INTO rank_count;

  -- reviewCount CORRECTED (D3): journal_entries with non-empty review_text,
  -- not the dead movie_reviews table.
  SELECT count(*) INTO review_count
  FROM journal_entries
  WHERE user_id = uid
    AND review_text IS NOT NULL
    AND btrim(review_text) <> '';

  -- followingCount = rows where I am the follower (achievementService.ts:25)
  SELECT count(*) INTO following_count
  FROM friend_follows WHERE follower_id = uid;

  -- followerCount = rows where I am being followed (achievementService.ts:26)
  SELECT count(*) INTO follower_count
  FROM friend_follows WHERE following_id = uid;

  -- listCount = movie_lists I created (achievementService.ts:27)
  SELECT count(*) INTO list_count
  FROM movie_lists WHERE created_by = uid;

  -- distinct trimmed non-empty genres across my movie rankings (achievementService.ts:63-73)
  SELECT count(DISTINCT btrim(g)) INTO genre_count
  FROM user_rankings ur
  CROSS JOIN LATERAL unnest(coalesce(ur.genres, ARRAY[]::text[])) AS g
  WHERE ur.user_id = uid
    AND g IS NOT NULL
    AND btrim(g) <> '';

  -- S / D tier counts, movie-only (achievementService.ts:76-85)
  SELECT
    count(*) FILTER (WHERE tier = 'S'),
    count(*) FILTER (WHERE tier = 'D')
  INTO s_count, d_count
  FROM user_rankings WHERE user_id = uid;

  -- ── Assemble the earned set (every grantable rule; thresholds cited above) ──
  earned := ARRAY[]::text[];
  IF rank_count     >= 1   THEN earned := array_append(earned, 'first_rank');   END IF;
  IF rank_count     >= 10  THEN earned := array_append(earned, 'rank_10');      END IF;
  IF rank_count     >= 25  THEN earned := array_append(earned, 'rank_25');      END IF;
  IF rank_count     >= 50  THEN earned := array_append(earned, 'rank_50');      END IF;
  IF rank_count     >= 100 THEN earned := array_append(earned, 'rank_100');     END IF;
  IF review_count   >= 1   THEN earned := array_append(earned, 'first_review'); END IF;
  IF review_count   >= 10  THEN earned := array_append(earned, 'review_10');    END IF;
  IF following_count >= 1  THEN earned := array_append(earned, 'first_follow'); END IF;
  IF follower_count >= 10  THEN earned := array_append(earned, 'followers_10'); END IF;
  IF follower_count >= 50  THEN earned := array_append(earned, 'followers_50'); END IF;
  IF list_count     >= 1   THEN earned := array_append(earned, 'first_list');   END IF;
  IF genre_count    >= 5   THEN earned := array_append(earned, 'genre_5');      END IF;
  IF genre_count    >= 10  THEN earned := array_append(earned, 'genre_10');     END IF;
  IF s_count        >= 10  THEN earned := array_append(earned, 's_tier_10');    END IF;
  IF d_count        >= 5   THEN earned := array_append(earned, 'd_tier_5');     END IF;

  -- ── Grant only NEW badges; RETURNING gives us exactly what was inserted ──
  WITH ins AS (
    INSERT INTO user_achievements (user_id, badge_key)
    SELECT uid, key
    FROM unnest(earned) AS key
    ON CONFLICT (user_id, badge_key) DO NOTHING
    RETURNING badge_key
  )
  SELECT coalesce(array_agg(badge_key), ARRAY[]::text[]) INTO newly_granted FROM ins;

  -- ── One badge_unlock notification per NEW grant only (D4 first writer) ──
  IF array_length(newly_granted, 1) IS NOT NULL THEN
    FOREACH k IN ARRAY newly_granted LOOP
      badge_label := replace(initcap(replace(k, '_', ' ')), '  ', ' ');
      INSERT INTO notifications (user_id, type, title, body, actor_id, reference_id)
      VALUES (uid, 'badge_unlock', 'Badge unlocked', badge_label, uid, k);
    END LOOP;
  END IF;

  RETURN newly_granted;
END;
$$;

-- ── 5. Grant EXECUTE to authenticated only; revoke from public ──────────────
REVOKE ALL ON FUNCTION public.grant_achievements() FROM public;
-- Supabase default privileges grant EXECUTE on new functions to anon explicitly;
-- revoking PUBLIC does not strip that grant. Defense-in-depth (anon would RAISE
-- on NULL auth.uid() anyway, before any write):
REVOKE EXECUTE ON FUNCTION public.grant_achievements() FROM anon;
GRANT EXECUTE ON FUNCTION public.grant_achievements() TO authenticated;

-- ============================================================================
-- ROLLBACK (verbatim — run to undo this migration)
-- ============================================================================
-- DROP FUNCTION IF EXISTS public.grant_achievements();
-- DROP INDEX IF EXISTS public.uq_user_achievements_user_badge;
-- CREATE POLICY "System can grant achievements" ON user_achievements
--   FOR INSERT WITH CHECK (true);
-- -- (notifications CHECK: no rollback — 'badge_unlock' was already a valid value
-- --  at HEAD per 20260325_drop_parties_polls_groups.sql:23; the guard above only
-- --  re-adds it if it was missing, which it is not, so nothing changed there.)
-- ============================================================================
