-- 20260707_reactions_comments_explore_rls.sql
-- Fixes audit finding B3 (docs/plans/audits/2026-07-07-c1-feed-web-audit.md):
-- the phase-2 SELECT/INSERT policies on activity_reactions and activity_comments
-- re-stated the own-or-followed event predicate inline, so they were never
-- extended when phase 5 opened explore. Result: reaction/comment counts read as
-- 0 on explore cards from non-followed actors, and every reaction toggle or
-- comment insert on such cards failed RLS (optimistic UI silently reverted).
--
-- Fix: engagement rights track event visibility exactly. Each policy now gates
-- on a bare EXISTS against activity_events; because these policies run as the
-- calling role (security invoker semantics — no definer functions involved),
-- the activity_events SELECT policies apply transitively inside the subquery.
-- Whatever events the caller can SELECT (own / followed / public-profile per
-- 20260707_explore_visibility_rls.sql), they can read and write engagement on.
--
-- Author-only write scoping is preserved:
--   - INSERT policies keep auth.uid() = user_id.
--   - The DELETE policies "Users can delete own reactions" / "Users can delete
--     own comments" (USING auth.uid() = user_id) are intentionally untouched.
--   - Neither table has an UPDATE policy; none is added.
--
-- ROLLBACK: drop the four replacement policies, then re-run the original
-- phase-2 definitions quoted verbatim below
-- (supabase_phase2_activity_patch.sql:76-166):
--
--   CREATE POLICY "Users can view reactions on visible events"
--     ON public.activity_reactions
--     FOR SELECT
--     USING (
--       EXISTS (
--         SELECT 1
--         FROM public.activity_events
--         WHERE public.activity_events.id = public.activity_reactions.event_id
--           AND (
--             public.activity_events.actor_id = auth.uid()
--             OR EXISTS (
--               SELECT 1
--               FROM public.friend_follows
--               WHERE public.friend_follows.follower_id = auth.uid()
--                 AND public.friend_follows.following_id = public.activity_events.actor_id
--             )
--           )
--       )
--     );
--
--   CREATE POLICY "Users can insert own reactions on visible events"
--     ON public.activity_reactions
--     FOR INSERT
--     WITH CHECK (
--       auth.uid() = user_id
--       AND EXISTS (
--         SELECT 1
--         FROM public.activity_events
--         WHERE public.activity_events.id = public.activity_reactions.event_id
--           AND (
--             public.activity_events.actor_id = auth.uid()
--             OR EXISTS (
--               SELECT 1
--               FROM public.friend_follows
--               WHERE public.friend_follows.follower_id = auth.uid()
--                 AND public.friend_follows.following_id = public.activity_events.actor_id
--             )
--           )
--       )
--     );
--
--   CREATE POLICY "Users can view comments on visible events"
--     ON public.activity_comments
--     FOR SELECT
--     USING (
--       EXISTS (
--         SELECT 1
--         FROM public.activity_events
--         WHERE public.activity_events.id = public.activity_comments.event_id
--           AND (
--             public.activity_events.actor_id = auth.uid()
--             OR EXISTS (
--               SELECT 1
--               FROM public.friend_follows
--               WHERE public.friend_follows.follower_id = auth.uid()
--                 AND public.friend_follows.following_id = public.activity_events.actor_id
--             )
--           )
--       )
--     );
--
--   CREATE POLICY "Users can insert own comments on visible events"
--     ON public.activity_comments
--     FOR INSERT
--     WITH CHECK (
--       auth.uid() = user_id
--       AND EXISTS (
--         SELECT 1
--         FROM public.activity_events
--         WHERE public.activity_events.id = public.activity_comments.event_id
--           AND (
--             public.activity_events.actor_id = auth.uid()
--             OR EXISTS (
--               SELECT 1
--               FROM public.friend_follows
--               WHERE public.friend_follows.follower_id = auth.uid()
--                 AND public.friend_follows.following_id = public.activity_events.actor_id
--             )
--           )
--       )
--     );

BEGIN;

-- activity_reactions ---------------------------------------------------------

DROP POLICY "Users can view reactions on visible events"
  ON public.activity_reactions;

CREATE POLICY "Users can view reactions on visible events"
  ON public.activity_reactions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_reactions.event_id
    )
  );

DROP POLICY "Users can insert own reactions on visible events"
  ON public.activity_reactions;

CREATE POLICY "Users can insert own reactions on visible events"
  ON public.activity_reactions
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_reactions.event_id
    )
  );

-- activity_comments ----------------------------------------------------------

DROP POLICY "Users can view comments on visible events"
  ON public.activity_comments;

CREATE POLICY "Users can view comments on visible events"
  ON public.activity_comments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_comments.event_id
    )
  );

DROP POLICY "Users can insert own comments on visible events"
  ON public.activity_comments;

CREATE POLICY "Users can insert own comments on visible events"
  ON public.activity_comments
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_comments.event_id
    )
  );

COMMIT;
