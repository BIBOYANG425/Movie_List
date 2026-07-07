# Ranking Engine Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One ranking-placement semantics across web (TypeScript) and iOS (Swift), enforced by a shared golden-fixture test corpus, with the small-tier algorithm formalized on web and both platforms consuming placement through a single session facade.

**Architecture:** The TypeScript engine (`services/spoolRankingEngine.ts`) is the semantic reference. We first remove two Swift porting scars (obfuscated midpoint expression, silent dictionary-miss fallbacks), then port the Swift-only pure small-tier algorithm (`advanceSmallTier`) back to `services/rankingAlgorithm.ts` with its tests, wrap all placement strategies behind a `RankingSession` facade on web and a `PlacementSession` facade on iOS, migrate the four web surfaces and `RankH2HScreen` onto the facades, and finally generate a JSON fixture corpus from the TS side that both vitest and XCTest replay in CI.

**Tech Stack:** TypeScript + vitest (web), Swift + XCTest via SwiftPM (`ios/Spool`), GitHub Actions (macOS runner), `tsx` for the fixture generator script.

## Global Constraints

- All work happens on a feature branch `feat/engine-unification` cut from up-to-date `origin/main`. Never commit to `main`.
- Behavior preservation. No task in this plan may change what rank or score any sequence of user choices produces. The only intentional user-visible change is Task 8's phase-label alignment (`.probe` → `.binarySearch` for iOS compare-all comparisons), which is metadata, not placement.
- Web test command: `npx vitest run <path>` (repo root). Full suite: `npm test`.
- iOS test command: `swift test --package-path ios/Spool` (requires macOS with Xcode toolchain). Filter: `swift test --package-path ios/Spool --filter <TestClassName>`.
- Typecheck after every web task: `npx tsc --noEmit`.
- Conventional commit messages (`feat:`, `fix:`, `refactor:`, `test:`, `ci:`). End every commit message body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- The comparison question strings intentionally differ per platform (web "Which do you prefer?", iOS "which do you love more?"). Do NOT align them; fixtures exclude question text.
- Do not modify `services/spoolRankingEngine.ts` phase logic, `services/spoolPrediction.ts` weights, or `constants.ts` values anywhere in this plan.

---

### Task 1: Replace the Swift `computeTierScore` precedence puzzle

The single-item branch of `computeTierScore` in Swift is an obfuscated expression that happens to equal "midpoint rounded to 1 decimal place". Pin the behavior with tests, then replace the puzzle with the plain expression.

**Files:**
- Modify: `ios/Spool/Sources/Spool/Algorithm/RankingAlgorithm.swift:189-200`
- Test: `ios/Spool/Tests/SpoolTests/SpoolRankingEngineTests.swift` (append new test method)

**Interfaces:**
- Consumes: `RankingAlgorithm.computeTierScore(position:totalInTier:tierMin:tierMax:)` (existing).
- Produces: same signature, simplified body. Later tasks (2, 8, 9) call it unchanged.

- [ ] **Step 1: Write the pinning test**

Append to `ios/Spool/Tests/SpoolTests/SpoolRankingEngineTests.swift` inside the existing test class:

```swift
    /// Single-item tiers get the tier midpoint rounded to 1 decimal place.
    /// Pins behavior before simplifying the obfuscated expression in
    /// computeTierScore's totalInTier <= 1 branch.
    func testSingleItemTierScoreIsRoundedMidpoint() {
        // (min + max) / 2, rounded to 1 place, per tier:
        // S: (9.0+10.0)/2 = 9.5   A: (7.0+8.9)/2 = 7.95 -> 8.0
        // B: (5.0+6.9)/2 = 5.95 -> 6.0   C: (3.0+4.9)/2 = 3.95 -> 4.0
        // D: (0.1+2.9)/2 = 1.5
        let expected: [Tier: Double] = [.S: 9.5, .A: 8.0, .B: 6.0, .C: 4.0, .D: 1.5]
        for (tier, want) in expected {
            let range = SpoolConstants.tierScoreRanges[tier]!
            let got = RankingAlgorithm.computeTierScore(
                position: 0, totalInTier: 1,
                tierMin: range.min, tierMax: range.max
            )
            XCTAssertEqual(got, want, accuracy: 0.0001, "tier \(tier)")
        }
    }
```

- [ ] **Step 2: Run the test to verify it passes against the CURRENT code**

Run: `swift test --package-path ios/Spool --filter SpoolRankingEngineTests/testSingleItemTierScoreIsRoundedMidpoint`
Expected: PASS. (This is a characterization test. If it FAILS, stop — the analysis of the obfuscated expression was wrong, and the discrepancy must be reported before changing anything.)

- [ ] **Step 3: Replace the puzzle with the plain expression**

In `ios/Spool/Sources/Spool/Algorithm/RankingAlgorithm.swift`, replace:

```swift
        if totalInTier <= 1 {
            return (tierMin + tierMax).rounded(toPlaces: 1) / 2.0.rounded(toPlaces: 1) == 0
                ? 0
                : ((tierMin + tierMax) / 2.0).rounded(toPlaces: 1)
        }
```

with:

```swift
        if totalInTier <= 1 {
            return ((tierMin + tierMax) / 2.0).rounded(toPlaces: 1)
        }
```

- [ ] **Step 4: Run the full iOS suite**

Run: `swift test --package-path ios/Spool`
Expected: all tests PASS (previously ~46 tests across 6 classes, plus the new one).

- [ ] **Step 5: Commit**

```bash
git add ios/Spool/Sources/Spool/Algorithm/RankingAlgorithm.swift ios/Spool/Tests/SpoolTests/SpoolRankingEngineTests.swift
git commit -m "refactor(ios): simplify computeTierScore single-item branch to plain rounded midpoint"
```

---

### Task 2: Make tier score ranges total in Swift and delete silent fallbacks

Every Swift phase handler guards `SpoolConstants.tierScoreRanges[tier]` and, on a hypothetical miss, silently returns `.done(finalRank: 0, finalScore: 0)` — which would place a movie at the TOP of its tier with score 0 and write that to the shared DB. Make the lookup a total function on the `Tier` enum so the compiler proves it can't miss, then delete every fallback.

**Files:**
- Modify: `ios/Spool/Sources/Spool/Algorithm/AlgorithmTypes.swift:92-99`
- Modify: `ios/Spool/Sources/Spool/Algorithm/SpoolRankingEngine.swift` (6 guard sites: lines ~74, 171, 212, 238, 250, 363)
- Modify: `ios/Spool/Sources/Spool/Algorithm/SpoolPrediction.swift` (2 guard sites: lines ~18, 42)
- Modify: `ios/Spool/Sources/Spool/Algorithm/RankingAlgorithm.swift` (2 guard sites in `computeAllScores` and `getNaturalTier`)
- Test: `ios/Spool/Tests/SpoolTests/SpoolRankingEngineTests.swift` (append one test)

**Interfaces:**
- Produces: `Tier.scoreRange: ScoreRange` (computed property, total over the enum). `SpoolConstants.tierScoreRanges` remains for other call sites but is derived from the property, so there is one source of truth. Tasks 8 and 9 use `tier.scoreRange`.

- [ ] **Step 1: Write the failing test**

Append to `SpoolRankingEngineTests.swift`:

```swift
    /// Tier.scoreRange must be total and agree with the legacy dictionary.
    func testTierScoreRangeIsTotalAndMatchesDictionary() {
        for tier in Tier.allCases {
            XCTAssertEqual(tier.scoreRange, SpoolConstants.tierScoreRanges[tier])
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path ios/Spool --filter SpoolRankingEngineTests/testTierScoreRangeIsTotalAndMatchesDictionary`
Expected: BUILD FAILURE with "value of type 'Tier' has no member 'scoreRange'".

- [ ] **Step 3: Add the total accessor and derive the dictionary from it**

In `AlgorithmTypes.swift`, add above `SpoolConstants`:

```swift
public extension Tier {
    /// Total function — the compiler guarantees every tier has a range,
    /// unlike the dictionary lookup this replaces.
    var scoreRange: ScoreRange {
        switch self {
        case .S: return ScoreRange(min: 9.0, max: 10.0)
        case .A: return ScoreRange(min: 7.0, max: 8.9)
        case .B: return ScoreRange(min: 5.0, max: 6.9)
        case .C: return ScoreRange(min: 3.0, max: 4.9)
        case .D: return ScoreRange(min: 0.1, max: 2.9)
        }
    }
}
```

and replace the literal dictionary in `SpoolConstants` with the derived form:

```swift
    public static let tierScoreRanges: [Tier: ScoreRange] =
        Dictionary(uniqueKeysWithValues: Tier.allCases.map { ($0, $0.scoreRange) })
```

Note: if `Tier` does not already conform to `CaseIterable`, add the conformance where `Tier` is declared (search: `grep -rn "enum Tier" ios/Spool/Sources/`). The existing `RankingAlgorithm.computeAllScores` already iterates `Tier.allCases`, so conformance almost certainly exists.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path ios/Spool --filter SpoolRankingEngineTests/testTierScoreRangeIsTotalAndMatchesDictionary`
Expected: PASS.

- [ ] **Step 5: Delete the silent fallbacks in the Algorithm layer**

Apply this mechanical rewrite at each of the 10 sites. Pattern — before:

```swift
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }
```

after:

```swift
        let range = tier.scoreRange
