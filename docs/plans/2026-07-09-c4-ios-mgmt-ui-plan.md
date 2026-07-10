# C4-iOS Ranking Management UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give Spool iOS the ranking-management surface (reorder, move tier, edit notes, re-rank, delete) on the corrected `set_tier_order` base, plus the deferred ceremony re-rank correction (source-tier compaction + `ranking_move` emission).

**Architecture (owner-adjudicated 2026-07-09):** long-press context menu on ranked cards (move to tier / edit notes / re-rank / delete) + an Edit mode enabling drag-to-reorder with handles, iOS-home-screen style. All order writes route through the `set_tier_order` RPC per the position-integrity contract (`docs/contracts/shared-payloads.md` `## user_rankings ordering`); pure order math mirrors web's tested helpers.

**Tech Stack:** Swift + XCTest (`ios/Spool`), no migrations (RPC shipped in PR #39).

## Global Constraints

- Binding: `docs/contracts/shared-payloads.md` `## user_rankings ordering` (position-integrity invariant; FULL-MEMBERSHIP rule — every `set_tier_order` call passes the tier's ENTIRE intended membership; UPDATE-only + row-must-exist-first; dedup-first-occurrence; title-locale pin; orphan semantics on delete; `ranking_move` metadata `{notes?, year?}`, NEVER watched-with). Audit: `docs/plans/audits/2026-07-09-c4-ranking-mgmt-web-audit.md` §1 reference semantics.
- Branch `feat/ios-parity-c4-mgmt-ui` off main. Movies only this cycle (TV/book ceremonies don't exist on iOS until C5; iOS `insertRanking`'s tv/book path is latent-broken — do not touch).
- Event semantics (mirror web post-C4): reorder/move emits ONE `ranking_move` only when the order/tier actually changed (no-op emits nothing); delete emits `ranking_remove`; re-rank emits `ranking_move` (never remove+add). Find and reuse the existing iOS activity-event emitter (the `ranking_add` path in/around RankPersistence — read it; do NOT invent a second emitter shape).
- Delete = destructive: confirmation dialog required; only the ranking row dies (+ tier compaction) — stubs/journal/feed history survive, watchlist NOT restored (contract's orphan semantics; do not "helpfully" restore the bookmark).
- iOS idioms: actor repository extensions with `[RankingRepository]` logging; @MainActor models with injected closures (iOS 16 floor); SpoolTokens/ticket idiom; RED-first pure tests. Baseline `swift test --package-path ios/Spool` = 458; `swift build` clean. Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Implementers: locate the ranked-list surface by reading `FullListScreen.swift` / `ProfileScreen.swift` first (the tier list lives there); report which screen hosts the affordances rather than guessing from this plan.

---

### Task 1: Repository management ops + pure order helpers

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankingRepository.swift`; Create `ios/Spool/Sources/Spool/Services/TierOrder.swift` (pure); Test `ios/Spool/Tests/SpoolTests/TierOrderTests.swift` + extend an existing repo-adjacent test file for op-level decision logic.

**Interfaces (Produces):**
- Pure (RED-first, mirror web `services/tierOrder.ts` semantics): `tierOrderAfterReorder(_ ids: [String], from: Int, to: Int) -> [String]` (clamped, non-mutating), `tierOrderAfterRemoval(_ ids: [String], removedId: String) -> [String]`, `ordersAfterCrossTierMove(source: [String], target: [String], movedId: String, targetIndex: Int) -> (source: [String], target: [String])`.
- Repository (each reads the CURRENT tier membership first — full-membership rule): `reorderTier(media: "movie", tier: String, ids: [String]) async throws -> Int` (thin RPC call), `moveRanking(tmdbId: String, fromTier: String, toTier: String, atIndex: Int?) async throws` (UPDATE row tier via target `set_tier_order` splice + source compaction call — two RPCs, target first, mirroring the ceremony's order), `updateNotes(tmdbId: String, notes: String?) async throws` (single-column UPDATE, nothing else touched), `deleteRanking(tmdbId: String, tier: String) async throws` (DELETE by (user_id,tmdb_id) → compact tier via `set_tier_order` with membership minus id; RPC failure after successful DELETE logs loudly, self-heals).
- Commit `feat(ios): ranking management repository ops — reorder/move/notes/delete via set_tier_order`.

### Task 2: Ceremony re-rank correction (deferred C4 item)

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankingRepository.swift` (`insertRanking`), the emitter call site (wherever `ranking_add` fires); Test `ios/Spool/Tests/SpoolTests/TierSpliceTests.swift` (extend).
- `insertRanking` pre-reads the existing row for (user_id, tmdb_id). If it exists: this is a re-rank — after the upsert + target-tier splice RPC, ALSO compact the OLD tier when it differs (membership minus the id), and the emission is `ranking_move` (metadata `{notes?, year?}`, no watched-with) instead of `ranking_add`. Fresh insert: behavior unchanged (`ranking_add`). This closes the ledgered deviation (`docs/plans/2026-07-07-ios-parity-ledger.md` C4 notes) and the shared-payloads known-deviations entry — UPDATE BOTH DOCS in this task.
- Same-tier re-rank: one RPC, `ranking_move` emitted (matches web ceremony semantics).
- Commit `fix(ios): ceremony re-rank compacts the source tier and emits ranking_move`.

### Task 3: Edit mode — drag-to-reorder

**Files:** Modify the ranked-list screen (read `FullListScreen.swift` first — adjust if the tier list lives elsewhere); Create `ios/Spool/Sources/Spool/Services/RankManageModel.swift` (@MainActor, injected closures); Test `ios/Spool/Tests/SpoolTests/RankManageModelTests.swift`.
- An "edit" affordance toggles edit mode: rows show drag handles; drag reorders WITHIN a tier (`.onMove`-style over the tier's rows); on drop → optimistic reorder → `reorderTier` with the full new membership → revert + toast on failure; no-op drop (same position) does nothing (no RPC, no event). Emit `ranking_move` on confirmed change via the Task-1/2 emitter path.
- Cross-tier drag is NOT in scope (move-to-tier lives in the context menu — keeps drag single-tier and simple).
- Commit `feat(ios): edit mode — drag-to-reorder tiers via set_tier_order`.

### Task 4: Long-press context menu (move / notes / re-rank / delete)

**Files:** Same screen + `RankManageModel.swift`; small sheets (`RankNotesSheet.swift`, tier picker can be a `Menu`/confirmationDialog); Test extend `RankManageModelTests.swift`.
- Long-press a ranked card → context menu: **move to tier** (submenu S/A/B/C/D minus current → `moveRanking` appending at target end; optimistic + revert), **edit notes** (sheet with the row's current notes → `updateNotes`), **re-rank** (enter the existing ceremony preseeded with the RAW item — the Task-2-corrected path handles events/compaction; no watchlist origin), **delete** (confirmation dialog naming the movie → `deleteRanking` → `ranking_remove` emission; optimistic removal + revert on error).
- Menu is movie-cards only where the list mixes media (TV/book rows get no menu this cycle).
- Commit `feat(ios): long-press ranking management — move tier, edit notes, re-rank, delete`.

### Task 5: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C4 row → iOS management UI shipped; deviation entries closed by Task 2; remaining C4 deferreds intact); `docs/contracts/shared-payloads.md` (only the known-deviations list update from Task 2 if not already done there).
- Commit `docs: C4 iOS management UI ledger`.

## Self-Review Notes

- No migrations: `set_tier_order` + all policies are live in prod (PR #39, probed).
- Task 2 rides this cycle because the ledger explicitly scheduled the re-rank correction here; it also makes the context menu's re-rank affordance correct for free.
- Device smoke owed in the PR body: long-press → move a movie S→B, drag-reorder in edit mode, delete one — verify positions stay contiguous (corruption detection query in `docs/plans/audits/2026-07-09-c4-verification.md`).
