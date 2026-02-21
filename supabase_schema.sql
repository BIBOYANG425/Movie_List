-- profiles table (linked to Supabase Auth)
CREATE TABLE profiles (
  id uuid REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  username citext NOT NULL UNIQUE,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
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

-- RLS
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_rankings ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlist_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE friend_follows ENABLE ROW LEVEL SECURITY;

-- profiles policies
CREATE POLICY "Authenticated users can view profiles" ON profiles FOR SELECT USING (auth.role() = 'authenticated');
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
CREATE POLICY "Authenticated users can view follows" ON friend_follows FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "Users can insert own follows" ON friend_follows FOR INSERT WITH CHECK (
  auth.uid() = follower_id
);
CREATE POLICY "Users can delete own follows" ON friend_follows FOR DELETE USING (
  auth.uid() = follower_id
);

-- Trigger to auto-create profile on signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, username)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'username', split_part(NEW.email, '@', 1)));
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE handle_new_user();