```

Sites and their exact `else` bodies (delete the whole guard in each):
1. `SpoolRankingEngine.swift` `start(...)` — else returns `.done(finalRank: 0, finalScore: 0)`
2. `SpoolRankingEngine.swift` `handleProbeResult` — same else
3. `SpoolRankingEngine.swift` `handleEscalationResult` — same else
4. `SpoolRankingEngine.swift` `handleCrossGenreResult` — same else
5. `SpoolRankingEngine.swift` `handleSettlementResult` — same else
6. `SpoolRankingEngine.swift` `computeFinalPlacement` — same else
7. `SpoolPrediction.swift` `computePredictionSignals` — else returns `PredictionSignals(totalRanked: allItems.count)`
8. `SpoolPrediction.swift` `predictScore` — else returns `0`
9. `RankingAlgorithm.swift` `computeAllScores` — `guard let range = ... else { continue }` becomes `let range = tier.scoreRange`
10. `RankingAlgorithm.swift` `getNaturalTier` — same `continue` guard, same replacement

Also in `SpoolPrediction.swift` `averageScore(for:in:)`: replace `guard let tierRange = SpoolConstants.tierScoreRanges[item.tier] else { return nil }` with `let tierRange = item.tier.scoreRange` and change the surrounding `compactMap` to `map` if the only `nil` source was that guard (verify by reading the closure — the remaining body returns non-optional).

Do NOT touch call sites outside `ios/Spool/Sources/Spool/Algorithm/` in this task (screens still use the dictionary; they are Task 8's concern or out of scope).

- [ ] **Step 6: Run the full iOS suite**

Run: `swift test --package-path ios/Spool`
Expected: all PASS. Placement behavior is unchanged because the deleted branches were unreachable (the dictionary covered all cases).

- [ ] **Step 7: Commit**

```bash
git add ios/Spool/Sources/Spool/Algorithm/
git commit -m "refactor(ios): total Tier.scoreRange accessor, delete silent rank-0 fallbacks"
```

---

### Task 3: Remove the vestigial `crossGenreAdjustment` field (both platforms)

Both engines write `crossGenreAdjustment = -0.3` on a cross-genre loss and snapshot it for undo, but nothing ever reads it — the -0.3 is applied directly to `tentativeScore`. Delete the dead field from both engines.

**Files:**
- Modify: `services/spoolRankingEngine.ts` (field decl ~line 65, snapshot interface ~line 35, `start` reset ~line 105, `handleCrossGenreResult` write ~line 323, `undo` restore ~line 215, `pushSnapshot` ~line 546)
- Modify: `ios/Spool/Sources/Spool/Algorithm/SpoolRankingEngine.swift` (Snapshot ~line 24, state ~line 44, `start` reset ~line 69, `handleCrossGenreResult` ~line 242, `undo` ~line 156, `pushSnapshot` ~line 382)

**Interfaces:**
- Consumes: nothing new. Produces: no API change — the field was `private` on both sides.

- [ ] **Step 1: Verify the field is truly write-only**

Run: `grep -rn "crossGenreAdjustment" --include="*.ts" --include="*.tsx" --include="*.swift" . | grep -v node_modules | grep -v .worktrees`
Expected: hits ONLY inside the two engine files (declaration, reset, `-0.3` write, snapshot copy, undo restore). If any OTHER file reads it (analytics, UI), STOP and leave this task undone — report the reader instead.

- [ ] **Step 2: Delete the field on both sides**

TypeScript — remove these lines from `services/spoolRankingEngine.ts`:
- `crossGenreAdjustment: number;` from `EngineSnapshot`
- `private crossGenreAdjustment = 0;`
- `this.crossGenreAdjustment = 0;` in `start()`
- `this.crossGenreAdjustment = -0.3;` in `handleCrossGenreResult` (keep the `tentativeScore` line below it)
- `this.crossGenreAdjustment = snapshot.crossGenreAdjustment;` in `undo()`
- `crossGenreAdjustment: this.crossGenreAdjustment,` in `pushSnapshot()`

Swift — remove the mirrored six lines from `SpoolRankingEngine.swift` (`Snapshot.crossGenreAdjustment`, `private var crossGenreAdjustment`, the `start` reset, the `handleCrossGenreResult` write, the `undo` restore, the `pushSnapshot` copy).

- [ ] **Step 3: Verify both suites pass**

Run: `npx vitest run services/__tests__/spoolRankingEngine.test.ts && npx tsc --noEmit`
Expected: PASS, no type errors.
Run: `swift test --package-path ios/Spool`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add services/spoolRankingEngine.ts ios/Spool/Sources/Spool/Algorithm/SpoolRankingEngine.swift
git commit -m "refactor: remove write-only crossGenreAdjustment field from both engines"
```

---

### Task 4: Port `advanceSmallTier` to TypeScript with the Swift test suite

The small-tier (≤20 items) placement algorithm exists as a pure tested function only in Swift (`RankingAlgorithm.advanceSmallTier`). On web it lives as untested inline copies in 4 components. Port the Swift function and its 7 tests to `services/rankingAlgorithm.ts`.

**Files:**
- Modify: `services/rankingAlgorithm.ts` (append)
- Create: `services/__tests__/rankingAlgorithm.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 5–7 and 9 depend on these exact names):

```ts
export type SmallTierMode = 'compare_all' | 'seed' | 'quartile';
export interface SmallTierState {
  mode: SmallTierMode;
  tierCount: number; // size of target tier, NOT counting the new item
  low: number;
  high: number;
  mid: number;
  round: number;
  seedIdx: number;
}
export type SmallTierStep =
  | { type: 'done'; rank: number }
  | { type: 'next'; state: SmallTierState };
export function advanceSmallTier(state: SmallTierState, pick: 'new' | 'existing'): SmallTierStep;
```

- [ ] **Step 1: Write the failing tests**

Create `services/__tests__/rankingAlgorithm.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import {
  advanceSmallTier,
  computeSeedIndex,
  computeTierScore,
  SmallTierState,
} from '../rankingAlgorithm';

// Ported 1:1 from ios/Spool/Tests/SpoolTests/SmallTierAlgorithmTests.swift
// so both platforms pin identical small-tier semantics.

const state = (overrides: Partial<SmallTierState>): SmallTierState => ({
  mode: 'seed',
  tierCount: 8,
  low: 0,
  high: 8,
  mid: 0,
  round: 1,
  seedIdx: 0,
  ...overrides,
});

describe('advanceSmallTier — seed mode', () => {
  it('user always picks new → inserts at rank 0 (8-item tier, median seed)', () => {
    const tierCount = 8;
    const tierScores = Array.from({ length: tierCount }, (_, idx) =>
      computeTierScore(idx, tierCount, 7.0, 8.9),
    );
    const seedIdx = computeSeedIndex(tierScores, 7.0, 8.9, undefined);
    expect(seedIdx).toBe(4); // median of 8 items

    let s = state({ mode: 'seed', mid: seedIdx, seedIdx });

    // Round 1: "new" at mid=4 → quartile with [0, 4), mid=0
    const r1 = advanceSmallTier(s, 'new');
    if (r1.type !== 'next') throw new Error('round 1: expected next');
    expect(r1.state.mode).toBe('quartile');
    expect(r1.state.low).toBe(0);
    expect(r1.state.high).toBe(4);
    expect(r1.state.mid).toBe(0);
    expect(r1.state.round).toBe(2);

    // Round 2: "new" at mid=0 → newLow=0 >= newHigh=0 → done at 0
    const r2 = advanceSmallTier(r1.state, 'new');
    expect(r2).toEqual({ type: 'done', rank: 0 });
  });

  it('new wins immediately at seed 0 → inserts at 0', () => {
    const s = state({ mode: 'seed', mid: 0, seedIdx: 0 });
    expect(advanceSmallTier(s, 'new')).toEqual({ type: 'done', rank: 0 });
  });

  it('user always picks existing → inserts at end (rank 8)', () => {
    let s = state({ mode: 'seed', mid: 4, seedIdx: 4 });
    const r1 = advanceSmallTier(s, 'existing');
    if (r1.type !== 'next') throw new Error('round 1: expected next');
    expect(r1.state.mode).toBe('quartile');
    expect(r1.state.low).toBe(5);
    expect(r1.state.high).toBe(8);
    expect(r1.state.mid).toBe(7); // 5 + floor(3 * 0.75) = 7

    const r2 = advanceSmallTier(r1.state, 'existing');
    expect(r2).toEqual({ type: 'done', rank: 8 });
  });
});

describe('advanceSmallTier — quartile mode', () => {
  it('existing jumps 75%: [0,8) mid=4 → [5,8) mid=7', () => {
    const s = state({ mode: 'quartile', low: 0, high: 8, mid: 4 });
    const r = advanceSmallTier(s, 'existing');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.low).toBe(5);
    expect(r.state.high).toBe(8);
    expect(r.state.mid).toBe(7);
  });

  it('new jumps 25%: [0,8) mid=4 → [0,4) mid=1', () => {
    const s = state({ mode: 'quartile', low: 0, high: 8, mid: 4 });
    const r = advanceSmallTier(s, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.low).toBe(0);
    expect(r.state.high).toBe(4);
    expect(r.state.mid).toBe(1);
  });
});

