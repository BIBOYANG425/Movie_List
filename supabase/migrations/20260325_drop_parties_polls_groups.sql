-- Drop Watch Parties
DROP TABLE IF EXISTS watch_party_members CASCADE;
DROP TABLE IF EXISTS watch_parties CASCADE;

-- Drop Group Rankings
DROP TABLE IF EXISTS group_ranking_entries CASCADE;
DROP TABLE IF EXISTS group_ranking_members CASCADE;
DROP TABLE IF EXISTS group_rankings CASCADE;

-- Drop Movie Polls
DROP TABLE IF EXISTS movie_poll_votes CASCADE;
DROP TABLE IF EXISTS movie_poll_options CASCADE;
DROP TABLE IF EXISTS movie_polls CASCADE;

-- Update notifications type constraint to remove deleted types
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check CHECK (
  type IN ('new_follower','review_like','list_like','badge_unlock','ranking_comment','journal_tag')
);
