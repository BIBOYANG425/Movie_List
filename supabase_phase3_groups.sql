-- ============================================================================
-- Phase 3: Group Experiences — Supabase Migration
-- Run in Supabase SQL Editor
-- ============================================================================

-- ── Watch Parties ────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS watch_parties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  host_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  title text NOT NULL,
  movie_tmdb_id text,
  movie_title text,
  movie_poster_url text,
  scheduled_at timestamptz NOT NULL,
  location text,
  notes text,
  status text DEFAULT 'upcoming' CHECK (status IN ('upcoming','active','completed','cancelled')),
  created_at timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_watch_parties_host ON watch_parties(host_id);
CREATE INDEX IF NOT EXISTS idx_watch_parties_scheduled ON watch_parties(scheduled_at);

CREATE TABLE IF NOT EXISTS watch_party_members (
  party_id uuid REFERENCES watch_parties(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  rsvp text DEFAULT 'pending' CHECK (rsvp IN ('pending','going','maybe','not_going')),
  responded_at timestamptz,
  PRIMARY KEY (party_id, user_id)
);

-- RLS for watch_parties
ALTER TABLE watch_parties ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read parties they host or are invited to" ON watch_parties
  FOR SELECT USING (
    host_id = auth.uid()
    OR id IN (SELECT party_id FROM watch_party_members WHERE user_id = auth.uid())
  );
CREATE POLICY "Users can create parties" ON watch_parties
  FOR INSERT WITH CHECK (host_id = auth.uid());
CREATE POLICY "Hosts can update their parties" ON watch_parties
  FOR UPDATE USING (host_id = auth.uid());
CREATE POLICY "Hosts can delete their parties" ON watch_parties
  FOR DELETE USING (host_id = auth.uid());

-- RLS for watch_party_members
ALTER TABLE watch_party_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read party membership" ON watch_party_members
  FOR SELECT USING (
    user_id = auth.uid()
    OR party_id IN (SELECT id FROM watch_parties WHERE host_id = auth.uid())
  );
CREATE POLICY "Hosts can invite members" ON watch_party_members
  FOR INSERT WITH CHECK (
    party_id IN (SELECT id FROM watch_parties WHERE host_id = auth.uid())
    OR user_id = auth.uid()
  );
CREATE POLICY "Members can update their own RSVP" ON watch_party_members
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Hosts or self can remove members" ON watch_party_members
  FOR DELETE USING (
    user_id = auth.uid()
    OR party_id IN (SELECT id FROM watch_parties WHERE host_id = auth.uid())
  );


-- ── Group Rankings ───────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS group_rankings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  created_by uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  description text,
  created_at timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_group_rankings_creator ON group_rankings(created_by);

CREATE TABLE IF NOT EXISTS group_ranking_members (
  group_id uuid REFERENCES group_rankings(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  joined_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (group_id, user_id)
);

CREATE TABLE IF NOT EXISTS group_ranking_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid REFERENCES group_rankings(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  poster_url text,
  year text,
  genres text[],
  tier text CHECK (tier IN ('S','A','B','C','D')) NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  UNIQUE (group_id, user_id, tmdb_id)
);

CREATE INDEX IF NOT EXISTS idx_group_ranking_entries_group ON group_ranking_entries(group_id);

-- RLS for group_rankings
ALTER TABLE group_rankings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read group rankings" ON group_rankings
  FOR SELECT USING (
    created_by = auth.uid()
    OR id IN (SELECT group_id FROM group_ranking_members WHERE user_id = auth.uid())
  );
CREATE POLICY "Users can create group rankings" ON group_rankings
  FOR INSERT WITH CHECK (created_by = auth.uid());
CREATE POLICY "Creators can update" ON group_rankings
  FOR UPDATE USING (created_by = auth.uid());
CREATE POLICY "Creators can delete" ON group_rankings
  FOR DELETE USING (created_by = auth.uid());

-- RLS for group_ranking_members
ALTER TABLE group_ranking_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read membership" ON group_ranking_members
  FOR SELECT USING (
    user_id = auth.uid()
    OR group_id IN (SELECT id FROM group_rankings WHERE created_by = auth.uid())
  );
CREATE POLICY "Creators can add members" ON group_ranking_members
  FOR INSERT WITH CHECK (
    group_id IN (SELECT id FROM group_rankings WHERE created_by = auth.uid())
    OR user_id = auth.uid()
  );
CREATE POLICY "Self or creator can remove" ON group_ranking_members
  FOR DELETE USING (
    user_id = auth.uid()
    OR group_id IN (SELECT id FROM group_rankings WHERE created_by = auth.uid())
  );

-- RLS for group_ranking_entries
ALTER TABLE group_ranking_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read entries" ON group_ranking_entries
  FOR SELECT USING (
    group_id IN (
      SELECT group_id FROM group_ranking_members WHERE user_id = auth.uid()
      UNION SELECT id FROM group_rankings WHERE created_by = auth.uid()
    )
  );
CREATE POLICY "Members can add entries" ON group_ranking_entries
  FOR INSERT WITH CHECK (
    user_id = auth.uid()
    AND group_id IN (
      SELECT group_id FROM group_ranking_members WHERE user_id = auth.uid()
      UNION SELECT id FROM group_rankings WHERE created_by = auth.uid()
    )
  );
CREATE POLICY "Users can update own entries" ON group_ranking_entries
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Users can delete own entries" ON group_ranking_entries
  FOR DELETE USING (user_id = auth.uid());


-- ── Movie Polls ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS movie_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  question text NOT NULL DEFAULT 'What should we watch?',
  expires_at timestamptz,
  is_closed boolean DEFAULT false,
  created_at timestamptz DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_movie_polls_creator ON movie_polls(created_by);

CREATE TABLE IF NOT EXISTS movie_poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid REFERENCES movie_polls(id) ON DELETE CASCADE NOT NULL,
  tmdb_id text NOT NULL,
  title text NOT NULL,
  poster_url text,
  position int NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_movie_poll_options_poll ON movie_poll_options(poll_id);

CREATE TABLE IF NOT EXISTS movie_poll_votes (
  poll_id uuid REFERENCES movie_polls(id) ON DELETE CASCADE,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  option_id uuid REFERENCES movie_poll_options(id) ON DELETE CASCADE NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (poll_id, user_id)
);

-- RLS for movie_polls
ALTER TABLE movie_polls ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read polls from people they follow" ON movie_polls
  FOR SELECT USING (
    created_by = auth.uid()
    OR created_by IN (SELECT following_id FROM friend_follows WHERE follower_id = auth.uid())
  );
CREATE POLICY "Users can create polls" ON movie_polls
  FOR INSERT WITH CHECK (created_by = auth.uid());
CREATE POLICY "Creators can update polls" ON movie_polls
  FOR UPDATE USING (created_by = auth.uid());
CREATE POLICY "Creators can delete polls" ON movie_polls
  FOR DELETE USING (created_by = auth.uid());

-- RLS for movie_poll_options
ALTER TABLE movie_poll_options ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Options readable with poll" ON movie_poll_options
  FOR SELECT USING (
    poll_id IN (SELECT id FROM movie_polls WHERE
      created_by = auth.uid()
      OR created_by IN (SELECT following_id FROM friend_follows WHERE follower_id = auth.uid())
    )
  );
CREATE POLICY "Creators can add options" ON movie_poll_options
  FOR INSERT WITH CHECK (
    poll_id IN (SELECT id FROM movie_polls WHERE created_by = auth.uid())
  );
CREATE POLICY "Creators can delete options" ON movie_poll_options
  FOR DELETE USING (
    poll_id IN (SELECT id FROM movie_polls WHERE created_by = auth.uid())
  );

-- RLS for movie_poll_votes
ALTER TABLE movie_poll_votes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Votes readable by participants" ON movie_poll_votes
  FOR SELECT USING (
    user_id = auth.uid()
    OR poll_id IN (SELECT id FROM movie_polls WHERE created_by = auth.uid())
  );
CREATE POLICY "Users can vote once" ON movie_poll_votes
  FOR INSERT WITH CHECK (user_id = auth.uid());
CREATE POLICY "Users can change vote" ON movie_poll_votes
  FOR UPDATE USING (user_id = auth.uid());
CREATE POLICY "Users can remove vote" ON movie_poll_votes
  FOR DELETE USING (user_id = auth.uid());
