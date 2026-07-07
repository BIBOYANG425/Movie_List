# C2 Web Journal Blocking Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the seven blocking findings from the C2 journal audit — five of them live privacy vulnerabilities — before any iOS journal work.

**Architecture:** SQL migrations rewrite the journal RPCs (auth-checked search, table-backed likes), the entry/photos RLS (visibility model that respects `profiles.profile_visibility`, private storage bucket with signed URLs), and the service layer stops leaking `personal_takeaway`, stops emitting friends-visibility review bodies into `activity_events`, and writes local calendar dates. Migrations applied by the OWNER per the C1 precedent (agent prod-DDL is permission-gated); code merges after.

**Tech Stack:** Postgres 17 (Supabase) RLS/RPC, Supabase Storage policies, TypeScript + vitest.

## Global Constraints

- Binding source: `docs/plans/audits/2026-07-08-c2-journal-web-audit.md` — each finding's "suggested fix" section is the starting point; §1 reference semantics must not change except where a finding says so.
- Adjudicated (controller 2026-07-08, owner review pending, do not relitigate): `visibility_override IS NULL` ("Default") resolves to the author's `profiles.profile_visibility` (NOT world-readable); `personal_takeaway` is owner-only everywhere (cross-user selects, search index, agent context for other users); photo bucket goes private with signed URLs (30-day expiry, re-signed on render); `activity_events` review emission gated to entries whose RESOLVED visibility is 'public'; likes move to a `journal_entry_likes` table (unique (entry_id, user_id)) with counts derived, RPCs become thin wrappers or are dropped in favor of direct inserts under RLS.
- All new/rewritten RPCs `security invoker` unless a finding's fix explicitly requires definer WITH a hardened auth predicate written first and commented.
- Migration files `supabase/migrations/20260708_*`; implementers never apply them or touch prod; every migration carries the verbatim old definition in a rollback comment block.
- Date handling mirrors C0/C1: user-local `yyyy-MM-dd` (reuse `localDateString` from `services/stubService.ts` — import, don't duplicate).
- Existing suites stay green: `npx vitest run services/__tests__/`, `npx tsc --noEmit`. Journal UI behavior (JournalHomeView etc.) unchanged except where a fix requires (signed URLs).
- Conventional commits ending `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Search + likes RPC hardening (B1, B3)

**Files:** Create `supabase/migrations/20260708_journal_search_likes_hardening.sql`; Modify `services/journalService.ts` (likes toggle + liked-state load per audit fix); Test `services/__tests__/journalLikes.test.ts` (pure payload/toggle-logic helpers).
- `search_journal_entries`: rewrite per audit B1 fix — auth predicate so callers see only entries they could read under the (Task 2) RLS: simplest correct form is `security invoker` + strip the `target_user_id` trust; verify the RPC's row filtering matches the new RLS by construction (document why). Exclude `personal_takeaway` from returned columns AND from the tsvector weights (B5's search half).
- Likes: create `journal_entry_likes(entry_id, user_id, created_at)` unique-pair table with RLS (insert/delete own row; select where the entry is visible); migrate existing counts (`journal_entries.likes_count` backfill comment — counts are drifted per audit, document the reconciliation choice); replace increment/decrement RPCs (drop, with rollback comments) — web toggles by insert/delete and reads liked-state per card; `likes_count` becomes a view or trigger-maintained (pick per audit's suggested fix; justify).
- Commit `fix(web): auth-checked journal search, table-backed likes`.

### Task 2: Visibility model (B2, B5, B6)

**Files:** Create `supabase/migrations/20260708_journal_visibility_model.sql`; Modify `services/journalService.ts` (cross-user select lists exclude `personal_takeaway`; event emission gate; resolved-visibility helper); Test extend `services/__tests__/journalService.test.ts` (new; pure helpers: visibility resolution, event-gate predicate).
- RLS rewrite per audit B2 fix: owner always; others per RESOLVED visibility (NULL → author's `profiles.profile_visibility`; 'public' → all authenticated; 'friends' → follower EXISTS (copy the C1 Task 2 branch shape); 'private' → owner only). Old policies quoted verbatim for rollback.
- B5: every cross-user read path (service selects, search RPC from Task 1, any `select('*')` serving another user's entries) excludes `personal_takeaway`; owner paths keep it.
- B6: review event emission gated on resolved visibility = 'public' (was `!== 'private'`).
- Commit `fix(web): journal visibility resolves through profile_visibility; private fields stay private`.

### Task 3: Photo privacy (B4)

**Files:** Create `supabase/migrations/20260708_journal_photos_private.sql`; Modify `services/journalService.ts` + the photo-rendering call sites the audit names (getPublicUrl → createSignedUrl, 30-day expiry, re-sign on render); Test: pure URL-builder helper tests.
- Bucket → private; storage policies: owner full CRUD on own prefix; SELECT via signed URLs only (no anon policy). Path scheme unchanged. Note in migration: existing public URLs in clients stop working on apply — code in this PR switches to signed URLs, so apply-then-merge ordering holds (same as C1).
- Commit `fix(web): journal photos bucket private with signed URLs`.

### Task 4: Local dates + streaks (B7)

**Files:** Modify `services/journalService.ts` (watched_date default + streak math per audit B7 fix, importing `localDateString` from stubService); Test extend the Task 2 test file (streak boundary cases across UTC-negative offsets, named-timezone calendars — C0's technique).
- Commit `fix(web): journal dates and streaks use local calendar days`.

### Task 5: Docs + ledger

**Files:** Modify `docs/contracts/shared-payloads.md` (journal_entries section: field contract incl. resolved-visibility model, likes table, photo signing — verified against final code); `docs/plans/2026-07-07-ios-parity-ledger.md` (C2 row, findings B1-B7 dispositions, 16 deferred pointer, adjudications with owner-pending marks); append the migration runbook (order: Task1 → Task2 → Task3 SQL; Task 4 is code-only) to the ledger.
- Commit `docs: journal contracts + C2 ledger`.

## Self-Review Notes

- B1's fix depends on Task 2's RLS existing at APPLY time — runbook must order the visibility migration before or together with the search rewrite if the invoker form relies on it; Task 1's migration must state its RLS dependency explicitly in the header (the implementer verifies which ordering is safe and documents it; if search-invoker requires Task 2's policies, the runbook swaps them — flag in the migration headers either way).
- Every fix is apply-then-merge compatible EXCEPT Task 3 (old deployed code renders public URLs that break the moment the bucket goes private) — the runbook therefore puts the bucket flip LAST, immediately before merge+deploy, and the PR body must say so.
