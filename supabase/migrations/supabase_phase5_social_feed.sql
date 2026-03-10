-- Phase 5: Social Feed Migration
-- Expands activity_events, activity_reactions, activity_comments for the social feed,
-- creates feed_mutes table, and adds necessary indexes and RLS policies.

BEGIN;

-- 1. Expand activity_events.event_type CHECK to include new types
ALTER TABLE activity_events DROP CONSTRAINT IF EXISTS activity_events_event_type_check;
ALTER TABLE activity_events ADD CONSTRAINT activity_events_event_type_check
  CHECK (event_type IN ('ranking_add', 'ranking_move', 'ranking_remove', 'review', 'list_create', 'milestone'));

-- 2. Migrate existing 'like' reactions to 'love', then update CHECK
UPDATE activity_reactions SET reaction = 'love' WHERE reaction = 'like';

ALTER TABLE activity_reactions DROP CONSTRAINT IF EXISTS activity_reactions_reaction_check;
ALTER TABLE activity_reactions ADD CONSTRAINT activity_reactions_reaction_check
  CHECK (reaction IN ('fire', 'agree', 'disagree', 'want_to_watch', 'love'));

-- 3. Add parent_comment_id to activity_comments for 1-level reply threading
ALTER TABLE activity_comments
  ADD COLUMN IF NOT EXISTS parent_comment_id uuid REFERENCES activity_comments(id) ON DELETE CASCADE;

-- 4. Create feed_mutes table
CREATE TABLE IF NOT EXISTS feed_mutes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  mute_type text NOT NULL CHECK (mute_type IN ('user', 'movie')),
  target_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, mute_type, target_id)
);

ALTER TABLE feed_mutes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own mutes"
  ON feed_mutes FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own mutes"
  ON feed_mutes FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own mutes"
  ON feed_mutes FOR DELETE
  USING (auth.uid() = user_id);

-- 5. Add Explore RLS policy on activity_events (allow reading public event types from anyone)
CREATE POLICY "Authenticated users can read public activity events"
  ON activity_events FOR SELECT
  USING (
    auth.uid() IS NOT NULL
    AND event_type IN ('ranking_add', 'review', 'list_create', 'milestone')
  );

-- 6. Add index for feed queries
CREATE INDEX IF NOT EXISTS idx_activity_events_type_created
  ON activity_events (event_type, created_at DESC);

COMMIT;
