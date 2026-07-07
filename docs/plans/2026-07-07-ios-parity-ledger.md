# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | in progress (spec/plan) | — | — | — |
| C1 | Feed + notifications | pending | — | — | — |
| C2 | Journal + AI agent | pending | — | — | — |
| C3 | Watchlist + Discover | pending | — | — | — |
| C4 | Ranking management | pending | — | — | — |
| C5 | TV seasons + books | pending | — | — | — |
| C6 | zh localization | pending | — | — | — |
| C7 | Smaller items | pending | — | — | — |

## Audit findings

None yet. Format per entry: `[cycle] [blocking|deferred] file:line — finding — disposition`.

## Behavior notes awaiting owner ack

None open. (PR #29's tier-migration size-table change was acked by merge on 2026-07-07.)

## Deferred minors carried from the engine-unification branch

- Corpus v2: misaligned-seed fixture case, cross-language undo replay, `tsc --noEmit` step in CI
- Style: MARK casing (SpoolRankingEngineTests), 2-space indent block (rankingAlgorithm.ts), dead `Bracket` import (RankingFlowModal)
- `sessionRef` not nulled on start-done paths in the 4 web surfaces (unreachable; fold into W1.3)
- Session-level self-comparison filter (`id !== newItem.id`) with test (upstream-guarded today)
