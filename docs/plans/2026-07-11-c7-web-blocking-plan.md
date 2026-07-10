# C7 Web Blocking Fixes Implementation Plan (final parity cycle, web half)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the C7-audit blockers before the iOS half: profile tabs showing the viewer's data on every profile (B1), the grant-any-badge-to-anyone RLS hole + client-side granting (B2/B3 — moves server-side), and the D2 success-toast overwrite that masks failure toasts on all three verticals (deferred-sweep #1).

**Architecture:** Achievements granting becomes a SECURITY DEFINER `grant_achievements()` RPC — the C4-style single primitive: rules evaluated server-side against the caller's own rows, idempotent (unique constraint + onConflict), corrected rules (the dead `movie_reviews` count → journal-entry-based), clients call fire-and-forget after rank/journal actions. RLS on `user_achievements` locks to SELECT-only for clients. Descopes per the ledgered adjudications: lists/import-on-iOS/send-3-recs are NOT ported or built (B4's port need dies with the lists descope; B1 still fixes the tab wiring).

**Tech Stack:** TypeScript + vitest; one Postgres migration (controller applies via MCP + probes before merge).

## Global Constraints

- Binding: `docs/plans/audits/2026-07-11-c7-smalls-web-audit.md` (B1-B4, achievements catalog + rules, D2 sites). Branch `fix/c7-web-blocking` off main.
- Baselines: web 545, iOS 782 (untouched this half).
- Migration file `supabase/migrations/20260711_achievements_server_grant.sql`; implementers never apply; verbatim rollback; probes doc for the controller.
- Events: milestone/badge emission rules per the audit — badge_unlock notifications may START being written (the type exists in the CHECK — verify) but only from the server RPC; no client-side grant writes remain.
- Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: B1 — profile tabs show the profile's data

**Files:** Modify `pages/ProfilePage.tsx` (~599, 605 — the lists/achievements tab loaders pass `user.id` instead of `profile.id`); Test pure seams if extractable.
- Verify every tab loader on the page keys on the VIEWED profile id; the viewer's id is only for is-own-profile checks. Check the same class on any sibling page the audit flags.
- Commit `fix(web): profile tabs load the viewed profile's data, not the viewer's (B1)`.

### Task 2: B2/B3 — server-side achievement granting

**Files:** Create `supabase/migrations/20260711_achievements_server_grant.sql` (lock `user_achievements` INSERT to service/definer only [drop the WITH CHECK (true) policy]; add UNIQUE(user_id, badge_id) if absent; `grant_achievements()` SECURITY DEFINER RPC: evaluates the audit's 15 grantable rules against `auth.uid()`'s rows [CORRECTED rules: review-count badges read journal entries, not the dead movie_reviews table — enumerate every rule from `services/achievementService.ts` + the audit], inserts new grants ON CONFLICT DO NOTHING, writes `badge_unlock` notifications for NEW grants only [verify the notifications type CHECK includes badge_unlock — the audit says the type exists but is never written], returns newly-granted badge ids); Create `docs/plans/audits/2026-07-11-c7-verification.md` (probes: RLS denial of direct client INSERT; RPC grants correctly for a fixture user; idempotent re-call grants nothing; cross-user isolation; notification written once).
- Modify `services/achievementService.ts`: `checkAndGrantBadges` becomes a thin `rpc('grant_achievements')` call (fire-and-forget, log on error); milestone activity events fire ONLY for newly-granted ids (the RPC's return — fixes B3's regardless-firing); delete the client-side rule evaluation + unchecked inserts.
- Commit `fix(web): achievements grant server-side — RLS locked, idempotent RPC, corrected rules (B2/B3)`.

### Task 3: D2 — success toast no longer overwrites failure

**Files:** Modify `pages/RankingAppPage.tsx` (~1410, 1451, 1502-1507 per the audit: `handleAddItem`/`handleAddTVItem`/`handleAddBookItem` fire the success toast unconditionally after the save — gate `toast.ranked` on the save-success boolean all three verticals; the C5W-T3 failure toasts finally become user-visible).
- Tests: extend the existing decision-seam tests if the gate extracts purely; else trace-in-report.
- Commit `fix(web): ranked toast gates on save success — failure toasts visible (D2)`.

### Task 4: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C7 row: web half in PR; B1-B4 dispositions incl. the lists/recs/import descopes as owner-reviewable adjudications; D2 closed; deferred-sweep ranking recorded; the C7-iOS scope note); `docs/contracts/shared-payloads.md` (new `## achievements` section: the RPC contract, badge catalog pointer, badge_unlock notification shape, client fire-and-forget rule).
- Commit `docs: C7 web dispositions — achievements contract, descopes recorded`.

## Self-Review Notes
- Controller applies the migration + runs probes BEFORE merge (apply-then-merge safe: old clients' direct INSERTs start failing against the locked RLS — verify the audit's claim that web is the only granter and gate the client swap in the same PR so no window exists where web still tries direct INSERTs against locked RLS... ordering: the merge carries the client swap; between apply and merge, OLD deployed web clients' checkAndGrantBadges inserts will fail RLS silently [they're already unchecked/best-effort per B3] — acceptable degraded window, note it).
- iOS half follows: achievements surface + the same RPC, movie-mode grid, card actions, emission items, spool://u/ links.
