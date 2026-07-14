import XCTest
@testable import Spool

/// Covers the anchor + quartile path (`RankingAlgorithm.advanceSmallTier`)
/// used by `RankH2HScreen` for 6-20 item tiers. Mirrors web's
/// `services/__tests__/rankingAlgorithm.test.ts` anchor suite so both
/// platforms pin identical small-tier semantics. The ≤5 `.compareAll` path
/// has view-level coverage in QA fixtures; this file focuses on the
/// anchor/quartile transitions (owner redesign, 2026-07-13).
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

    // MARK: anchor round 1 — the tier's very best

    /// Beating the tier's best places at rank 0 in ONE comparison.
    func testAnchorBestNewWinsInsertsAtRankZero() {
        let s = state(mode: .anchorBest, tierCount: 8,
                      low: 0, high: 8, mid: 0)
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .done when new beats the tier best"); return
        }
        XCTAssertEqual(rank, 0)
    }

    /// Losing to the best moves to the WORST anchor (mid = tierCount-1).
    func testAnchorBestExistingMovesToWorstAnchor() {
        let s = state(mode: .anchorBest, tierCount: 8,
                      low: 0, high: 8, mid: 0)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s1.mode, .anchorWorst)
        XCTAssertEqual(s1.mid, 7)
        XCTAssertEqual(s1.round, 2)
    }

    // MARK: anchor round 2 — the tier's very worst

    /// Losing to the worst places at the bottom (rank tierCount).
    func testAnchorWorstExistingInsertsAtEnd() {
        let s = state(mode: .anchorWorst, tierCount: 8,
                      low: 1, high: 8, mid: 7, round: 2)
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .done when the worst wins"); return
        }
        XCTAssertEqual(rank, 8)
    }

    /// Beating the worst enters quartile narrowing over [1, tierCount-1]
    /// with the first pivot at the 25% boundary.
    func testAnchorWorstNewEntersQuartileAtTwentyFivePercent() {
        let s = state(mode: .anchorWorst, tierCount: 8,
                      low: 1, high: 8, mid: 7, round: 2)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s1.mode, .quartile)
        XCTAssertEqual(s1.low, 1)
        XCTAssertEqual(s1.high, 7)
        XCTAssertEqual(s1.mid, 2, "1 + floor((7-1) * 0.25) = 2")
        XCTAssertEqual(s1.round, 3)
    }

    /// Full walk: 8-item tier, always existing → rank 8 in exactly two
    /// anchor rounds (lose to best, lose to worst).
    func testAnchorAlwaysExistingLandsAtBottomInTwoRounds() {
        let s = state(mode: .anchorBest, tierCount: 8,
                      low: 0, high: 8, mid: 0)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("round 1: expected .next"); return
        }
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s1, pick: .existing) else {
            XCTFail("round 2: expected .done"); return
        }
        XCTAssertEqual(rank, 8)
    }

    /// Full walk: lose to best, beat worst, then always new → rank 1
    /// (directly below the best).
    func testAnchorMiddleWalkAlwaysNewLandsBelowBest() {
        var s = state(mode: .anchorBest, tierCount: 8,
                      low: 0, high: 8, mid: 0)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .next"); return
        }
        s = s1
        guard case .next(let s2) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .next"); return
        }
        s = s2
        guard case .next(let s3) = RankingAlgorithm.advanceSmallTier(state: s, pick: .new) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s3.mid, 1)
        guard case .done(let rank) = RankingAlgorithm.advanceSmallTier(state: s3, pick: .new) else {
            XCTFail("expected .done"); return
        }
        XCTAssertEqual(rank, 1)
    }

    /// 6-item tier: anchors then quartile pivot at 2 (1 + floor(4*0.25)).
    func testAnchorSixItemTierQuartilePivot() {
        let s = state(mode: .anchorBest, tierCount: 6,
                      low: 0, high: 6, mid: 0)
        guard case .next(let s1) = RankingAlgorithm.advanceSmallTier(state: s, pick: .existing) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s1.mid, 5)
        guard case .next(let s2) = RankingAlgorithm.advanceSmallTier(state: s1, pick: .new) else {
            XCTFail("expected .next"); return
        }
        XCTAssertEqual(s2.mode, .quartile)
        XCTAssertEqual(s2.low, 1)
        XCTAssertEqual(s2.high, 5)
        XCTAssertEqual(s2.mid, 2)
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
