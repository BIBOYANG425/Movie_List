# C6 Web Blocking Fixes Implementation Plan (zh correctness before the iOS port)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix the five C6-audit blocking findings so the web zh implementation is a sound reference: reachable toggle (B1), reconciled key tables + the keyless top surfaces covered (B2), typed zh with a parity test (B3), no proxy burn on `ol_` ids (B4), no mixed-language sentences (B5).

**Architecture:** Table + `t()` mechanics stay as-is (the audit endorses them); this is coverage, typing, and two small behavioral fixes. New zh copy follows the existing zh register; the owner's voice rules bind (no 不是…而是, no em dashes, no negation-contrast).

**Tech Stack:** TypeScript + vitest. Baselines: web 533, iOS untouched (741).

## Global Constraints

- Binding: `docs/plans/audits/2026-07-10-c6-zh-web-audit.md` (B1-B5 + §1 mechanism reference). Branch `fix/c6-zh-web-blocking` off main.
- zh copy rules (owner, standing): no 不是…而是 construction, no em dashes (use periods/recast), no "it's not X, it's Y" pattern; match the existing zh table's register.
- Key hygiene: every key in `en` exists in `zh` and vice versa (the parity test enforces both directions + non-empty values); dead keys DELETED not padded.
- Tests `npx vitest run services/__tests__/` (533 baseline) + `npx tsc --noEmit`. Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Toggle reachability (B1) + typed zh + parity test (B3)

**Files:** Modify `components/AppLayout.tsx` (the `hidden md:flex` toggle — make it reachable on mobile: move/duplicate into the mobile nav or an always-visible header slot; match the app's visual language), `i18n/zh.ts` (type it against the en key union — `Record<TranslationKey, string>` or `satisfies`), new `services/__tests__/i18nParity.test.ts` (bidirectional key parity + non-empty + no-em-dash guard on zh values).
- Commit `fix(web): language toggle reachable on mobile; zh table typed with parity test (B1/B3)`.

### Task 2: Key reconciliation + keyless top surfaces (B2)

**Files:** `i18n/en.ts` + `i18n/zh.ts` (delete the 72 dead keys — verify each by grep before deleting; add keys for the top keyless surfaces), then wire `t()` through: `components/AppLayout.tsx` nav labels, the ceremony steps (`components/media/TierPicker.tsx`/NotesStep/ComparisonStep — locate by the audit's names), `components/media/AddMediaModal.tsx`, `pages/AuthPage.tsx`, `pages/MovieOnboardingPage.tsx`, the journal suite's top-level user-facing strings (JournalConversation + entry cards — scope to USER-VISIBLE copy; internal/debug strings stay EN).
- This is the bulk task: sweep systematically, file by file; new zh values follow the register + voice rules. Do NOT restyle copy while wiring — translate what's there.
- Tests: extend the parity test's expectations; spot pure seams only (no render harness exists).
- Commit `fix(web): dead i18n keys removed; nav, ceremony, auth, onboarding, journal wired through t() (B2)`.

### Task 3: `ol_` proxy burn (B4) + mixed-language sentences (B5)

**Files:** `hooks/useLocalizedItems.ts` (early-return for `ol_` ids — books never localize; C5-D5), `pages/RankingAppPage.tsx` (~367 the EN-enum-interpolated-into-zh toast + any siblings the audit lists — parameterize via t() with the enum value translated or restructured).
- Commit `fix(web): books skip title localization; no mixed-language sentences (B4/B5)`.

### Task 4: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C6 row: web blocking in PR; B1-B5 dispositions; adjudications incl. the iOS-side ones recorded for the next plan; deferred pointer).
- Commit `docs: C6 web blocking dispositions`.

## Self-Review Notes
- Task 2's sweep must not change ceremony/flow behavior — string extraction only; the reviewer will diff for accidental logic edits.
- The iOS C6 plan (LocaleStore + table port + toggle + locale() re-source + zh for iOS-only strings) follows after this merges.
