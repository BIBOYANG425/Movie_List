-- Phase 2 activity patch for existing Supabase projects.
-- Run this after supabase_schema.sql / supabase_phase1_profile_patch.sql.

CREATE TABLE IF NOT EXISTS public.activity_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('ranking_add','ranking_move','ranking_remove','follow','comment','reaction')),
  target_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  media_tmdb_id text,
  media_title text,
  media_tier text CHECK (media_tier IN ('S','A','B','C','D')),
  media_poster_url text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_activity_event_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX IF NOT EXISTS idx_activity_events_actor_created_at
  ON public.activity_events(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_events_created_at
  ON public.activity_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_events_target_user
  ON public.activity_events(target_user_id);

CREATE TABLE IF NOT EXISTS public.activity_reactions (
  event_id uuid NOT NULL REFERENCES public.activity_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  reaction text NOT NULL DEFAULT 'like' CHECK (reaction IN ('like')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, user_id, reaction)
);

CREATE INDEX IF NOT EXISTS idx_activity_reactions_event
  ON public.activity_reactions(event_id);
CREATE INDEX IF NOT EXISTS idx_activity_reactions_user
  ON public.activity_reactions(user_id);

CREATE TABLE IF NOT EXISTS public.activity_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.activity_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_activity_comment_body CHECK (length(btrim(body)) BETWEEN 1 AND 500)
);

CREATE INDEX IF NOT EXISTS idx_activity_comments_event_created_at
  ON public.activity_comments(event_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_activity_comments_user
  ON public.activity_comments(user_id);

ALTER TABLE public.activity_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own and followed activity events" ON public.activity_events;
CREATE POLICY "Users can view own and followed activity events"
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
  );

DROP POLICY IF EXISTS "Users can insert own activity events" ON public.activity_events;
CREATE POLICY "Users can insert own activity events"
  ON public.activity_events
  FOR INSERT
  WITH CHECK (auth.uid() = actor_id);

DROP POLICY IF EXISTS "Users can view reactions on visible events" ON public.activity_reactions;
CREATE POLICY "Users can view reactions on visible events"
  ON public.activity_reactions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_reactions.event_id
        AND (
          public.activity_events.actor_id = auth.uid()
          OR EXISTS (
            SELECT 1
            FROM public.friend_follows
            WHERE public.friend_follows.follower_id = auth.uid()
              AND public.friend_follows.following_id = public.activity_events.actor_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "Users can insert own reactions on visible events" ON public.activity_reactions;
CREATE POLICY "Users can insert own reactions on visible events"
  ON public.activity_reactions
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_reactions.event_id
        AND (
          public.activity_events.actor_id = auth.uid()
          OR EXISTS (
            SELECT 1
            FROM public.friend_follows
            WHERE public.friend_follows.follower_id = auth.uid()
              AND public.friend_follows.following_id = public.activity_events.actor_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "Users can delete own reactions" ON public.activity_reactions;
CREATE POLICY "Users can delete own reactions"
  ON public.activity_reactions
  FOR DELETE
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can view comments on visible events" ON public.activity_comments;
CREATE POLICY "Users can view comments on visible events"
  ON public.activity_comments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_comments.event_id
        AND (
          public.activity_events.actor_id = auth.uid()
          OR EXISTS (
            SELECT 1
            FROM public.friend_follows
            WHERE public.friend_follows.follower_id = auth.uid()
              AND public.friend_follows.following_id = public.activity_events.actor_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "Users can insert own comments on visible events" ON public.activity_comments;
CREATE POLICY "Users can insert own comments on visible events"
  ON public.activity_comments
  FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND EXISTS (
      SELECT 1
      FROM public.activity_events
      WHERE public.activity_events.id = public.activity_comments.event_id
        AND (
          public.activity_events.actor_id = auth.uid()
          OR EXISTS (
            SELECT 1
            FROM public.friend_follows
            WHERE public.friend_follows.follower_id = auth.uid()
              AND public.friend_follows.following_id = public.activity_events.actor_id
          )
        )
    )
  );

DROP POLICY IF EXISTS "Users can delete own comments" ON public.activity_comments;
CREATE POLICY "Users can delete own comments"
  ON public.activity_comments
  FOR DELETE
  USING (auth.uid() = user_id);