describe('advanceSmallTier — compare_all mode', () => {
  it('new wins → inserts at current cursor', () => {
    const s = state({ mode: 'compare_all', tierCount: 5, high: 5, mid: 2 });
    expect(advanceSmallTier(s, 'new')).toEqual({ type: 'done', rank: 2 });
  });

  it('losing every comparison walks to the end (rank == tierCount)', () => {
    let s = state({ mode: 'compare_all', tierCount: 3, high: 3, mid: 0 });
    for (const expectedMid of [1, 2]) {
      const r = advanceSmallTier(s, 'existing');
      if (r.type !== 'next') throw new Error(`expected next at mid ${s.mid}`);
      expect(r.state.mid).toBe(expectedMid);
      s = r.state;
    }
    expect(advanceSmallTier(s, 'existing')).toEqual({ type: 'done', rank: 3 });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run services/__tests__/rankingAlgorithm.test.ts`
Expected: FAIL — `advanceSmallTier` is not exported from `../rankingAlgorithm`.

- [ ] **Step 3: Implement `advanceSmallTier`**

Append to `services/rankingAlgorithm.ts`:

```ts
// ── Small-Tier State Machine ────────────────────────────────────────────────
// Direct port of ios/Spool RankingAlgorithm.advanceSmallTier — the pure
// formalization of the inline smallTierRef logic previously copy-pasted
// across RankingFlowModal / AddMediaModal / AddTVSeasonModal /
// MovieOnboardingPage. tierCount is the size of the target tier (the new
// item is NOT counted).

export type SmallTierMode = 'compare_all' | 'seed' | 'quartile';

export interface SmallTierState {
  mode: SmallTierMode;
  tierCount: number;
  low: number;
  high: number;
  mid: number;
  round: number;
  seedIdx: number;
}

export type SmallTierStep =
  | { type: 'done'; rank: number }
  | { type: 'next'; state: SmallTierState };

export function advanceSmallTier(
  state: SmallTierState,
  pick: 'new' | 'existing',
): SmallTierStep {
  const nextRound = state.round + 1;

  switch (state.mode) {
    case 'compare_all': {
      if (pick === 'new') return { type: 'done', rank: state.mid };
      if (state.mid + 1 >= state.tierCount) {
        return { type: 'done', rank: state.tierCount };
      }
      return { type: 'next', state: { ...state, mid: state.mid + 1, round: nextRound } };
    }

    case 'seed': {
      if (pick === 'new') {
        if (state.mid === 0) return { type: 'done', rank: 0 };
        return {
          type: 'next',
          state: { ...state, mode: 'quartile', low: 0, high: state.mid, mid: 0, round: nextRound },
        };
      }
      const newLow = state.mid + 1;
      if (newLow >= state.tierCount) return { type: 'done', rank: state.tierCount };
      const newHigh = state.tierCount;
      const nextMid = Math.min(newLow + Math.floor((newHigh - newLow) * 0.75), newHigh - 1);
      return {
        type: 'next',
        state: { ...state, mode: 'quartile', low: newLow, high: newHigh, mid: nextMid, round: nextRound },
      };
    }

    case 'quartile': {
      const newLow = pick === 'new' ? state.low : state.mid + 1;
      const newHigh = pick === 'new' ? state.mid : state.high;
      if (newLow >= newHigh) return { type: 'done', rank: newLow };
      const ratio = pick === 'new' ? 0.25 : 0.75;
      const nextMid = Math.max(
        newLow,
        Math.min(newLow + Math.floor((newHigh - newLow) * ratio), newHigh - 1),
      );
      return {
        type: 'next',
        state: { ...state, low: newLow, high: newHigh, mid: nextMid, round: nextRound },
      };
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run services/__tests__/rankingAlgorithm.test.ts && npx tsc --noEmit`
Expected: 7 tests PASS, no type errors.

- [ ] **Step 5: Commit**

```bash
git add services/rankingAlgorithm.ts services/__tests__/rankingAlgorithm.test.ts
git commit -m "feat(web): port advanceSmallTier small-tier state machine from iOS with full test parity"
```

---

### Task 5: `RankingSession` facade (web)

One object that picks the placement strategy by tier size (0 → immediate, ≤5 → compare_all, ≤20 → seed/quartile, >20 → 5-phase engine) and exposes a uniform `start / submit / undo` API. This is what the four web surfaces will call instead of carrying their own copies. It also gives the small-tier path undo support for the first time.

**Files:**
- Create: `services/rankingSession.ts`
- Create: `services/__tests__/rankingSession.test.ts`

**Interfaces:**
- Consumes: `SpoolRankingEngine` (`start/submitChoice/skip/undo`), `computePredictionSignals` from `./spoolPrediction`, `advanceSmallTier`, `SmallTierState`, `classifyBracket`, `computeSeedIndex`, `computeTierScore` from `./rankingAlgorithm`, `TIER_SCORE_RANGES` from `../constants`, types from `../types`.
- Produces (Tasks 6, 7, 9 depend on these exact names):

```ts
export type SessionChoice = 'new' | 'existing' | 'too_tough' | 'skip';
export type SessionResult =
  | { type: 'comparison'; comparison: ComparisonRequest }
  | { type: 'done'; finalRank: number; finalScore: number | null };
export class RankingSession {
  constructor(newItem: RankedItem, tier: Tier, allItems: RankedItem[]);
  start(): SessionResult;
  submit(choice: SessionChoice): SessionResult;
  undo(): SessionResult | null;
}
```

`finalScore` is `null` on the small-tier and empty-tier paths (rank-only placement, score recomputed by `computeAllScores` at persist time — same as today), and a number on the engine path.

- [ ] **Step 1: Write the failing tests**

Create `services/__tests__/rankingSession.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { RankingSession } from '../rankingSession';
import { Tier, RankedItem } from '../../types';

const GENRES = ['Drama', 'Action', 'Comedy', 'Horror', 'Sci-Fi'];

// Factory for test items. If RankedItem gains new required fields,
// extend here — tsc will flag it.
function mkItem(i: number, tier: Tier, rank: number): RankedItem {
  return {
    id: `m${i}`,
    title: `Movie ${i}`,
    genres: [GENRES[i % GENRES.length]],
    tier,
    rank,
    globalScore: 5 + (i % 5),
  } as RankedItem;
}

function mkTier(tier: Tier, count: number): RankedItem[] {
  return Array.from({ length: count }, (_, i) => mkItem(i, tier, i));
}

const newItem = (id = 'new1'): RankedItem =>
  ({ id, title: 'New Movie', genres: ['Drama'], tier: Tier.A, rank: 0, globalScore: 7.5 } as RankedItem);

describe('RankingSession — strategy selection', () => {
  it('empty tier → immediate done at rank 0, null score', () => {
    const s = new RankingSession(newItem(), Tier.A, []);
    expect(s.start()).toEqual({ type: 'done', finalRank: 0, finalScore: null });
  });

  it('≤5 items → compare_all starting at rank 0, phase binary_search', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    expect(r.comparison.movieB.id).toBe('m0');
    expect(r.comparison.phase).toBe('binary_search');
    expect(r.comparison.round).toBe(1);
  });

  it('6–20 items → seed mode pivots via computeSeedIndex', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 8));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    // newItem.globalScore = 7.5 is inside A range [7.0, 8.9] → aligned seed,
    // closest tier score to 7.5. Just assert it's a valid index and phase.
    expect(r.comparison.phase).toBe('binary_search');
    expect(Number(r.comparison.movieB.id.slice(1))).toBeGreaterThanOrEqual(0);
  });

  it('>20 items → engine mode (phase is an engine phase, not binary_search)', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    expect(['probe', 'escalation', 'cross_genre', 'settlement']).toContain(r.comparison.phase);
  });
});

describe('RankingSession — small-tier flow', () => {
  it('compare_all: new wins on round 2 → done at rank 1', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    const r1 = s.submit('existing');
    if (r1.type !== 'comparison') throw new Error('expected comparison');
    expect(r1.comparison.movieB.id).toBe('m1');
    const r2 = s.submit('new');
    expect(r2).toEqual({ type: 'done', finalRank: 1, finalScore: null });
  });

  it('too_tough / skip inserts at current cursor', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    s.submit('existing'); // cursor now at mid=1
    const r = s.submit('too_tough');
    expect(r).toEqual({ type: 'done', finalRank: 1, finalScore: null });
  });

  it('undo restores the previous small-tier comparison', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    const first = s.start();
    if (first.type !== 'comparison') throw new Error('expected comparison');
    s.submit('existing');
    const undone = s.undo();
    if (!undone || undone.type !== 'comparison') throw new Error('expected restored comparison');
    expect(undone.comparison.movieB.id).toBe(first.comparison.movieB.id);
    // Replaying the same choice reproduces the same next state
    const replay = s.submit('existing');
    if (replay.type !== 'comparison') throw new Error('expected comparison');
    expect(replay.comparison.movieB.id).toBe('m1');
  });
});

