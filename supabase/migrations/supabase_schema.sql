-- profiles table (linked to Supabase Auth)
CREATE TABLE profiles (
  id uuid REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  username citext NOT NULL UNIQUE,
  display_name text,
  bio text,
  avatar_url text,
  avatar_path text,
  onboarding_completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_profile_display_name_len CHECK (display_name IS NULL OR length(display_name) <= 60),
  CONSTRAINT chk_profile_bio_len CHECK (bio IS NULL OR length(bio) <= 280),
  CONSTRAINT chk_username_format CHECK (username ~ '^[a-zA-Z0-9_]{3,32}$')
);

-- user_rankings: stores full movie data + tier + position
CREATE TABLE user_rankings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'movie',
  genres text[] NOT NULL DEFAULT '{}',
  director text,
  tier text NOT NULL CHECK (tier IN ('S','A','B','C','D')),
  rank_position integer NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_tmdb UNIQUE (user_id, tmdb_id)
);

-- watchlist_items
CREATE TABLE watchlist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  year text,
  poster_url text,
  type text NOT NULL DEFAULT 'movie',
  genres text[] NOT NULL DEFAULT '{}',
  director text,
  added_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_watchlist_tmdb UNIQUE (user_id, tmdb_id)
);

-- friend_follows: directed graph (follower -> following)
CREATE TABLE friend_follows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  follower_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  following_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_friend_follow UNIQUE (follower_id, following_id),
  CONSTRAINT chk_friend_no_self_follow CHECK (follower_id <> following_id)
);
CREATE INDEX idx_friend_follows_follower ON friend_follows(follower_id);
CREATE INDEX idx_friend_follows_following ON friend_follows(following_id);

-- activity_events: append-only social timeline items
CREATE TABLE activity_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN ('ranking_add','ranking_move','ranking_remove','follow','comment','reaction')),
  target_user_id uuid REFERENCES profiles(id) ON DELETE SET NULL,
  media_tmdb_id text,
  media_title text,
  media_tier text CHECK (media_tier IN ('S','A','B','C','D')),
  media_poster_url text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_activity_event_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
);
CREATE INDEX idx_activity_events_actor_created_at ON activity_events(actor_id, created_at DESC);
CREATE INDEX idx_activity_events_created_at ON activity_events(created_at DESC);
CREATE INDEX idx_activity_events_target_user ON activity_events(target_user_id);

-- activity_reactions: one reaction per user per event type (currently only "like")
CREATE TABLE activity_reactions (
  event_id uuid NOT NULL REFERENCES activity_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  reaction text NOT NULL DEFAULT 'like' CHECK (reaction IN ('like')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (event_id, user_id, reaction)
);
CREATE INDEX idx_activity_reactions_event ON activity_reactions(event_id);
CREATE INDEX idx_activity_reactions_user ON activity_reactions(user_id);

-- activity_comments: threaded comments on social events
CREATE TABLE activity_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES activity_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_activity_comment_body CHECK (length(btrim(body)) BETWEEN 1 AND 500)
);
CREATE INDEX idx_activity_comments_event_created_at ON activity_comments(event_id, created_at ASC);
CREATE INDEX idx_activity_comments_user ON activity_comments(user_id);

CREATE OR REPLACE FUNCTION set_profiles_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE PROCEDURE set_profiles_updated_at();

-- RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_rankings ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlist_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE friend_follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_comments ENABLE ROW LEVEL SECURITY;

-- profiles policies
CREATE POLICY "Public users can view profiles" ON profiles FOR SELECT USING (true);
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);

-- user_rankings policies
CREATE POLICY "Users can view own rankings" ON user_rankings FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can view followed rankings" ON user_rankings FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM friend_follows
    WHERE friend_follows.follower_id = auth.uid()
      AND friend_follows.following_id = user_rankings.user_id
  )
);
CREATE POLICY "Users can insert own rankings" ON user_rankings FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own rankings" ON user_rankings FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own rankings" ON user_rankings FOR DELETE USING (auth.uid() = user_id);

-- watchlist policies
CREATE POLICY "Users can view own watchlist" ON watchlist_items FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own watchlist" ON watchlist_items FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own watchlist" ON watchlist_items FOR DELETE USING (auth.uid() = user_id);

-- friend_follows policies
CREATE POLICY "Public users can view follows" ON friend_follows FOR SELECT USING (true);
CREATE POLICY "Users can insert own follows" ON friend_follows FOR INSERT WITH CHECK (
  auth.uid() = follower_id
);
CREATE POLICY "Users can delete own follows" ON friend_follows FOR DELETE USING (
  auth.uid() = follower_id
);

