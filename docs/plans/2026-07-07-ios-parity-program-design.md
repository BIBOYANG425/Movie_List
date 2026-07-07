# iOS Parity Program Design

**Goal.** Bring the Spool iOS app (`ios/Spool`) to full feature parity with the web app. Every feature a web user can touch exists on iOS, both clients write identical data shapes to the shared Supabase backend, and no business logic is duplicated client-side beyond the fixture-gated ranking engine.

**Owner decisions (2026-07-07).**
1. Scope covers everything users can touch. Orphaned web dead code (stats view, friend-search UI) is excluded and gets deleted by roadmap item W0.3 instead of ported.
2. Bug policy for the pre-port web audits. Blocking bugs (would be ported into Swift, or corrupt shared data) are fixed on web in a small PR before the iOS build starts. Non-blocking findings go to the ledger and are batched later.
3. Sequencing follows the roadmap order (data integrity first, then user impact).
4. Delivery is one PR per feature cycle, executed subagent-driven with per-task reviews and a final whole-branch review (the PR #29 machinery). The owner smoke-tests on device and merges before the next cycle starts.
5. Architecture follows the hybrid rule (Approach A). Big algorithmic surfaces move to the backend once and both clients call them. Simple CRUD features are thin Swift ports against existing tables.

## The cycle loop

Every cycle runs five steps.

1. **Audit.** A subagent audits the web feature's logic as the reference implementation. It hunts real logic bugs, data-contract quirks, N+1s, and dead paths, and writes an audit doc plus ledger entries. The audit reads code and verifies against the database schema; it does not refactor.
2. **Blocking fixes.** Findings classified blocking land as a small web PR. Owner merges; Vercel deploys.
3. **Spec and plan.** The iOS feature gets a short design (brainstormed only if open questions remain) and a detailed implementation plan via writing-plans.
4. **Build.** Subagent-driven execution on a feature branch. Per-task reviewer gates, final whole-branch review, engine-parity CI green.
5. **Verify and merge.** Contract doc updated for any payload both clients write. Owner smoke-tests on device, acks any behavior notes, merges. Ledger updated with cycle status and deferred findings. Owner directive 2026-07-07: when task reviews, the final whole-branch review, and CI are all clean, the controller auto-merges; device-level smoke is noted as owed in the PR body instead of gating the merge.

## Cycles

| Cycle | Feature | Backend work | iOS work | Audit focus | Est. |
|---|---|---|---|---|---|
| C0 | Stub write fix | none | Chain `insertStub` + palette extraction into `RankPersistence.save` (TODO at RankPersistence.swift:70) | Web `createStub` semantics (fields, palette, dedup) as reference | 2–3 days |
| C1 | Social feed + notifications | Feed-score SQL RPC (fixes the known ~100-query N+1 on web, both clients adopt) | `FeedRepository`, feed UI (friends/explore, reactions, comments, mutes, pagination), notifications bell + list + mark-read | `feedService` (592 ln) scoring, filters, mute logic; notification types; `activity_events.metadata` shapes | 2–3 wks |
| C2 | Journal + AI agent | none (edge function `journal-agent` already deployed) | Stage a: ceremony quick-entry writes `journal_entries` instead of notes-only. Stage b: journal tab (CRUD, moods, photos, visibility, search, likes) + thin agent chat client | `journalService` CRUD + visibility rules, agent session/consent/correction flow | 2–3 wks |
| C3 | Watchlist + Discover | New `suggestions` edge function extracted from the tmdbService 5-pool engine; TMDB key moves out of both clients | Watchlist tab + rank-from-watchlist; Discover surface calling the edge function | 5-pool engine logic + taste profile writes; watchlist RLS paths | ~2 wks |
| C4 | Ranking management | none | Edit notes, reorder within tier, move across tiers, delete (RankingRepository is insert-only today) | Web reorder/persist semantics on the movie path (reference), incl. the cross-tier migration flow | ~1 wk |
| C5 | TV seasons + books | none | Open Library client, `tv_{id}_s{n}` and `ol_` id handling, per-vertical tabs; PlacementSession is already media-agnostic | Web TV/book divergences from the movie path (known: drop-handler divergences) | 1–1.5 wks |
| C6 | Chinese localization | none | `.xcstrings` catalog (~376 keys from web i18n), TMDB `language` from locale, localized-title strategy | Web i18n key coverage; `useLocalizedItems` behavior | 3–4 days |
| C7 | Smaller items | `movie_recommendations` migration (from the 2026-04-18 plan that never shipped) | Achievements, curated lists, Letterboxd import (ZIPFoundation), public-profile universal links, send-3-recs | Achievement grant rules; list CRUD; import parse pipeline | 2–3 wks |

Estimated program total is 8–12 focused weeks, matching the parity study.

## Drift prevention (applies to every cycle)

1. New shared business logic lives in the backend once. The ranking engine remains the only sanctioned client-side duplicate, gated by `fixtures/engine-parity.json`.
2. `docs/contracts/shared-payloads.md` is the single contract document for shapes both clients write (`activity_events.metadata`, notification rows, journal entry fields, stub fields). Any cycle that touches a shared shape updates it in the same PR.
3. The engine fixture corpus grows only when a cycle touches placement logic.
4. The `engine-parity` CI workflow must stay green on every PR; cycles that add backend functions include their own verification steps in the cycle plan.

## Tracking

`docs/plans/2026-07-07-ios-parity-ledger.md` is the living program record. Cycle status, audit findings with blocking/deferred classification, behavior notes awaiting owner ack, and links to per-cycle audit docs and PRs. Any future session resumes from the ledger.

## Risks

1. Edge-function deploys (C1 RPC, C3 suggestions) touch the production Supabase project. Mitigation. SQL and functions reviewed in-PR, applied via migration files, staged where branch environments exist, and E2E smoke after schema changes per the owner's standing rule.
2. Device-level verification cannot be automated here. The simulator covers most flows; owner smoke-tests each cycle on device before merge.
3. Web audits may surface larger bug clusters than expected (journal and feed are the likeliest). The blocking/deferred split keeps cycles moving; a cycle can be paused and resequenced if an audit reveals structural problems.
4. The web refactor waves (W1.x) run on the same files some audits read. One cycle in flight at a time, rebase early, and audits pin the commit they read.

## Definition of done

**Per cycle.** Audit doc written; blocking fixes merged; iOS feature merged with CI green; contract doc updated; owner device-smoke passed; ledger updated.

**Program.** All cycles C0–C7 merged. No live web feature lacks an iOS equivalent. Both clients write identical shapes for every shared table. TMDB key absent from both client bundles.
