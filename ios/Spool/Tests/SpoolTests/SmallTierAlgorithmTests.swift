import XCTest
@testable import Spool

/// Covers the seed + quartile binary-search path (`RankingAlgorithm
/// .advanceSmallTier`) used by `RankH2HScreen` for 6-20 item tiers.
/// Mirrors web's `RankingFlowModal.handleCompareChoice` `smallTierRef`
/// branch. The ≤5 `.compareAll` path has view-level coverage in QA
/// fixtures; this file focuses on the seed/quartile transitions.
final class SmallTierAlgorithmTests: XCTestCase {

    // MARK: helpers

    private func state(
        mode: RankingAlgorithm.SmallTierMode,
        tierCount: Int,
        low: Int, high: Int, mid: Int,
        round: Int = 1, seedIdx: Int = 0
    ) -> RankingAlgorithm.SmallTierState {
        .init(mode: mode, tierCount: tierCount,
              low: low, high: high, mid: mid,
              round: round, seedIdx: seedIdx)
    }

    // MARK: seed-mode happy path (task spec)

    /// 8-item tier, user always picks "new". Seed pivots at median (4)
    /// when globalAvg is nil, then on first "new" win we jump to
    /// mid=0 in `.quartile` mode with `[0, 4)`. Another "new" on mid=0
    /// converges at `newLow = low = 0` → insert at rank 0.
    func testSeedModeUserAlwaysPicksNewInsertsAtRankZero() {
        // Start: tier has 8 items, globalAvg unknown → seedIdx = median = 4
        let tierCount = 8
        let tierScores: [Double] = (0..<tierCount).map { idx in
            RankingAlgorithm.computeTierScore(
                position: idx, totalInTier: tierCount,
                tierMin: 7.0, tierMax: 8.9
            )
        }
        let seedIdx = RankingAlgorithm.computeSeedIndex(
            tierItemScores: tierScores,
            tierMin: 7.0, tierMax: 8.9, globalAvg: nil
        )
        XCTAssertEqual(seedIdx, 4, "median of 8 items is 8/2 = 4")

        var s = state(
            mode: .seed, tierCount: tierCount,
            low: 0, high: tierCount, mid: seedIdx,
            round: 1, seedIdx: seedIdx
        )

        // Round 1: user picks "new" at mid=4 → transition to .quartile
        // with [0, 4) and mid=0.
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("round 1: expected .next from seed mode"); return
        }
        XCTAssertEqual(s1.mode, .quartile)
        XCTAssertEqual(s1.low, 0)
        XCTAssertEqual(s1.high, 4)
        XCTAssertEqual(s1.mid, 0)
        XCTAssertEqual(s1.round, 2)
        s = s1

        // Round 2: user picks "new" again at mid=0 → newLow = low = 0,
        // newHigh = mid = 0 → newLow >= newHigh → done at 0.
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("round 2: expected .done at quartile convergence"); return
        }
        XCTAssertEqual(rank, 0, "always-new user should land at rank 0")
    }

    // MARK: seed-mode edge — new wins immediately at seed 0

    func testSeedModeNewWinsAtSeedZeroInsertsAtZero() {
        let s = state(mode: .seed, tierCount: 8,
                      low: 0, high: 8, mid: 0,
                      round: 1, seedIdx: 0)
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .done when new beats seed 0"); return
        }
        XCTAssertEqual(rank, 0)
    }

    // MARK: seed-mode edge — existing always wins

    /// 8-item tier, user always picks "existing". Seed at 4 → existing
    /// wins → transition to `.quartile` with `[5, 8)` and mid = 5 +
    /// floor(3*0.75) = 5 + 2 = 7. Existing wins again → newLow = 8,
    /// newHigh = 8 → done at 8 (inserts below everyone).
    func testSeedModeUserAlwaysPicksExistingInsertsAtEnd() {
        var s = state(mode: .seed, tierCount: 8,
                      low: 0, high: 8, mid: 4,
                      round: 1, seedIdx: 4)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("round 1: expected .next"); return
        }
        XCTAssertEqual(s1.mode, .quartile)
        XCTAssertEqual(s1.low, 5)
        XCTAssertEqual(s1.high, 8)
        XCTAssertEqual(s1.mid, 7)
        s = s1

        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("round 2: expected .done"); return
        }
        XCTAssertEqual(rank, 8, "always-existing should land below the tier")
    }

    // MARK: quartile-mode narrowing

    /// Classic quartile jump: low=0, high=8, mid=4, pick existing →
    /// newLow=5, newHigh=8, nextMid = max(5, min(5 + floor(3*0.75), 7)) = 7.
    func testQuartileExistingJumpsSeventyFivePercent() {
        let s = state(mode: .quartile, tierCount: 8,
                      low: 0, high: 8, mid: 4)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s1.low, 5)
        XCTAssertEqual(s1.high, 8)
        XCTAssertEqual(s1.mid, 7)
    }

    /// Quartile jump for "new": low=0, high=8, mid=4, pick new →
    /// newLow=0, newHigh=4, nextMid = max(0, min(0 + floor(4*0.25), 3)) = 1.
    func testQuartileNewJumpsTwentyFivePercent() {
        let s = state(mode: .quartile, tierCount: 8,
                      low: 0, high: 8, mid: 4)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s1.low, 0)
        XCTAssertEqual(s1.high, 4)
        XCTAssertEqual(s1.mid, 1)
    }

    // MARK: compareAll path parity guard

    func testCompareAllNewWinsInsertsAtCursor() {
        let s = state(mode: .compareAll, tierCount: 5,
                      low: 0, high: 5, mid: 2)
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .done"); return
        }
        XCTAssertEqual(rank, 2)
    }

    func testCompareAllLosingAllAdvancesToEnd() {
        var s = state(mode: .compareAll, tierCount: 3,
                      low: 0, high: 3, mid: 0)
        for expectedMid in [1, 2] {
            guard case .next(let ns) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
                XCTFail("expected .next at mid \(s.mid)"); return
            }
            XCTAssertEqual(ns.mid, expectedMid)
            s = ns
        }
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .done after exhausting tier"); return
        }
        XCTAssertEqual(rank, 3)
    }
}
