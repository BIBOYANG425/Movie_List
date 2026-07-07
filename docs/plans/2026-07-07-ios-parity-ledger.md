# iOS Parity Program Ledger

Living record for the program defined in `2026-07-07-ios-parity-program-design.md`. Any session resumes from here. Update in the same PR as the work it records.

## Cycle status

| Cycle | Feature | Status | Audit doc | Web-fix PR | iOS PR |
|---|---|---|---|---|---|
| C0 | Stub write fix | iOS build in final review | audits/2026-07-07-c0-stub-web-audit.md | #30 | (PR opens after final review) |
| C1 | Feed + notifications | pending | — | — | — |
| C2 | Journal + AI agent | pending | — | — | — |
| C3 | Watchlist + Discover | pending | — | — | — |
| C4 | Ranking management | pending | — | — | — |
| C5 | TV seasons + books | pending | — | — | — |
| C6 | zh localization | pending | — | — | — |
| C7 | Smaller items | pending | — | — | — |

## Audit findings

Format per entry: `[cycle] [blocking|deferred] finding — disposition`.

- [C0] [blocking] stubService upsert clobbered `palette` on every re-rank — fixed in PR #30 (a44ae3f)
- [C0] [blocking] stub `watched_date` UTC (evening ranks land on tomorrow), live + backfill paths — fixed in PR #30 (a44ae3f, 8fbcaac); forward-only, historical rows keep UTC dates
- [C0] [deferred] 6 findings logged in audits/2026-07-07-c0-stub-web-audit.md (rewatches unrepresentable in one-stub-per-item model; backfill date is a proxy; and 4 more, see doc)
- [C0] [deferred, review] pin `process.env.TZ` in stubService date tests so a UTC-methods regression fails on UTC CI; defensive try/catch in `insertStubOrUpdateOnConflict`; fold both into the iOS C0 cycle or W1.x
- [C0] [resolved] iOS legacy insertStub violated the write contract (sent palette/mood_tags/stub_line, GMT dates, no conflict handling) — deleted; StubWriter is the only stub write path

## Behavior notes awaiting owner ack

None open. (PR #29's tier-migration size-table change was acked by merge on 2026-07-07.)

## Deferred minors carried from the engine-unification branch

- Corpus v2: misaligned-seed fixture case, cross-language undo replay, `tsc --noEmit` step in CI
- Style: MARK casing (SpoolRankingEngineTests), 2-space indent block (rankingAlgorithm.ts), dead `Bracket` import (RankingFlowModal)
- `sessionRef` not nulled on start-done paths in the 4 web surfaces (unreachable; fold into W1.3)
- Session-level self-comparison filter (`id !== newItem.id`) with test (upstream-guarded today)