describe('RankingSession — engine flow', () => {
  it('delegates to the engine and completes with a numeric score', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    let r = s.start();
    let guard = 0;
    while (r.type === 'comparison' && guard < 30) {
      r = s.submit('new');
      guard++;
    }
    if (r.type !== 'done') throw new Error('engine did not converge');
    expect(typeof r.finalScore).toBe('number');
    expect(r.finalRank).toBeGreaterThanOrEqual(0);
  });

  it('skip on engine path finalizes at tentative score', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    s.start();
    const r = s.submit('skip');
    if (r.type !== 'done') throw new Error('expected done after skip');
    expect(typeof r.finalScore).toBe('number');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run services/__tests__/rankingSession.test.ts`
Expected: FAIL — cannot resolve `../rankingSession`.

- [ ] **Step 3: Implement `RankingSession`**

Create `services/rankingSession.ts`:

```ts
/**
 * RankingSession — uniform facade over the placement strategies.
 *
 * Strategy by target-tier size:
 *   0      → immediate insert at rank 0
 *   1–5    → compare_all sequential walk       (advanceSmallTier)
 *   6–20   → seed pivot + quartile narrowing   (advanceSmallTier)
 *   21+    → 5-phase genre-anchored engine     (SpoolRankingEngine)
 *
 * Replaces the inline smallTierRef/engineRef copies previously duplicated
 * across RankingFlowModal, AddMediaModal, AddTVSeasonModal, and
 * MovieOnboardingPage. finalScore is null on small-tier/empty paths
 * (rank-only insertion; scores are recomputed by computeAllScores at
 * persist time) and numeric on the engine path.
 */

import { Tier, RankedItem, ComparisonRequest } from '../types';
import { TIER_SCORE_RANGES } from '../constants';
import { SpoolRankingEngine } from './spoolRankingEngine';
import { computePredictionSignals } from './spoolPrediction';
import {
  advanceSmallTier,
  classifyBracket,
  computeSeedIndex,
  computeTierScore,
  SmallTierState,
} from './rankingAlgorithm';

export type SessionChoice = 'new' | 'existing' | 'too_tough' | 'skip';

export type SessionResult =
  | { type: 'comparison'; comparison: ComparisonRequest }
  | { type: 'done'; finalRank: number; finalScore: number | null };

const SMALL_TIER_QUESTION = 'Which do you prefer?';

interface SmallSnapshot {
  state: SmallTierState;
  comparison: ComparisonRequest;
}

export class RankingSession {
  private readonly newItem: RankedItem;
  private readonly tier: Tier;
  private readonly allItems: RankedItem[];

  private engine: SpoolRankingEngine | null = null;
  private small: SmallTierState | null = null;
  private tierItems: RankedItem[] = [];
  private smallHistory: SmallSnapshot[] = [];
  private current: ComparisonRequest | null = null;

  constructor(newItem: RankedItem, tier: Tier, allItems: RankedItem[]) {
    this.newItem = newItem;
    this.tier = tier;
    this.allItems = allItems;
  }

  start(): SessionResult {
    this.tierItems = this.allItems
      .filter((i) => i.tier === this.tier)
      .sort((a, b) => a.rank - b.rank);

    if (this.tierItems.length === 0) {
      return { type: 'done', finalRank: 0, finalScore: null };
    }

    if (this.tierItems.length <= 5) {
      this.small = {
        mode: 'compare_all',
        tierCount: this.tierItems.length,
        low: 0,
        high: this.tierItems.length,
        mid: 0,
        round: 1,
        seedIdx: 0,
      };
      return this.emitSmallComparison();
    }

    if (this.tierItems.length <= 20) {
      const range = TIER_SCORE_RANGES[this.tier];
      const tierScores = this.tierItems.map((_, idx) =>
        computeTierScore(idx, this.tierItems.length, range.min, range.max),
      );
      const seedIdx = computeSeedIndex(tierScores, range.min, range.max, this.newItem.globalScore);
      this.small = {
        mode: 'seed',
        tierCount: this.tierItems.length,
        low: 0,
        high: this.tierItems.length,
        mid: seedIdx,
        round: 1,
        seedIdx,
      };
      return this.emitSmallComparison();
    }

    this.engine = new SpoolRankingEngine();
    const bracket = this.newItem.bracket ?? classifyBracket(this.newItem.genres);
    const signals = computePredictionSignals(
      this.allItems,
      this.newItem.genres[0] ?? '',
      bracket,
      this.newItem.globalScore,
      this.tier,
    );
    return this.mapEngineResult(
      this.engine.start(this.newItem, this.tier, this.allItems, signals),
    );
  }

  submit(choice: SessionChoice): SessionResult {
    if (this.small) return this.submitSmall(choice);
    if (this.engine) return this.submitEngine(choice);
    throw new Error('RankingSession.submit called before start() or after done');
  }

  undo(): SessionResult | null {
    if (this.small || this.smallHistory.length > 0) {
      const snap = this.smallHistory.pop();
      if (!snap) return null;
      this.small = snap.state;
      this.current = snap.comparison;
      return { type: 'comparison', comparison: snap.comparison };
    }
    if (this.engine) {
      const r = this.engine.undo();
      if (!r || !r.comparison) return null;
      this.current = r.comparison;
      return { type: 'comparison', comparison: r.comparison };
    }
    return null;
  }

  // ── small-tier path ──────────────────────────────────────────────────

  private submitSmall(choice: SessionChoice): SessionResult {
    const st = this.small!;
    if (choice === 'too_tough' || choice === 'skip') {
      this.small = null;
      return { type: 'done', finalRank: st.mid, finalScore: null };
    }
    if (this.current) {
      this.smallHistory.push({ state: st, comparison: this.current });
    }
    const step = advanceSmallTier(st, choice);
    if (step.type === 'done') {
      this.small = null;
      return { type: 'done', finalRank: step.rank, finalScore: null };
    }
    this.small = step.state;
    return this.emitSmallComparison();
  }

  private emitSmallComparison(): SessionResult {
    const st = this.small!;
    const comparison: ComparisonRequest = {
      movieA: this.newItem,
      movieB: this.tierItems[st.mid],
      question: SMALL_TIER_QUESTION,
      phase: 'binary_search',
      round: st.round,
    };
    this.current = comparison;
    return { type: 'comparison', comparison };
  }

  // ── engine path ──────────────────────────────────────────────────────

  private submitEngine(choice: SessionChoice): SessionResult {
    const engine = this.engine!;
    if (choice === 'too_tough' || choice === 'skip') {
      return this.mapEngineResult(engine.skip());
    }
    const winnerId =
      choice === 'new' ? this.newItem.id : this.current?.movieB.id ?? '';
    return this.mapEngineResult(engine.submitChoice(winnerId));
  }

  private mapEngineResult(r: {
    type: 'comparison' | 'done';
    comparison?: ComparisonRequest;
    finalRank?: number;
    finalScore?: number;
  }): SessionResult {
    if (r.type === 'done') {
      return { type: 'done', finalRank: r.finalRank!, finalScore: r.finalScore! };
    }
    this.current = r.comparison!;
    return { type: 'comparison', comparison: r.comparison! };
  }
}
```

Note: if `EngineResult` in `types.ts` already matches the `mapEngineResult` parameter shape, import and use it directly instead of the inline structural type.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run services/__tests__/rankingSession.test.ts && npx tsc --noEmit`
Expected: 9 tests PASS, no type errors.

- [ ] **Step 5: Commit**

```bash
git add services/rankingSession.ts services/__tests__/rankingSession.test.ts
git commit -m "feat(web): RankingSession facade unifying small-tier and engine placement"
```

---

### Task 6: Migrate `RankingFlowModal` to `RankingSession` (reference migration)

Replace the inline `smallTierRef`/`engineRef` machinery with the session. This is the template the Task 7 migrations copy.

**Files:**
- Modify: `components/media/RankingFlowModal.tsx` (state refs ~lines 60–90; `proceedFromNotes` lines 111–152; `handleCompareChoice` lines 154–240; `handleUndo` lines 242–248)

**Interfaces:**
- Consumes: `RankingSession`, `SessionChoice` from `../../services/rankingSession`.
- Produces: no API change — the component's props and rendered behavior are identical.

- [ ] **Step 1: Swap the refs**

Delete the `smallTierRef` and `engineRef` declarations (and their type imports if now unused). Add:

```ts
import { RankingSession } from '../../services/rankingSession';
```

```ts
  const sessionRef = useRef<RankingSession | null>(null);
```

- [ ] **Step 2: Replace `proceedFromNotes`**

```ts
  const proceedFromNotes = (overrideSkip?: boolean) => {
    const tierItems = getTierItems(selectedTier!);
    const item = selectedItem;
    const finalNotes = overrideSkip ? undefined : (notes.trim() || undefined);
    const finalWatchedWith = overrideSkip ? undefined : (watchedWithUserIds.length > 0 ? watchedWithUserIds : undefined);

    if (tierItems.length === 0) {
      onAdd({ ...item, tier: selectedTier!, rank: 0, notes: finalNotes, watchedWithUserIds: finalWatchedWith });
      onClose();
      return;
    }

    const session = new RankingSession(item, selectedTier!, currentItems);
    sessionRef.current = session;
    const result = session.start();

    if (result.type === 'done') {
      handleInsertAt(result.finalRank);
    } else {
      setCurrentComparison(result.comparison);
      setStep('compare');
    }
  };
```

Behavior notes (verify while editing): the empty-tier fast path stays in the component because it is the only branch that uses `finalNotes`/`finalWatchedWith` directly (`handleInsertAt` reads live state — same as before). The session reproduces the old thresholds exactly: ≤5 compare_all, ≤20 seed, >20 engine.

- [ ] **Step 3: Replace `handleCompareChoice` and `handleUndo`**

```ts
  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    if (!currentComparison) return;
    const session = sessionRef.current;
    if (!session) return;
    if (isProcessingRef.current) return;
    isProcessingRef.current = true;

    try {
      if (onCompare && selectedItem && selectedTier) {
        onCompare({
          sessionId,
          movieAId: currentComparison.movieA.id,
          movieBId: currentComparison.movieB.id,
          winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
          round: currentComparison.round,
          phase: currentComparison.phase,
          questionText: currentComparison.question,
        });
      }

      const result = session.submit(choice);
      if (result.type === 'done') {
        sessionRef.current = null;
        handleInsertAt(result.finalRank);
      } else {
        setCurrentComparison(result.comparison);
      }
    } finally {
      isProcessingRef.current = false;
    }
  };

  const handleUndo = () => {
    const result = sessionRef.current?.undo();
    if (result && result.type === 'comparison') {
      setCurrentComparison(result.comparison);
    }
  };
```

- [ ] **Step 4: Clean imports and typecheck**

Remove now-unused imports from the file (candidates: `SpoolRankingEngine`, `computePredictionSignals`, `computeSeedIndex`, `computeTierScore`, `classifyBracket`, `TIER_SCORE_RANGES` — keep any that other parts of the file still use; check with editor/tsc rather than assuming).

Run: `npx tsc --noEmit && npm test`
Expected: no type errors, all suites PASS.

- [ ] **Step 5: Manual smoke test**

Run: `npm run dev` and in the browser: open the ranking flow for (a) a tier with ≤5 items and rank via 2 comparisons, (b) a tier with >20 items and complete an engine flow, (c) hit undo mid-flow in both. Expected: identical UX to before; undo now also works in the small-tier flow (previously a silent no-op).

- [ ] **Step 6: Commit**

```bash
git add components/media/RankingFlowModal.tsx
git commit -m "refactor(web): RankingFlowModal placement via RankingSession"
```

---

### Task 7: Migrate the remaining three web surfaces

Apply the Task 6 template to the other three copies. Each sub-step is read-first: identify the file's local equivalents of the three integration points (insert-callback, close-callback, comparison-log callback), then apply the same replacement.

**Files:**
- Modify: `components/media/AddMediaModal.tsx` (comparison logic ~lines 355–517)
- Modify: `components/media/AddTVSeasonModal.tsx` (comparison logic ~lines 398–549)
- Modify: `pages/MovieOnboardingPage.tsx` (comparison logic ~lines 261–423)

**Interfaces:**
- Consumes: `RankingSession`, `SessionChoice` from `services/rankingSession` — exactly as in Task 6.
- Produces: no API changes. MovieOnboardingPage gains `too_tough` semantics (insert at cursor) that the other surfaces already had — this closes a known divergence, and its two-button UI simply never sends the value, so nothing visible changes.

- [ ] **Step 1: Migrate `AddMediaModal.tsx`**

Read the file's `proceedFromNotes`/`handleCompareChoice` block first (~355–517). It is a near-verbatim copy of RankingFlowModal's. Apply the identical transformation from Task 6 Steps 1–3, keeping this file's own insert function (`handleInsertAt`), its `onCompare` logging block, and its wizard-step navigation intact. Delete the local `smallTierRef`/`engineRef` and dead imports.

Run: `npx tsc --noEmit && npm test`
Expected: clean.

```bash
git add components/media/AddMediaModal.tsx
git commit -m "refactor(web): AddMediaModal placement via RankingSession"
```

- [ ] **Step 2: Migrate `AddTVSeasonModal.tsx`**

Same transformation (~lines 398–549). TV items flow through unchanged — `RankingSession` is media-agnostic (it only reads `id`, `genres`, `tier`, `rank`, `globalScore`, `bracket`). Keep the `show_detail` season-picker step untouched; only the tier→compare machinery changes.

Run: `npx tsc --noEmit && npm test`
Expected: clean.

```bash
git add components/media/AddTVSeasonModal.tsx
git commit -m "refactor(web): AddTVSeasonModal placement via RankingSession"
```

- [ ] **Step 3: Migrate `MovieOnboardingPage.tsx`**

Read its compare block (~261–423) first. Two known divergences to handle:
1. Its choice type lacks `'too_tough'` — its `handleCompareChoice` signature stays two-choice at the UI layer; internally call `session.submit(choice)` with `'new' | 'existing'` only. Do not add a too-tough button (out of scope).
2. It logs comparisons to Supabase inline instead of an `onCompare` prop — KEEP that inline logging block exactly where it is, before the `session.submit` call, same as the `onCompare` block sits in Task 6.

Its strategy-selection code (`proceedFromNotes` equivalent) is replaced by `new RankingSession(...)` + `start()` exactly as in Task 6 Step 2, using this page's own insert/finish functions.

Run: `npx tsc --noEmit && npm test`
Expected: clean.

- [ ] **Step 4: Manual smoke test of onboarding**

Run: `npm run dev`, walk the onboarding grid → tier → head-to-head flow with at least 6 ranked picks so the seed path triggers. Expected: identical behavior.

- [ ] **Step 5: Commit**

```bash
git add pages/MovieOnboardingPage.tsx
git commit -m "refactor(web): onboarding placement via RankingSession, closes small-tier divergence"
```

---

### Task 8: `PlacementSession` facade (iOS) and `RankH2HScreen` migration

Give iOS the same facade shape and delete RankH2HScreen's duplicated mirror struct and enum-bridging. Also aligns the compare-all phase label with web (`.binarySearch` instead of `.probe` — metadata only).

**Files:**
- Create: `ios/Spool/Sources/Spool/Algorithm/PlacementSession.swift`
- Create: `ios/Spool/Tests/SpoolTests/PlacementSessionTests.swift`
- Modify: `ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift` (delete private `SmallTierState` struct lines ~44–68, `startCompareAll`/`startSeedMode` ~316–366, `submitSmallTier` ~394–451; rewire `start`/`submit`/`skip`)

**Interfaces:**
- Consumes: `SpoolRankingEngine`, `RankingAlgorithm.advanceSmallTier`, `RankingAlgorithm.computeSeedIndex`, `RankingAlgorithm.computeTierScore`, `SpoolPrediction.computePredictionSignals`, `Tier.scoreRange` (Task 2), `EngineResult`, `ComparisonRequest`, `RankedItem`.
- Produces:

```swift
public final class PlacementSession {
    public init()
    public func start(newItem: RankedItem, tier: Tier, allItems: [RankedItem]) -> EngineResult
    /// nil = out-of-sync tap, caller should ignore (matches current NSLog behavior)
    public func submit(winnerId: String) -> EngineResult?
    /// nil = engine skip failed (rare), caller keeps its fallback
    public func skip() -> EngineResult?
}
```

- [ ] **Step 1: Write the failing tests**

Create `ios/Spool/Tests/SpoolTests/PlacementSessionTests.swift`:

```swift
import XCTest
@testable import Spool

final class PlacementSessionTests: XCTestCase {

    private func mkItem(_ i: Int, tier: Tier, rank: Int) -> RankedItem {
        let genres = ["Drama", "Action", "Comedy", "Horror", "Sci-Fi"]
        return RankedItem(
            id: "m\(i)", title: "Movie \(i)",
            genres: [genres[i % genres.count]],
            tier: tier, rank: rank,
            globalScore: 5.0 + Double(i % 5)
        )
    }

    private func mkTier(_ tier: Tier, count: Int) -> [RankedItem] {
        (0..<count).map { mkItem($0, tier: tier, rank: $0) }
    }

    private var newItem: RankedItem {
        RankedItem(id: "new1", title: "New Movie", genres: ["Drama"],
                   tier: .A, rank: 0, globalScore: 7.5)
    }

    func testSmallTierCompareAllWalkMatchesWebSemantics() {
        let session = PlacementSession()
        let start = session.start(newItem: newItem, tier: .A, allItems: mkTier(.A, 3))
        guard case .comparison(let c0) = start else { return XCTFail("expected comparison") }
        XCTAssertEqual(c0.movieB.id, "m0")
        XCTAssertEqual(c0.phase, .binarySearch) // aligned with web (was .probe)
        XCTAssertEqual(c0.round, 1)

        guard case .comparison(let c1)? = session.submit(winnerId: "m0") else {
            return XCTFail("expected next comparison")
        }
        XCTAssertEqual(c1.movieB.id, "m1")

        guard case .done(let rank, _)? = session.submit(winnerId: newItem.id) else {
            return XCTFail("expected done")
        }
        XCTAssertEqual(rank, 1)
    }

    func testEngineModeAboveTwentyItemsCompletes() {
        let session = PlacementSession()
        var result = session.start(newItem: newItem, tier: .A, allItems: mkTier(.A, 25))
        var guardCount = 0
        while case .comparison = result, guardCount < 30 {
            guard let next = session.submit(winnerId: newItem.id) else {
                return XCTFail("engine rejected a valid submit")
            }
            result = next
            guardCount += 1
        }
        guard case .done(let rank, let score) = result else {
            return XCTFail("engine did not converge")
        }
        XCTAssertGreaterThanOrEqual(rank, 0)
        XCTAssertGreaterThan(score, 0)
    }

    func testSkipInSmallTierInsertsAtCursor() {
        let session = PlacementSession()
        _ = session.start(newItem: newItem, tier: .A, allItems: mkTier(.A, 3))
        _ = session.submit(winnerId: "m0") // cursor -> 1
        guard case .done(let rank, _)? = session.skip() else {
            return XCTFail("expected done from skip")
        }
        XCTAssertEqual(rank, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ios/Spool --filter PlacementSessionTests`
Expected: BUILD FAILURE — `PlacementSession` unresolved.

- [ ] **Step 3: Implement `PlacementSession`**

Create `ios/Spool/Sources/Spool/Algorithm/PlacementSession.swift`:

```swift
import Foundation

/// Uniform facade over the two placement strategies — mirrors the web's
/// `services/rankingSession.ts`. Strategy by target-tier size:
///   0     → engine (returns immediate .done at tier midpoint)
///   1–5   → compare-all walk       (RankingAlgorithm.advanceSmallTier)
///   6–20  → seed + quartile        (RankingAlgorithm.advanceSmallTier)
///   21+   → 5-phase engine         (SpoolRankingEngine)
/// Replaces RankH2HScreen's private SmallTierState mirror struct and the
/// enum-bridging in submitSmallTier.
public final class PlacementSession {

    private let smallTierQuestion = "which do you love more?"

    private var engine: SpoolRankingEngine?
    private var small: RankingAlgorithm.SmallTierState?
    private var tierItems: [RankedItem] = []
    private var newItem: RankedItem!
    private var tier: Tier!
    private var current: ComparisonRequest?

    public init() {}

    public func start(newItem: RankedItem, tier: Tier, allItems: [RankedItem]) -> EngineResult {
        self.newItem = newItem
        self.tier = tier
        self.tierItems = allItems
            .filter { $0.tier == tier }
            .sorted { $0.rank < $1.rank }

        if tierItems.isEmpty || tierItems.count > 20 {
            // Empty tier delegates to the engine, which returns an
            // immediate .done at the tier midpoint — current iOS behavior.
            let engine = SpoolRankingEngine()
            self.engine = engine
            let bracket = newItem.bracket ?? RankingAlgorithm.classifyBracket(genres: newItem.genres)
            let signals = SpoolPrediction.computePredictionSignals(
                allItems: allItems,
                primaryGenre: newItem.genres.first ?? "",
                bracket: bracket,
                globalScore: newItem.globalScore,
                tier: tier
            )
            let result = engine.start(newMovie: newItem, tier: tier, allItems: allItems, signals: signals)
            if case .comparison(let c) = result { current = c }
            return result
        }

        if tierItems.count <= 5 {
            small = RankingAlgorithm.SmallTierState(
                mode: .compareAll, tierCount: tierItems.count,
                low: 0, high: tierItems.count, mid: 0, round: 1, seedIdx: 0
            )
            return emitSmallComparison()
        }

        // 6–20: seed mode
        let range = tier.scoreRange
        let tierScores = (0..<tierItems.count).map { idx in
            RankingAlgorithm.computeTierScore(
                position: idx, totalInTier: tierItems.count,
                tierMin: range.min, tierMax: range.max
            )
        }
        let seedIdx = RankingAlgorithm.computeSeedIndex(
            tierItemScores: tierScores,
            tierMin: range.min, tierMax: range.max,
            globalAvg: newItem.globalScore
        )
        small = RankingAlgorithm.SmallTierState(
            mode: .seed, tierCount: tierItems.count,
            low: 0, high: tierItems.count, mid: seedIdx, round: 1, seedIdx: seedIdx
        )
        return emitSmallComparison()
    }

    public func submit(winnerId: String) -> EngineResult? {
        if small != nil { return submitSmall(winnerId: winnerId) }
        guard let engine else { return nil }
        do {
            let result = try engine.submitChoice(winnerId: winnerId)
            if case .comparison(let c) = result { current = c }
            return result
        } catch {
            // Out-of-sync tap (stale double-tap) — caller ignores,
            // session stays alive. Matches previous screen behavior.
            return nil
        }
    }

    public func skip() -> EngineResult? {
        if let st = small {
            // "Too tough" inserts at the current cursor with a midpoint
            // score for celebration copy — matches previous screen behavior.
            small = nil
            current = nil
            let range = tier.scoreRange
            let score = ((range.min + range.max) / 2 * 100).rounded() / 100
            return .done(finalRank: st.mid, finalScore: score)
        }
        guard let engine else { return nil }
        do {
            let result = try engine.skip()
            if case .comparison(let c) = result { current = c }
            return result
        } catch {
            return nil
        }
    }

    // MARK: small-tier internals

    private func submitSmall(winnerId: String) -> EngineResult? {
        guard let st = small, let c = current else { return nil }
        let pick: RankingAlgorithm.NarrowChoice = winnerId == c.movieA.id ? .new : .existing

        switch RankingAlgorithm.advanceSmallTier(state: st, pick: pick) {
        case .done(let rank):
            small = nil
            current = nil
            // Approximate score for celebration copy only — true insertion
            // order is set by rank_position in the DB.
            let range = tier.scoreRange
            let total = max(st.tierCount + 1, 1)
            let frac = Double(total - rank - 1) / Double(total)
            let score = ((range.min + (range.max - range.min) * frac) * 100).rounded() / 100
            return .done(finalRank: rank, finalScore: score)

        case .next(let nextState):
            small = nextState
            return emitSmallComparison()
        }
    }

    private func emitSmallComparison() -> EngineResult {
        guard let st = small else {
            return .done(finalRank: 0, finalScore: 0)
        }
        let comparison = ComparisonRequest(
            movieA: newItem,
            movieB: tierItems[st.mid],
            question: smallTierQuestion,
            phase: .binarySearch, // aligned with web (compare-all previously used .probe)
            round: st.round
        )
        current = comparison
        return .comparison(comparison)
    }
}
```

Note: `RankingAlgorithm.classifyBracket` takes `genres:` — verify the label matches the declaration (`classifyBracket(genres:)` per `RankingAlgorithm.swift:10`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ios/Spool --filter PlacementSessionTests`
Expected: 3 tests PASS.

- [ ] **Step 5: Migrate `RankH2HScreen`**

In `ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift`:
1. Delete the private `SmallTierState` struct (lines ~44–68) and the `@State private var smallTier` property.
2. Replace the engine property with `private let session = PlacementSession()` (keep whatever `@State` wrapper the engine currently uses if the view relies on identity — read the declaration ~line 20 first).
3. In the flow-start function (~lines 250–314): replace the three-way dispatch to `startCompareAll` / `startSeedMode` / engine-start with a single call, preserving the existing `newItem` construction (which must keep setting `globalScore: movie.voteAverage`):

```swift
        let result = session.start(newItem: newItem, tier: tier, allItems: all)
        handle(result)
```

4. Delete `startCompareAll` and `startSeedMode` entirely.
5. Replace `submit(winnerId:)` body:

```swift
    private func submit(winnerId: String) {
        guard !done, comparison != nil else { return }
        if let result = session.submit(winnerId: winnerId) {
            handle(result)
        } else {
            NSLog("[RankH2HScreen] submit ignored: out-of-sync tap")
        }
    }
```

6. Delete `submitSmallTier` entirely.
7. Replace the `skip()` small-tier branch and engine branch with:

```swift
    private func skip() {
        guard !done else { return }
        if let result = session.skip() {
            handle(result)
        } else {
            NSLog("[RankH2HScreen] skip errored: finishing at tentative state")
            done = true
        }
    }
```

8. Verify `handle(_ result: EngineResult)` (existing) sets `comparison`/`finalRank`/`finalScore`/`done` for both `.comparison` and `.done` cases — it already handles engine results, and small-tier results now arrive in the same shape.
9. Check for any remaining references to the deleted symbols: `grep -n "smallTier\|startCompareAll\|startSeedMode" ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift` — expect zero hits. Also check the preview/fixture section (~line 520) still compiles.

- [ ] **Step 6: Full iOS suite + build**

Run: `swift test --package-path ios/Spool`
Expected: all PASS (engine tests, small-tier tests, prediction, prompts, placement session, onboarding queue, toast).

- [ ] **Step 7: Commit**

```bash
git add ios/Spool/Sources/Spool/Algorithm/PlacementSession.swift ios/Spool/Tests/SpoolTests/PlacementSessionTests.swift ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift
git commit -m "refactor(ios): PlacementSession facade; RankH2HScreen drops mirror struct and enum bridging"
```

---

### Task 9: Golden fixture corpus shared by vitest and XCTest

Generate a deterministic JSON corpus from the TypeScript side (the reference), replay it in both test runners. Any future divergence in engine, prediction, small-tier logic, or constants fails a test instead of corrupting the shared database.

**Files:**
- Create: `scripts/generateEngineFixtures.ts`
- Create: `fixtures/engine-parity.json` (generated artifact, committed)
- Create: `services/__tests__/engineParity.test.ts`
- Create: `ios/Spool/Tests/SpoolTests/EngineParityTests.swift`
- Modify: `package.json` (add `tsx` devDependency + `fixtures:engine` script)

**Interfaces:**
- Consumes: `RankingSession` (Task 5), `PlacementSession` (Task 8), constants from both platforms.
- Produces: fixture schema (all consumers depend on these exact field names):

```json
{
  "constants": {
    "tierScoreRanges": { "S": {"min": 9.0, "max": 10.0}, "A": {"min": 7.0, "max": 8.9}, "B": {"min": 5.0, "max": 6.9}, "C": {"min": 3.0, "max": 4.9}, "D": {"min": 0.1, "max": 2.9} },
    "newUserThreshold": 15,
    "predictionWeights": { "genreAffinity": 0.45, "globalScore": 0.35, "bracketAffinity": 0.20 }
  },
  "cases": [
    {
      "name": "engine-25-all-new",
      "tier": "A",
      "newItem": { "id": "new1", "title": "New Movie", "genres": ["Drama"], "globalScore": 7.5 },
      "allItems": [ { "id": "m0", "title": "Movie 0", "genres": ["Drama"], "tier": "A", "rank": 0, "globalScore": 5.0 } ],
      "choices": ["new", "new"],
      "expectedSteps": [ { "round": 1, "phase": "probe", "movieBId": "m3" } ],
      "expectedFinalRank": 0,
      "expectedFinalScore": 8.9
    }
  ]
}
```

`expectedFinalScore` is `null` for small-tier cases (platforms compute display-only scores differently there; rank is the contract). `choices` values are `"new" | "existing" | "skip"`.

- [ ] **Step 1: Add tsx and the npm script**

Run: `npm install --save-dev tsx`
Add to `package.json` scripts: `"fixtures:engine": "tsx scripts/generateEngineFixtures.ts"`.

- [ ] **Step 2: Write the generator**

Create `scripts/generateEngineFixtures.ts`:

```ts
/**
 * Generates fixtures/engine-parity.json from the TypeScript ranking
 * implementation (the semantic reference). Both vitest
 * (services/__tests__/engineParity.test.ts) and XCTest
 * (ios/Spool/Tests/SpoolTests/EngineParityTests.swift) replay this file.
 *
 * Fully deterministic — no Date, no Math.random. Regenerate with:
 *   npm run fixtures:engine
 * Only regenerate when TS ranking semantics change INTENTIONALLY; the
 * diff is the review artifact.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { RankingSession, SessionChoice } from '../services/rankingSession';
import { Tier, RankedItem } from '../types';
import { TIER_SCORE_RANGES, NEW_USER_THRESHOLD } from '../constants';

const GENRES = ['Drama', 'Action', 'Comedy', 'Horror', 'Sci-Fi'];

function mkItem(i: number, tier: Tier, rank: number): RankedItem {
  return {
    id: `m${i}`,
    title: `Movie ${i}`,
    genres: [GENRES[i % GENRES.length]],
    tier,
    rank,
    globalScore: 5 + (i % 5),
  } as RankedItem;
}

function mkTier(tier: Tier, count: number): RankedItem[] {
  return Array.from({ length: count }, (_, i) => mkItem(i, tier, i));
}

const newItem = (genre = 'Drama', globalScore = 7.5): RankedItem =>
  ({ id: 'new1', title: 'New Movie', genres: [genre], tier: Tier.A, rank: 0, globalScore } as RankedItem);

interface CaseSpec {
  name: string;
  tier: Tier;
  item: RankedItem;
  allItems: RankedItem[];
  choices: SessionChoice[];
}

// Choice sequences are longer than any flow needs; replay stops at done.
const always = (c: SessionChoice) => Array.from({ length: 30 }, () => c);
const alternating = (): SessionChoice[] =>
  Array.from({ length: 30 }, (_, i) => (i % 2 === 0 ? 'new' : 'existing') as SessionChoice);

const specs: CaseSpec[] = [
  { name: 'small-3-compare-all-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: always('new') },
  { name: 'small-3-compare-all-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: always('existing') },
  { name: 'small-3-skip-after-one', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: ['existing', 'skip'] },
  { name: 'small-8-seed-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: always('new') },
  { name: 'small-8-seed-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: always('existing') },
  { name: 'small-8-seed-alternating', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: alternating() },
  { name: 'small-20-seed-alternating', tier: Tier.B, item: newItem('Action', 6.0), allItems: mkTier(Tier.B, 20), choices: alternating() },
  { name: 'engine-25-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: always('new') },
  { name: 'engine-25-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: always('existing') },
  { name: 'engine-25-alternating', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: alternating() },
  { name: 'engine-25-skip-after-two', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: ['new', 'existing', 'skip'] },
  { name: 'engine-25-offgenre-item', tier: Tier.A, item: newItem('Horror', 8.2), allItems: mkTier(Tier.A, 25), choices: alternating() },
  { name: 'engine-40-cross-tiers', tier: Tier.A, item: newItem(), allItems: [...mkTier(Tier.A, 25), ...mkTier(Tier.B, 15).map((it, i) => ({ ...it, id: `b${i}` }))], choices: alternating() },
];

function runCase(spec: CaseSpec) {
  const session = new RankingSession(spec.item, spec.tier, spec.allItems);
  const steps: { round: number; phase: string; movieBId: string }[] = [];
  const usedChoices: SessionChoice[] = [];

  let result = session.start();
  let i = 0;
  while (result.type === 'comparison') {
    steps.push({
      round: result.comparison.round,
      phase: result.comparison.phase,
      movieBId: result.comparison.movieB.id,
    });
    if (i >= spec.choices.length) throw new Error(`${spec.name}: ran out of choices`);
    const choice = spec.choices[i++];
    usedChoices.push(choice);
    result = session.submit(choice);
  }

  return {
    name: spec.name,
    tier: spec.tier,
    newItem: { id: spec.item.id, title: spec.item.title, genres: spec.item.genres, globalScore: spec.item.globalScore ?? null },
    allItems: spec.allItems.map((it) => ({
      id: it.id, title: it.title, genres: it.genres,
      tier: it.tier, rank: it.rank, globalScore: it.globalScore ?? null,
    })),
    choices: usedChoices,
    expectedSteps: steps,
    expectedFinalRank: result.finalRank,
    expectedFinalScore: result.finalScore, // null on small-tier paths
  };
}

const out = {
  constants: {
    tierScoreRanges: TIER_SCORE_RANGES,
    newUserThreshold: NEW_USER_THRESHOLD,
    predictionWeights: { genreAffinity: 0.45, globalScore: 0.35, bracketAffinity: 0.2 },
  },
  cases: specs.map(runCase),
};

mkdirSync('fixtures', { recursive: true });
writeFileSync('fixtures/engine-parity.json', JSON.stringify(out, null, 2) + '\n');
console.log(`wrote fixtures/engine-parity.json with ${out.cases.length} cases`);
```

- [ ] **Step 3: Generate and eyeball the corpus**

Run: `npm run fixtures:engine`
Expected: `wrote fixtures/engine-parity.json with 13 cases`. Open the file and sanity-check: small cases have `expectedFinalScore: null` and `phase: "binary_search"` steps; engine cases have numeric scores and probe/escalation/cross_genre/settlement phases; `engine-25-skip-after-two` has exactly 3 choices.

- [ ] **Step 4: Write the vitest replay test**

Create `services/__tests__/engineParity.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { RankingSession, SessionChoice } from '../rankingSession';
import { Tier, RankedItem } from '../../types';
import { TIER_SCORE_RANGES, NEW_USER_THRESHOLD } from '../../constants';

// Replays fixtures/engine-parity.json against the live TS implementation.
// If this fails, either the change to ranking semantics is unintentional
// (fix the code) or intentional (run `npm run fixtures:engine`, commit the
// diff, and expect the Swift parity test to fail until iOS is updated).

const corpus = JSON.parse(readFileSync('fixtures/engine-parity.json', 'utf8'));

describe('engine parity corpus — constants', () => {
  it('constants match the fixture', () => {
    expect(corpus.constants.tierScoreRanges).toEqual(TIER_SCORE_RANGES);
    expect(corpus.constants.newUserThreshold).toBe(NEW_USER_THRESHOLD);
  });
});

describe('engine parity corpus — replay', () => {
  for (const c of corpus.cases) {
    it(c.name, () => {
      const allItems = c.allItems.map((it: any) => ({ ...it, globalScore: it.globalScore ?? undefined }) as RankedItem);
      const item = { ...c.newItem, tier: c.tier as Tier, rank: 0, globalScore: c.newItem.globalScore ?? undefined } as RankedItem;
      const session = new RankingSession(item, c.tier as Tier, allItems);

      let result = session.start();
      let i = 0;
      const steps: any[] = [];
      while (result.type === 'comparison') {
        steps.push({ round: result.comparison.round, phase: result.comparison.phase, movieBId: result.comparison.movieB.id });
        result = session.submit(c.choices[i++] as SessionChoice);
      }

      expect(steps).toEqual(c.expectedSteps);
      expect(result.finalRank).toBe(c.expectedFinalRank);
      if (c.expectedFinalScore !== null) {
        expect(result.finalScore).toBeCloseTo(c.expectedFinalScore, 4);
      }
    });
  }
});
```

Run: `npx vitest run services/__tests__/engineParity.test.ts`
Expected: 14 tests PASS (13 cases + constants).

- [ ] **Step 5: Write the Swift replay test**

Create `ios/Spool/Tests/SpoolTests/EngineParityTests.swift`:

```swift
import XCTest
@testable import Spool

/// Replays fixtures/engine-parity.json (generated by the TypeScript
/// reference via `npm run fixtures:engine`) against the Swift
/// implementation. A failure here means the two platforms have diverged —
/// fix the Swift side, or if the TS change was intentional, port it.
final class EngineParityTests: XCTestCase {

    // MARK: fixture schema

    struct Corpus: Decodable {
        let constants: Constants
        let cases: [Case]
    }
    struct Constants: Decodable {
        let tierScoreRanges: [String: Range]
        let newUserThreshold: Int
    }
    struct Range: Decodable { let min: Double; let max: Double }
    struct Case: Decodable {
        let name: String
        let tier: String
        let newItem: Item
        let allItems: [TierItem]
        let choices: [String]
        let expectedSteps: [Step]
        let expectedFinalRank: Int
        let expectedFinalScore: Double?
    }
    struct Item: Decodable { let id: String; let title: String; let genres: [String]; let globalScore: Double? }
    struct TierItem: Decodable { let id: String; let title: String; let genres: [String]; let tier: String; let rank: Int; let globalScore: Double? }
    struct Step: Decodable { let round: Int; let phase: String; let movieBId: String }

    // MARK: helpers

    private func loadCorpus() throws -> Corpus {
        // …/ios/Spool/Tests/SpoolTests/EngineParityTests.swift → repo root is 5 hops up
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SpoolTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Spool
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("fixtures/engine-parity.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    private func tier(_ raw: String) -> Tier {
        guard let t = Tier(rawValue: raw) else {
            XCTFail("unknown tier raw value \(raw)"); return .D
        }
        return t
    }

    private func ranked(_ it: TierItem) -> RankedItem {
        RankedItem(id: it.id, title: it.title, genres: it.genres,
                   tier: tier(it.tier), rank: it.rank, globalScore: it.globalScore)
    }

    // MARK: tests

    func testConstantsMatchFixture() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.constants.newUserThreshold, SpoolConstants.newUserThreshold)
        for (raw, range) in corpus.constants.tierScoreRanges {
            let t = tier(raw)
            XCTAssertEqual(t.scoreRange.min, range.min, accuracy: 0.0001, "\(raw).min")
            XCTAssertEqual(t.scoreRange.max, range.max, accuracy: 0.0001, "\(raw).max")
        }
    }

    func testReplayAllCases() throws {
        let corpus = try loadCorpus()
        for c in corpus.cases {
            let allItems = c.allItems.map(ranked)
            let newItem = RankedItem(
                id: c.newItem.id, title: c.newItem.title, genres: c.newItem.genres,
                tier: tier(c.tier), rank: 0, globalScore: c.newItem.globalScore
            )
            let session = PlacementSession()
            var result = session.start(newItem: newItem, tier: tier(c.tier), allItems: allItems)
            var stepIdx = 0

            loop: while true {
                switch result {
                case .comparison(let comp):
                    guard stepIdx < c.expectedSteps.count else {
                        XCTFail("\(c.name): more comparisons than expected"); break loop
                    }
                    let want = c.expectedSteps[stepIdx]
                    XCTAssertEqual(comp.round, want.round, "\(c.name) step \(stepIdx) round")
                    XCTAssertEqual(comp.phase.rawValue, want.phase, "\(c.name) step \(stepIdx) phase")
                    XCTAssertEqual(comp.movieB.id, want.movieBId, "\(c.name) step \(stepIdx) movieB")

                    let choice = c.choices[stepIdx]
                    stepIdx += 1
                    let next: EngineResult?
                    switch choice {
                    case "new":      next = session.submit(winnerId: newItem.id)
                    case "existing": next = session.submit(winnerId: comp.movieB.id)
                    case "skip":     next = session.skip()
                    default:
                        XCTFail("\(c.name): unknown choice \(choice)"); break loop
                    }
                    guard let n = next else {
                        XCTFail("\(c.name): session rejected choice \(choice) at step \(stepIdx)"); break loop
                    }
                    result = n

                case .done(let rank, let score):
                    XCTAssertEqual(stepIdx, c.expectedSteps.count, "\(c.name): step count")
                    XCTAssertEqual(rank, c.expectedFinalRank, "\(c.name): finalRank")
                    if let wantScore = c.expectedFinalScore {
                        XCTAssertEqual(score, wantScore, accuracy: 0.0001, "\(c.name): finalScore")
                    }
                    break loop
                }
            }
        }
    }
}
```

Note: this assumes `Tier` has raw values `"S"`, `"A"`, `"B"`, `"C"`, `"D"` — verify with `grep -rn "enum Tier" ios/Spool/Sources/` before running, and adjust `tier(_:)` if the raw values differ.

- [ ] **Step 6: Run the Swift replay — the cross-language moment of truth**

Run: `swift test --package-path ios/Spool --filter EngineParityTests`
Expected: 2 tests PASS. If `testReplayAllCases` fails, the failure message names the case, step, and field that diverged — this is a REAL platform divergence. Diagnose which side is wrong against the fixture (TS is the reference); do not weaken the assertion.

- [ ] **Step 7: Run everything, then commit**

Run: `npm test && npx tsc --noEmit && swift test --package-path ios/Spool`
Expected: all PASS.

```bash
git add scripts/generateEngineFixtures.ts fixtures/engine-parity.json services/__tests__/engineParity.test.ts ios/Spool/Tests/SpoolTests/EngineParityTests.swift package.json package-lock.json
git commit -m "test: shared golden-fixture corpus replayed by vitest and XCTest"
```

---

### Task 10: CI gate for cross-platform parity

One workflow that runs both suites and verifies the fixture file is in sync with the TS reference. Divergence fails the PR instead of landing in the shared database.

**Files:**
- Create: `.github/workflows/engine-parity.yml`

**Interfaces:**
- Consumes: `npm run fixtures:engine` (Task 9), both test suites.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/engine-parity.yml`:

```yaml
name: engine-parity

on:
  pull_request:
    paths:
      - "services/**"
      - "constants.ts"
      - "types.ts"
      - "ios/Spool/**"
      - "fixtures/**"
      - "components/media/RankingFlowModal.tsx"
      - "components/media/AddMediaModal.tsx"
      - "components/media/AddTVSeasonModal.tsx"
      - "pages/MovieOnboardingPage.tsx"
      - ".github/workflows/engine-parity.yml"
  push:
    branches: [main]

jobs:
  parity:
    runs-on: macos-14
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - name: Install web deps
        run: npm ci

      - name: Web tests
        run: npx vitest run

      - name: Fixture freshness (TS is the reference)
        run: |
          npm run fixtures:engine
          git diff --exit-code fixtures/engine-parity.json || {
            echo "::error::fixtures/engine-parity.json is stale. Run 'npm run fixtures:engine' and commit the diff.";
            exit 1;
          }

      - name: iOS tests (includes EngineParityTests replay)
        run: swift test --package-path ios/Spool
```

- [ ] **Step 2: Validate the workflow locally as far as possible**

Run: `npx vitest run && npm run fixtures:engine && git diff --exit-code fixtures/engine-parity.json && swift test --package-path ios/Spool`
Expected: all green, no fixture diff.

- [ ] **Step 3: Commit and push the branch**

```bash
git add .github/workflows/engine-parity.yml
git commit -m "ci: engine parity gate — vitest + XCTest + fixture freshness on one workflow"
git push -u origin feat/engine-unification
```

- [ ] **Step 4: Verify CI passes on the PR**

Open a PR from `feat/engine-unification` to `main` (`gh pr create`). Watch the `engine-parity` workflow. Expected: green. Per the repo owner's global workflow rules, do not merge without CI green, and fix any failures before handing off.

---

## Self-Review Notes

- **Spec coverage:** Task 1–2 = Swift scars; Task 3 = shared dead field; Task 4 = small-tier backport with mirrored tests; Tasks 5–7 = web facade + all four surface migrations; Task 8 = iOS facade + RankH2H cleanup; Tasks 9–10 = golden corpus + CI gate. All five recommendations from the engine comparison are covered.
- **Known accepted asymmetries (do not "fix" in this plan):** per-platform question strings; small-tier `finalScore` is `null` on web but an approximate display score on iOS (fixtures assert rank only for small cases); iOS empty-tier goes through the engine (immediate midpoint done) while web fast-paths in the component — fixtures contain no empty-tier case for this reason.
- **Type consistency check:** `SmallTierState`/`advanceSmallTier` names match between Task 4 (definition) and Tasks 5, 9 (consumers); `RankingSession` constructor/method signatures match between Task 5 (definition) and Tasks 6, 7, 9; `PlacementSession.start/submit/skip` match between Task 8 (definition) and Task 9 (consumer); fixture field names match between generator (Task 9 Step 2), vitest replay (Step 4), and Swift `Decodable` structs (Step 5).
- **Verification-first steps** (Task 1 Step 2, Task 3 Step 1, Task 8 Step 5.9, Task 9 Step 5 note) exist because three claims rest on static analysis: the obfuscated expression's equivalence, `crossGenreAdjustment` being write-only, and `Tier` raw values. Each has an explicit stop-and-report instruction if the claim fails.
