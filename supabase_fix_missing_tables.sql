-- ============================================================================
-- Fix: Create missing tables + Enable RLS + Add missing RPC functions
-- Applied 2026-02-24
-- ============================================================================

-- ── 1. review_likes table ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.review_likes (
  review_id uuid NOT NULL REFERENCES public.movie_reviews(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (review_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_review_likes_review ON public.review_likes(review_id);
CREATE INDEX IF NOT EXISTS idx_review_likes_user ON public.review_likes(user_id);

ALTER TABLE public.review_likes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view review likes" ON public.review_likes
  FOR SELECT USING (true);
CREATE POLICY "Users can like reviews" ON public.review_likes
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can unlike reviews" ON public.review_likes
  FOR DELETE USING (auth.uid() = user_id);


-- ── 2. shared_watchlist_votes table ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shared_watchlist_votes (
  item_id uuid NOT NULL REFERENCES public.shared_watchlist_items(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now() NOT NULL,
  PRIMARY KEY (item_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_shared_watchlist_votes_item ON public.shared_watchlist_votes(item_id);
CREATE INDEX IF NOT EXISTS idx_shared_watchlist_votes_user ON public.shared_watchlist_votes(user_id);

ALTER TABLE public.shared_watchlist_votes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view watchlist votes" ON public.shared_watchlist_votes
  FOR SELECT USING (true);
CREATE POLICY "Users can vote" ON public.shared_watchlist_votes
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can unvote" ON public.shared_watchlist_votes
  FOR DELETE USING (auth.uid() = user_id);


-- ── 3. Enable RLS on tables that had it disabled ───────────────────────────
ALTER TABLE public.movie_reviews ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view reviews" ON public.movie_reviews
  FOR SELECT USING (true);
CREATE POLICY "Users can create own reviews" ON public.movie_reviews
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own reviews" ON public.movie_reviews
  FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own reviews" ON public.movie_reviews
  FOR DELETE USING (auth.uid() = user_id);

ALTER TABLE public.shared_watchlists ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view shared watchlists" ON public.shared_watchlists
  FOR SELECT USING (true);
CREATE POLICY "Users can create shared watchlists" ON public.shared_watchlists
  FOR INSERT WITH CHECK (auth.uid() = created_by);
CREATE POLICY "Creators can update shared watchlists" ON public.shared_watchlists
  FOR UPDATE USING (auth.uid() = created_by);
CREATE POLICY "Creators can delete shared watchlists" ON public.shared_watchlists
  FOR DELETE USING (auth.uid() = created_by);

ALTER TABLE public.shared_watchlist_members ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view watchlist members" ON public.shared_watchlist_members
  FOR SELECT USING (true);
CREATE POLICY "Users can join watchlists" ON public.shared_watchlist_members
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can leave watchlists" ON public.shared_watchlist_members
  FOR DELETE USING (auth.uid() = user_id);

ALTER TABLE public.shared_watchlist_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view watchlist items" ON public.shared_watchlist_items
  FOR SELECT USING (true);
CREATE POLICY "Users can add watchlist items" ON public.shared_watchlist_items
  FOR INSERT WITH CHECK (auth.uid() = added_by);
CREATE POLICY "Users can remove own watchlist items" ON public.shared_watchlist_items
  FOR DELETE USING (auth.uid() = added_by);


-- ── 4. RPC functions for review like counts ────────────────────────────────
CREATE OR REPLACE FUNCTION public.increment_review_likes(review_id_param uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.movie_reviews
  SET like_count = like_count + 1
  WHERE id = review_id_param;
END;
$$;

CREATE OR REPLACE FUNCTION public.decrement_review_likes(review_id_param uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.movie_reviews
  SET like_count = GREATEST(like_count - 1, 0)
  WHERE id = review_id_param;
END;
$$;
