-- ============================================================
-- Critical DB Fixes (2026-02-26)
-- ============================================================

-- FIX 1: Add 'journal_tag' to notifications type CHECK constraint
-- The journal feature sends 'journal_tag' notifications when tagging
-- friends in watch context, but the CHECK constraint was missing it.
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
CHECK (type IN (
  'new_follower', 'review_like', 'party_invite', 'party_rsvp',
  'poll_vote', 'poll_closed', 'list_like', 'badge_unlock',
  'group_invite', 'ranking_comment', 'journal_tag'
));

-- FIX 2: Tighten journal_entries SELECT policy
-- Was: FOR SELECT USING (true) — anyone could read all entries
-- Now: Respects visibility_override column (public/friends/private)
DROP POLICY IF EXISTS "journal_entries_select" ON journal_entries;
CREATE POLICY "journal_entries_select" ON journal_entries
FOR SELECT USING (
  auth.uid() = user_id
  OR visibility_override = 'public'
  OR visibility_override IS NULL
  OR (
    visibility_override = 'friends'
    AND EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid()
        AND following_id = journal_entries.user_id
    )
  )
);

-- FIX 3: Tighten notifications INSERT policy
-- Was: WITH CHECK (true) — any user could insert for any user_id
-- Now: Target user must exist in profiles table
DROP POLICY IF EXISTS "System can insert notifications" ON notifications;
CREATE POLICY "Authenticated users can create notifications" ON notifications
FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (SELECT 1 FROM profiles WHERE id = notifications.user_id)
);