-- activity_events policies
CREATE POLICY "Users can view own and followed activity events" ON activity_events FOR SELECT USING (
  auth.uid() = actor_id
  OR EXISTS (
    SELECT 1
    FROM friend_follows
    WHERE friend_follows.follower_id = auth.uid()
      AND friend_follows.following_id = activity_events.actor_id
  )
);
CREATE POLICY "Users can insert own activity events" ON activity_events FOR INSERT WITH CHECK (
  auth.uid() = actor_id
);

-- activity_reactions policies
CREATE POLICY "Users can view reactions on visible events" ON activity_reactions FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM activity_events
    WHERE activity_events.id = activity_reactions.event_id
      AND (
        activity_events.actor_id = auth.uid()
        OR EXISTS (
          SELECT 1
          FROM friend_follows
          WHERE friend_follows.follower_id = auth.uid()
            AND friend_follows.following_id = activity_events.actor_id
        )
      )
  )
);
CREATE POLICY "Users can insert own reactions on visible events" ON activity_reactions FOR INSERT WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1
    FROM activity_events
    WHERE activity_events.id = activity_reactions.event_id
      AND (
        activity_events.actor_id = auth.uid()
        OR EXISTS (
          SELECT 1
          FROM friend_follows
          WHERE friend_follows.follower_id = auth.uid()
            AND friend_follows.following_id = activity_events.actor_id
        )
      )
  )
);
CREATE POLICY "Users can delete own reactions" ON activity_reactions FOR DELETE USING (
  auth.uid() = user_id
);

-- activity_comments policies
CREATE POLICY "Users can view comments on visible events" ON activity_comments FOR SELECT USING (
  EXISTS (
    SELECT 1
    FROM activity_events
    WHERE activity_events.id = activity_comments.event_id
      AND (
        activity_events.actor_id = auth.uid()
        OR EXISTS (
          SELECT 1
          FROM friend_follows
          WHERE friend_follows.follower_id = auth.uid()
            AND friend_follows.following_id = activity_events.actor_id
        )
      )
  )
);
CREATE POLICY "Users can insert own comments on visible events" ON activity_comments FOR INSERT WITH CHECK (
  auth.uid() = user_id
  AND EXISTS (
    SELECT 1
    FROM activity_events
    WHERE activity_events.id = activity_comments.event_id
      AND (
        activity_events.actor_id = auth.uid()
        OR EXISTS (
          SELECT 1
          FROM friend_follows
          WHERE friend_follows.follower_id = auth.uid()
            AND friend_follows.following_id = activity_events.actor_id
        )
      )
  )
);
CREATE POLICY "Users can delete own comments" ON activity_comments FOR DELETE USING (
  auth.uid() = user_id
);

-- avatar storage bucket + policies
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
);

CREATE POLICY "Avatar images are publicly readable" ON storage.objects
FOR SELECT
USING (bucket_id = 'avatars');

CREATE POLICY "Users can upload own avatar objects" ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Users can update own avatar objects" ON storage.objects
FOR UPDATE
USING (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Users can delete own avatar objects" ON storage.objects
FOR DELETE
USING (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- Trigger to auto-create profile on signup
CREATE OR REPLACE FUNCTION generate_unique_username(base_username text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  clean text;
  candidate text;
  suffix integer := 0;
BEGIN
  clean := regexp_replace(lower(coalesce(base_username, '')), '[^a-z0-9_]', '', 'g');
  IF clean = '' THEN
    clean := 'user';
  END IF;
  IF length(clean) < 3 THEN
    clean := rpad(clean, 3, '0');
  END IF;
  clean := left(clean, 24);

  LOOP
    IF suffix = 0 THEN
      candidate := clean;
    ELSE
      candidate := left(clean, 32 - length(suffix::text) - 1) || '_' || suffix::text;
    END IF;

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM profiles p
      WHERE p.username = candidate
    );

    suffix := suffix + 1;
  END LOOP;

  RETURN candidate;
END;
$$;

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  base_username text;
  resolved_username text;
  display_name text;
  avatar text;
BEGIN
  base_username := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'username', ''),
    NULLIF(split_part(NEW.email, '@', 1), ''),
    NULLIF(NEW.raw_user_meta_data->>'name', ''),
    NULLIF(NEW.raw_user_meta_data->>'full_name', ''),
    'user'
  );
  resolved_username := generate_unique_username(base_username);
  display_name := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'name', ''),
    NULLIF(NEW.raw_user_meta_data->>'full_name', '')
  );
  avatar := COALESCE(
    NULLIF(NEW.raw_user_meta_data->>'avatar_url', ''),
    NULLIF(NEW.raw_user_meta_data->>'picture', '')
  );

  INSERT INTO public.profiles (id, username, display_name, avatar_url, onboarding_completed)
  VALUES (NEW.id, resolved_username, display_name, avatar, false);
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE handle_new_user();
