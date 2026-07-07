-- ============================================================================
-- C2 Task 3 — Journal photo privacy (audit finding B4)
--
-- Plan:  docs/plans/2026-07-08-c2-journal-web-fixes.md (Task 3)
-- Audit: docs/plans/audits/2026-07-08-c2-journal-web-audit.md
--
-- ============================================================================
-- !! APPLY LAST — READ BEFORE APPLYING !!
-- ============================================================================
-- This is the ONLY migration in the C2 set that is NOT apply-then-merge
-- compatible (plan self-review note). The currently DEPLOYED web bundle
-- renders journal photos through getPublicUrl links
-- (components/journal/JournalPhotoGrid.tsx on the old build); the moment
-- `public = false` lands, every one of those public URLs starts returning
-- 400 — photos vanish for the deployed app and stay broken until the web
-- deploy of this PR (whose JournalPhotoGrid renders 30-day signed URLs,
-- re-signed on every mount).
--
-- RUNBOOK ORDER (full runbook lands in the ledger via plan Task 5):
--   1. 20260708_journal_visibility_model.sql   §§1-3   (Task 2)
--   2. 20260708_journal_search_likes_hardening.sql     (Task 1)
--   3. THIS FILE — LAST, immediately before step 4.
--   4. Merge + deploy the web build of this PR right away; then the
--      visibility file's §4 compat-view drop, per its own header.
-- The gap between step 3 and step 4 is the photo outage window for the old
-- bundle — keep it to minutes. (Residual CDN edge caches may keep serving a
-- previously fetched public object for up to its cacheControl=3600 lifetime
-- after the flip; that is a bounded tail of the OLD exposure, not a new one.)
--
-- No other C2 file depends on this one; applying it last never reorders
-- their guarantees.
-- ============================================================================
-- WHAT THIS FIXES (B4): the journal-photos bucket is public
-- (supabase_journal_entries.sql:171-173) AND storage.objects carries an
-- unconditional SELECT policy for it (`USING (bucket_id = 'journal-photos')`,
-- :176-177). Paths are structured and low-entropy apart from the entry uuid
-- ({userId}/{entryId}/{index}.{ext}) and are disclosed in
-- journal_entries.photo_paths on any readable row — so photos attached to
-- 'friends'/'private' entries are readable by ANYONE with the URL, and entry
-- visibility never gates photo access. Adjudicated fix (plan Global
-- Constraints): private bucket + signed URLs, 30-day expiry, re-signed on
-- render.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Verification notes (same drill as the Task 1/2 headers):
--      bucket id            = 'journal-photos' (JOURNAL_PHOTO_BUCKET,
--                             constants.ts:268; created by
--                             supabase_journal_entries.sql:171-173)
--      path scheme          = {userId}/{entryId}/{index}.{ext}
--                             (uploadJournalPhoto, services/journalService.ts)
--                             → (storage.foldername(name))[1] IS the owner's
--                             auth uuid, so the scheme DOES give an owner
--                             prefix; the existing INSERT/DELETE policies
--                             (supabase_journal_entries.sql:179-183) already
--                             key on exactly that expression. Path scheme
--                             unchanged by this migration (plan Task 3).
--      row storage          = journal_entries.photo_paths text[] stores
--                             storage object PATHS (not URLs) — client code
--                             defensively converts any legacy full-URL value
--                             back to a path before signing
--                             (extractJournalPhotoPath, journalService.ts).
--      signing prerequisite = createSignedUrl/createSignedUrls called with a
--                             user JWT require storage RLS SELECT on the
--                             object (the signed link itself is then
--                             token-verified, not RLS-evaluated) — hence the
--                             owner SELECT policy in §4.
-- ────────────────────────────────────────────────────────────────────────────

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 2. B4 — flip the bucket private. Public-URL serving stops immediately;
--    from here every read is either an owner-minted signed URL or an
--    RLS-gated authenticated read.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK:
--
--   UPDATE storage.buckets SET public = true WHERE id = 'journal-photos';
--
-- (For completeness, the bucket's original definition, from
--  supabase_journal_entries.sql:170-173 — size limit and mime allowlist are
--  intentionally untouched by this migration:
--
--   -- 9. Storage bucket for journal photos
--   INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
--   VALUES ('journal-photos', 'journal-photos', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
--   ON CONFLICT (id) DO NOTHING;
-- )

UPDATE storage.buckets SET public = false WHERE id = 'journal-photos';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. B4 — drop the unconditional SELECT policy. With the bucket private this
--    policy would still let ANY role that reaches storage.objects (anon
--    included) read every journal photo through the authenticated endpoints —
--    the flip alone is not enough. Dropped by exact name; fails loudly if
--    prod has drifted from the migration files.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: recreate the previous policy verbatim
--   (from supabase_journal_entries.sql:175-177):
--
--   -- Storage policies for journal-photos bucket
--   CREATE POLICY "journal_photos_select" ON storage.objects
--     FOR SELECT USING (bucket_id = 'journal-photos');

DROP POLICY "journal_photos_select" ON storage.objects;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Owner-only SELECT on the owner's own prefix. Two jobs:
--      (a) lets the owner's client mint signed URLs (see §1 — signing needs
--          RLS SELECT on the object);
--      (b) lets the owner read their own photos directly.
--    Viewers of 'public'/'friends' entries never hit this policy on the
--    current web: the ONLY photo-rendering surface is the owner-only
--    composer grid (JournalPhotoGrid via JournalConversation) — cards show a
--    camera indicator, not images — so cross-user rendering happens purely
--    through owner-minted signed URLs within their 30-day TTL. If a future
--    cycle ships cross-user photo rendering (e.g. iOS entry detail), extend
--    THIS policy with a resolved-visibility EXISTS against journal_entries
--    (same shape as the Task 2 entry policy) so viewers can mint their own
--    signed URLs; do not re-add an unconditional policy.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: DROP POLICY "journal_photos_select_own" ON storage.objects;

CREATE POLICY "journal_photos_select_own" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'journal-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- ────────────────────────────────────────────────────────────────────────────
-- 5. Owner-only UPDATE on the owner's own prefix — completes owner CRUD
--    (plan Task 3: "owner full CRUD on own prefix"). The upload path has
--    always used upsert:true (uploadJournalPhoto), which needs UPDATE when a
--    path is reused, but no storage UPDATE policy ever existed (audit D6's
--    missing-policy half; D6's index-collision half stays deferred). The
--    existing owner-prefix INSERT/DELETE policies ("journal_photos_insert" /
--    "journal_photos_delete", supabase_journal_entries.sql:179-183) already
--    match this shape and are INTENTIONALLY UNTOUCHED.
-- ────────────────────────────────────────────────────────────────────────────
-- ROLLBACK: DROP POLICY "journal_photos_update_own" ON storage.objects;
--   (restores the pre-migration state — there was no UPDATE policy.)

CREATE POLICY "journal_photos_update_own" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'journal-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  )
  WITH CHECK (
    bucket_id = 'journal-photos'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

COMMIT;
