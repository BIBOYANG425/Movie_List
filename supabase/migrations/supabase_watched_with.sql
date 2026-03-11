-- Add watched_with_user_ids to user_rankings and tv_rankings
ALTER TABLE user_rankings ADD COLUMN IF NOT EXISTS watched_with_user_ids uuid[] DEFAULT '{}';
ALTER TABLE tv_rankings ADD COLUMN IF NOT EXISTS watched_with_user_ids uuid[] DEFAULT '{}';

-- Index for querying "who watched this with me"
CREATE INDEX IF NOT EXISTS idx_rankings_watched_with ON user_rankings USING gin(watched_with_user_ids);
CREATE INDEX IF NOT EXISTS idx_tv_rankings_watched_with ON tv_rankings USING gin(watched_with_user_ids);
