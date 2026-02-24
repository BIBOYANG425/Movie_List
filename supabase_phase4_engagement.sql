-- ============================================================================
-- Phase 4: Content & Engagement — Supabase Migration
-- Run in Supabase SQL Editor
-- ============================================================================

-- ── Notifications ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  type text NOT NULL CHECK (type IN (
    'new_follower', 'review_like', 'party_invite', 'party_rsvp',
    'poll_vote', 'poll_closed', 'list_like', 'badge_unlock',
    'group_invite', 'ranking_comment'
  )),
  title text NOT NULL,
  body text,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reference_id text,       -- generic FK: party_id, poll_id, list_id, etc.
  is_read boolean DEFAULT false NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON notifications(user_id) WHERE NOT is_read;

-- RLS
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own notifications" ON notifications
  FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "System can insert notifications" ON notifications
  FOR INSERT WITH CHECK (true);
CREATE POLICY "Users mark own as read" ON notifications
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Users delete own notifications" ON notifications
  FOR DELETE USING (user_id = auth.uid());


-- ── Movie Lists (Curated Collections) ───────────────────────────────────────

CREATE TABLE IF NOT EXISTS movie_lists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title text NOT NULL,
  description text,
  is_public boolean DEFAULT true NOT NULL,
  cover_url text,
  like_count int DEFAULT 0 NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_movie_lists_creator ON movie_lists(created_by);
CREATE INDEX IF NOT EXISTS idx_movie_lists_public ON movie_lists(created_at DESC) WHERE is_public;

CREATE TABLE IF NOT EXISTS movie_list_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id uuid REFERENCES movie_lists(id) ON DELETE CASCADE NOT NULL,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  poster_url text,
  year text,
  position int NOT NULL DEFAULT 0,
  note text,
  added_at timestamptz DEFAULT now() NOT NULL,
  UNIQUE (list_id, tmdb_id)
);

CREATE INDEX IF NOT EXISTS idx_movie_list_items_list ON movie_list_items(list_id, position);

CREATE TABLE IF NOT EXISTS movie_list_likes (
  list_id uuid REFERENCES movie_lists(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (list_id, user_id)
);

-- RLS for movie_lists
ALTER TABLE movie_lists ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public lists readable by all" ON movie_lists
  FOR SELECT USING (is_public OR created_by = auth.uid());
CREATE POLICY "Users create lists" ON movie_lists
  FOR INSERT WITH CHECK (created_by = auth.uid());
CREATE POLICY "Creators update lists" ON movie_lists
  FOR UPDATE USING (created_by = auth.uid());
CREATE POLICY "Creators delete lists" ON movie_lists
  FOR DELETE USING (created_by = auth.uid());

-- RLS for movie_list_items
ALTER TABLE movie_list_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Items readable with list" ON movie_list_items
  FOR SELECT USING (
    list_id IN (SELECT id FROM movie_lists WHERE is_public OR created_by = auth.uid())
  );
CREATE POLICY "Creators add items" ON movie_list_items
  FOR INSERT WITH CHECK (
    list_id IN (SELECT id FROM movie_lists WHERE created_by = auth.uid())
  );
CREATE POLICY "Creators update items" ON movie_list_items
  FOR UPDATE USING (
    list_id IN (SELECT id FROM movie_lists WHERE created_by = auth.uid())
  );
CREATE POLICY "Creators delete items" ON movie_list_items
  FOR DELETE USING (
    list_id IN (SELECT id FROM movie_lists WHERE created_by = auth.uid())
  );

-- RLS for movie_list_likes
ALTER TABLE movie_list_likes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Likes readable" ON movie_list_likes
  FOR SELECT USING (true);
CREATE POLICY "Users can like" ON movie_list_likes
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Users can unlike" ON movie_list_likes
  FOR DELETE USING (user_id = auth.uid());

-- Trigger to update like_count on movie_lists
CREATE OR REPLACE FUNCTION update_list_like_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE movie_lists SET like_count = like_count + 1 WHERE id = NEW.list_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE movie_lists SET like_count = like_count - 1 WHERE id = OLD.list_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_movie_list_likes ON movie_list_likes;
CREATE TRIGGER trg_movie_list_likes
  AFTER INSERT OR DELETE ON movie_list_likes
  FOR EACH ROW EXECUTE FUNCTION update_list_like_count();


-- ── Achievements ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS user_achievements (
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  badge_key text NOT NULL,
  unlocked_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (user_id, badge_key)
);

-- RLS
ALTER TABLE user_achievements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Achievements publicly readable" ON user_achievements
  FOR SELECT USING (true);
CREATE POLICY "System can grant achievements" ON user_achievements
  FOR INSERT WITH CHECK (true);
