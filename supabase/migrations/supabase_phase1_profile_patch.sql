-- Phase 1 profile/social patch for existing Supabase projects.
-- Run this once in Supabase SQL editor.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_url text,
  ADD COLUMN IF NOT EXISTS avatar_path text,
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS bio text,
  ADD COLUMN IF NOT EXISTS onboarding_completed boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_profile_display_name_len'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT chk_profile_display_name_len
      CHECK (display_name IS NULL OR length(display_name) <= 60);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_profile_bio_len'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT chk_profile_bio_len
      CHECK (bio IS NULL OR length(bio) <= 280);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_profiles_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE PROCEDURE public.set_profiles_updated_at();

CREATE OR REPLACE FUNCTION public.generate_unique_username(base_username text)
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
      FROM public.profiles p
      WHERE p.username = candidate
    );

    suffix := suffix + 1;
  END LOOP;

  RETURN candidate;
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  resolved_username := public.generate_unique_username(base_username);
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

-- Normalize profile/follow read policies so friend discovery works across users.
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can view profiles" ON public.profiles;
DROP POLICY IF EXISTS "Authenticated users can view profiles" ON public.profiles;
DROP POLICY IF EXISTS "Public users can view profiles" ON public.profiles;
CREATE POLICY "Public users can view profiles" ON public.profiles
  FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Users can view related follows" ON public.friend_follows;
DROP POLICY IF EXISTS "Users can view follows" ON public.friend_follows;
DROP POLICY IF EXISTS "Authenticated users can view follows" ON public.friend_follows;
DROP POLICY IF EXISTS "Public users can view follows" ON public.friend_follows;
CREATE POLICY "Public users can view follows" ON public.friend_follows
  FOR SELECT
  USING (true);

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Avatar images are publicly readable" ON storage.objects;
CREATE POLICY "Avatar images are publicly readable" ON storage.objects
FOR SELECT
USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "Users can upload own avatar objects" ON storage.objects;
CREATE POLICY "Users can upload own avatar objects" ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Users can update own avatar objects" ON storage.objects;
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

DROP POLICY IF EXISTS "Users can delete own avatar objects" ON storage.objects;
CREATE POLICY "Users can delete own avatar objects" ON storage.objects
FOR DELETE
USING (
  bucket_id = 'avatars'
  AND auth.uid() IS NOT NULL
  AND (storage.foldername(name))[1] = auth.uid()::text
);
