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

    private func mkTier(_ tier: Tier, _ count: Int) -> [RankedItem] {
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
