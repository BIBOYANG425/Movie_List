-- Phase 1 profile/social patch for existing Supabase projects.
-- Run this once in Supabase SQL editor.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_url text;

DROP POLICY IF EXISTS "Users can view related follows" ON public.friend_follows;
DROP POLICY IF EXISTS "Authenticated users can view follows" ON public.friend_follows;
CREATE POLICY "Authenticated users can view follows" ON public.friend_follows
  FOR SELECT
  USING (auth.role() = 'authenticated');
