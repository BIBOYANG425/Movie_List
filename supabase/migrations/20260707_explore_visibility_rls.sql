-- 20260707_explore_visibility_rls.sql
-- Fixes audit finding B2 (docs/plans/audits/2026-07-07-c1-feed-web-audit.md):
-- the phase-5 explore SELECT policy on activity_events let ANY authenticated user
-- read ANYONE's ranking_add/review/list_create/milestone events, ignoring
-- profiles.profile_visibility (default 'friends'). Adjudicated decision Q2
-- (controller, 2026-07-07): explore shows events from 'public'-visibility
-- profiles only.
--
-- Column verification (against supabase_schema.sql + 20260406_public_profiles.sql):
--   profiles PK           = profiles.id (uuid REFERENCES auth.users(id))
--   visibility column     = profiles.profile_visibility
--   visibility values     = CHECK (profile_visibility IN ('public', 'friends', 'private'))
--   activity_events FK    = activity_events.actor_id REFERENCES profiles(id)
--
-- The phase-2 policy "Users can view own and followed activity events"
-- (supabase_phase2_activity_patch.sql:56-68) is intentionally left untouched;
-- permissive policies OR together. The replacement policy below is nevertheless
-- self-contained (own OR followed OR public) per the plan, so explore-mode
-- consumers such as the upcoming get_feed_page RPC can rely on this single
-- policy doing the work under security invoker semantics.
--
-- The event-type list from the original policy is retained on the public branch:
-- B2 only narrows WHO is globally readable, not WHICH event types. Without it,
-- public-visibility users' ranking_move/ranking_remove rows would leak to
-- non-followers — a semantics change no finding asks for (audit §1.6).
--
-- ROLLBACK: drop the new policy, then re-run the original phase-5 policy quoted
-- verbatim below (from supabase_phase5_social_feed.sql:47-53):
--
--   DROP POLICY "Users can read own, followed, and public-profile activity events"
--     ON public.activity_events;
--
--   -- 5. Add Explore RLS policy on activity_events (allow reading public event types from anyone)
--   CREATE POLICY "Authenticated users can read public activity events"
--     ON activity_events FOR SELECT
--     USING (
--       auth.uid() IS NOT NULL
--       AND event_type IN ('ranking_add', 'review', 'list_create', 'milestone')
--     );

BEGIN;

-- Drop by exact name; fail loudly if prod has drifted from the migration files.
DROP POLICY "Authenticated users can read public activity events"
  ON public.activity_events;

CREATE POLICY "Users can read own, followed, and public-profile activity events"
  ON public.activity_events
  FOR SELECT
  USING (
    auth.uid() = actor_id
    OR EXISTS (
      SELECT 1
      FROM public.friend_follows
      WHERE public.friend_follows.follower_id = auth.uid()
        AND public.friend_follows.following_id = public.activity_events.actor_id
    )
    OR (
      auth.uid() IS NOT NULL
      AND event_type IN ('ranking_add', 'review', 'list_create', 'milestone')
      AND EXISTS (
        SELECT 1
        FROM public.profiles p
        WHERE p.id = public.activity_events.actor_id
          AND p.profile_visibility = 'public'
      )
    )
  );

COMMIT;
