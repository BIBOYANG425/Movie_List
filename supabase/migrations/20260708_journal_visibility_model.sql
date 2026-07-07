-- ============================================================================
-- C2 Task 2 — Journal visibility model (audit finding B2; enables B1/B3
-- correctness; §4 retires the Task 1 compat view after deploy)
--
-- Plan:  docs/plans/2026-07-08-c2-journal-web-fixes.md (Task 2)
-- Audit: docs/plans/audits/2026-07-08-c2-journal-web-audit.md
--
-- ============================================================================
-- RUNBOOK ORDER (see also 20260708_journal_search_likes_hardening.sql header):
--   1. Apply THIS file FIRST — §§1-3 rewrite journal_entries SELECT RLS.
--      §4 (compat-view drop) is a guarded no-op on this first pass because
--      the view does not exist yet.
--   2. Apply 20260708_journal_search_likes_hardening.sql (its invoker search
--      RPC and journal_entry_likes policies EXISTS-reference journal_entries
--      and are only correct under the policy created here).
--   3. Merge + deploy the web build from this PR (reviewService reads
--      journal_entry_likes directly; nothing reads journal_likes anymore).
--   4. AFTER the web deploy, run §4 (the single DO block, quoted there) once
--      more to drop the transitional journal_likes compat view. Do NOT re-run
--      §§1-3 (the DROP POLICY would fail — by design, it fails loudly).
-- ============================================================================
-- APPLY-THEN-MERGE COMPATIBILITY (old deployed web code, between DB apply and
-- web deploy of this PR):
--   * The old bundle select('*')s journal_entries — rows it may READ shrink
--     to the resolved-visibility set (that is the fix: NULL-override rows of
--     non-public profiles stop being world-readable). Owner reads unchanged.
--   * personal_takeaway still rides along on rows the old bundle can read;
--     the column exclusion is client-side (this PR's code) — the RLS change
--     is row-level, so nothing breaks, it just narrows.
--   * No RPC/table this file touches is called by the old bundle except
--     journal_likes, which §4 defers past the web deploy precisely for that
--     bundle's sake (its reads degrade to isLikedByViewer=false via the
--     `?? []` fallbacks in reviewService if §4 runs early — annoying, not
--     breaking).
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Column/relation verification (same drill as the C1 explore migration):
--      profiles PK              = profiles.id (uuid REFERENCES auth.users(id))
--      visibility column        = profiles.profile_visibility
--                                 text NOT NULL DEFAULT 'friends'
--                                 CHECK (IN ('public','friends','private'))
--                                 (20260406_public_profiles.sql:2-3)
--      journal_entries owner FK = journal_entries.user_id REFERENCES profiles
--                                 (supabase_journal_entries.sql:15) — a
--                                 profiles row always exists for an entry.
--      override column          = journal_entries.visibility_override
--                                 text NULL, CHECK (IN ('public','friends',
--                                 'private')) (supabase_journal_entries.sql)
--      follow relation          = friend_follows(follower_id, following_id);
--                                 "friends" = viewer FOLLOWS author (one-way,
--                                 same relation as the C1 feed policy).
--      supporting index         = idx_profiles_visibility ON profiles
--                                 (id, profile_visibility)
--                                 (20260406_public_profiles.sql:47).
-- ────────────────────────────────────────────────────────────────────────────

-- ────────────────────────────────────────────────────────────────────────────
-- 2. B2 — drop the current SELECT policy. Its `visibility_override IS NULL`
--    branch made every untouched-default entry world-readable, ignoring the
--    author's profiles.profile_visibility entirely (default 'friends' per the
--    C1 B2 adjudication). Dropped by exact name; fails loudly if prod has
--    drifted from the migration files.
--
--    INSERT/UPDATE/DELETE policies ("journal_entries_insert" /
--    "journal_entries_update" / "journal_entries_delete",
--    supabase_journal_entries.sql:88-95) are owner-only and INTENTIONALLY
--    UNTOUCHED — no audit finding asks for a write-policy change.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: drop the new policy, then re-run the previous policy quoted
-- verbatim below (from supabase_fix_critical_rls.sql:19-33):
--
--   DROP POLICY "Users can read journal entries per resolved visibility"
--     ON public.journal_entries;
--
--   DROP POLICY IF EXISTS "journal_entries_select" ON journal_entries;
--   CREATE POLICY "journal_entries_select" ON journal_entries
--   FOR SELECT USING (
--     auth.uid() = user_id
--     OR visibility_override = 'public'
--     OR visibility_override IS NULL
--     OR (
--       visibility_override = 'friends'
--       AND EXISTS (
--         SELECT 1 FROM friend_follows
--         WHERE follower_id = auth.uid()
--           AND following_id = journal_entries.user_id
--       )
--     )
--   );
--
-- (For completeness: "journal_entries_select" itself replaced the original
--  `FOR SELECT USING (true)` policy of the same name from
--  supabase_journal_entries.sql:85-86 — do not roll back to that one.)

BEGIN;

DROP POLICY "journal_entries_select" ON public.journal_entries;

-- ────────────────────────────────────────────────────────────────────────────
-- 3. B2 fix — resolved-visibility SELECT policy. The resolution rule is
--    RESOLVED = COALESCE(visibility_override, profiles.profile_visibility),
--    mirrored one-to-one by resolveVisibility() in services/journalService.ts.
--    Truth table (override × author profile_visibility → who may read):
--
--      override   profile    resolved   readable by
--      ─────────  ─────────  ─────────  ─────────────────────────────────────
--      'public'   (any)      public     owner + all authenticated
--      'friends'  (any)      friends    owner + followers of the author
--      'private'  (any)      private    owner only
--      NULL       public     public     owner + all authenticated
--      NULL       friends    friends    owner + followers of the author
--      NULL       private    private    owner only
--
--    Branch notes:
--      * owner branch: auth.uid() = user_id — always, regardless of profile.
--      * public branch: gated on auth.uid() IS NOT NULL (adjudication:
--        'public' → all AUTHENTICATED; anon reads nothing), resolution via
--        EXISTS against profiles.
--      * friends branch: resolution EXISTS against profiles + the follower
--        EXISTS copied from the C1 explore policy shape
--        (20260707_explore_visibility_rls.sql); anon fails it because
--        follower_id = auth.uid() matches no row for NULL.
--      * 'private' (explicit or resolved) matches no branch → owner only.
--      * a CHECK-violating value (impossible today) matches no branch →
--        fails closed to owner-only.
-- ────────────────────────────────────────────────────────────────────────────

CREATE POLICY "Users can read journal entries per resolved visibility"
  ON public.journal_entries
  FOR SELECT
  USING (
    auth.uid() = user_id
    OR (
      auth.uid() IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = public.journal_entries.user_id
          AND COALESCE(public.journal_entries.visibility_override, p.profile_visibility) = 'public'
      )
    )
    OR (
      EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = public.journal_entries.user_id
          AND COALESCE(public.journal_entries.visibility_override, p.profile_visibility) = 'friends'
      )
      AND EXISTS (
        SELECT 1
        FROM public.friend_follows
        WHERE public.friend_follows.follower_id = auth.uid()
          AND public.friend_follows.following_id = public.journal_entries.user_id
      )
    )
  );

COMMIT;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Retire the transitional journal_likes compat view (created by
--    20260708_journal_search_likes_hardening.sql §5 to keep reviewService.ts
--    and pre-deploy bundles reading). This PR migrates reviewService's two
--    read sites (getReviewsForMovie / getReviewsByUser liked-state) to direct
--    journal_entry_likes reads — self-scoped to the viewer
--    (user_id = auth.uid()), so they pass the new table's RLS trivially —
--    leaving the old deployed bundle as the view's ONLY reader.
--
--    Guarded DO block: a no-op when the view does not exist (runbook step 1,
--    where this file applies BEFORE the hardening file creates it) and when
--    already dropped. Run it again as RUNBOOK STEP 4, after the web deploy:
--
--      DO $drop_compat$
--      BEGIN
--        IF EXISTS (SELECT 1 FROM pg_views
--                   WHERE schemaname = 'public' AND viewname = 'journal_likes')
--        THEN
--          EXECUTE 'DROP VIEW public.journal_likes';
--        END IF;
--      END $drop_compat$;
--
-- ROLLBACK: recreate the view verbatim
--   (from 20260708_journal_search_likes_hardening.sql §5):
--
--   CREATE VIEW journal_likes
--   WITH (security_invoker = true) AS
--     SELECT entry_id, user_id, created_at
--     FROM journal_entry_likes;
--
--   COMMENT ON VIEW journal_likes IS
--     'TRANSITIONAL compat alias for journal_entry_likes (C2 Task 1, 20260708). '
--     'Kept for pre-deploy web bundles and reviewService.ts reads; drop after '
--     'Task 2 migrates reviewService off the old name.';
--
--   GRANT SELECT, INSERT, DELETE ON journal_likes TO authenticated;
--   GRANT ALL ON journal_likes TO service_role;
-- ────────────────────────────────────────────────────────────────────────────

DO $drop_compat$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_views
             WHERE schemaname = 'public' AND viewname = 'journal_likes')
  THEN
    EXECUTE 'DROP VIEW public.journal_likes';
  END IF;
END $drop_compat$;
