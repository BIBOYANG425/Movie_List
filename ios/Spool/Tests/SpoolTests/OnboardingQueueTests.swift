import XCTest
@testable import Spool

@MainActor
final class OnboardingQueueTests: XCTestCase {

    /// Use an isolated UserDefaults suite so tests don't collide with the
    /// user's real defaults and we can reset cleanly between cases.
    private let suiteName = "spool.onboarding_queue.tests"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defs = UserDefaults(suiteName: suiteName)!
        testDefaults = defs
        OnboardingQueue.defaults = defs
    }

    override func tearDown() {
        OnboardingQueue.defaults = .standard
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Codable

    func testQueuedRankingCodableRoundTrip() throws {
        let original = QueuedRanking(
            tmdbId: "12345",
            title: "Past Lives",
            year: "2023",
            posterURL: "https://image.tmdb.org/t/p/w500/abc.jpg",
            genres: ["Drama", "Romance"],
            director: nil,
            tier: "S",
            rankPosition: 1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueuedRanking.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.tmdbId, "12345")
        XCTAssertEqual(decoded.title, "Past Lives")
        XCTAssertEqual(decoded.year, "2023")
        XCTAssertEqual(decoded.genres, ["Drama", "Romance"])
        XCTAssertNil(decoded.director)
        XCTAssertEqual(decoded.tier, "S")
        XCTAssertEqual(decoded.rankPosition, 1)
    }

    func testQueuedRankingCodableWithNilOptionals() throws {
        let original = QueuedRanking(
            tmdbId: "9",
            title: "Unknown",
            year: nil,
            posterURL: nil,
            genres: [],
            director: nil,
            tier: "D",
            rankPosition: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueuedRanking.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - replace / pending / clear

    func testPendingStartsEmpty() {
        XCTAssertTrue(OnboardingQueue.pending.isEmpty)
    }

    func testEnqueueReflectsInPending() {
        let rows = [
            makeRow(tmdbId: "1", tier: "S", rank: 1),
            makeRow(tmdbId: "2", tier: "S", rank: 2),
            makeRow(tmdbId: "3", tier: "A", rank: 1),
        ]
        OnboardingQueue.replace(rows)
        XCTAssertEqual(OnboardingQueue.pending, rows)
    }

    func testEnqueueReplacesPriorQueue() {
        OnboardingQueue.replace([makeRow(tmdbId: "old", tier: "B", rank: 1)])
        let newRows = [makeRow(tmdbId: "new", tier: "S", rank: 1)]
        OnboardingQueue.replace(newRows)
        XCTAssertEqual(OnboardingQueue.pending, newRows)
        XCTAssertEqual(OnboardingQueue.pending.first?.tmdbId, "new")
    }

    func testClearEmptiesTheQueue() {
        OnboardingQueue.replace([makeRow(tmdbId: "1", tier: "S", rank: 1)])
        XCTAssertFalse(OnboardingQueue.pending.isEmpty)
        OnboardingQueue.clear()
        XCTAssertTrue(OnboardingQueue.pending.isEmpty)
    }

    func testClearOnEmptyQueueIsNoop() {
        XCTAssertNoThrow(OnboardingQueue.clear())
        XCTAssertTrue(OnboardingQueue.pending.isEmpty)
    }

    // MARK: - append

    func testAppendOnEmptyQueueAddsSingleRow() {
        let row = makeRow(tmdbId: "42", tier: "S", rank: 1)
        OnboardingQueue.append(row)
        XCTAssertEqual(OnboardingQueue.pending, [row])
    }

    func testAppendPreservesExistingRows() {
        let first = makeRow(tmdbId: "1", tier: "S", rank: 1)
        let second = makeRow(tmdbId: "2", tier: "A", rank: 1)
        OnboardingQueue.replace([first, second])

        let third = makeRow(tmdbId: "3", tier: "B", rank: 1)
        OnboardingQueue.append(third)

        // Original two rows stay put, new row lands at the tail.
        XCTAssertEqual(OnboardingQueue.pending, [first, second, third])
    }

    func testAppendMultipleTimesAccumulates() {
        let a = makeRow(tmdbId: "a", tier: "S", rank: 1)
        let b = makeRow(tmdbId: "b", tier: "S", rank: 2)
        OnboardingQueue.append(a)
        OnboardingQueue.append(b)

        XCTAssertEqual(OnboardingQueue.pending.count, 2)
        XCTAssertEqual(OnboardingQueue.pending, [a, b])
    }

    // MARK: - flush

    func testFlushWithEmptyQueueIsNoop() async {
        // No queue, no session — should not throw because we never hit the
        // session check when there's nothing to flush.
        do {
            try await OnboardingQueue.flush()
        } catch {
            XCTFail("flush on empty queue should not throw, got \(error)")
        }
    }

    func testFlushThrowsWhenNoSession() async {
        // With the test UserDefaults holding a row, flush must reach the
        // session check. In the test environment `SpoolClient.shared` is nil
        // (no Info.plist keys), so we expect `.notConfigured`. If credentials
        // were present but no session existed it would throw `.notAuthenticated`.
        OnboardingQueue.replace([makeRow(tmdbId: "1", tier: "S", rank: 1)])

        do {
            try await OnboardingQueue.flush()
            XCTFail("flush should have thrown")
        } catch OnboardingQueue.QueueError.notConfigured {
            // Expected when Supabase Info.plist keys aren't set in tests.
        } catch OnboardingQueue.QueueError.notAuthenticated {
            // Also acceptable — happens if the test host has SUPABASE_URL
            // configured but no signed-in session.
        } catch {
            XCTFail("flush threw unexpected error: \(error)")
        }

        // Queue must be preserved on a failed flush so the next sign-in can retry.
        XCTAssertFalse(OnboardingQueue.pending.isEmpty)
    }

    // MARK: - helpers

    private func makeRow(tmdbId: String, tier: String, rank: Int) -> QueuedRanking {
        QueuedRanking(
            tmdbId: tmdbId,
            title: "t-\(tmdbId)",
            year: "2024",
            posterURL: nil,
            genres: ["Drama"],
            director: nil,
            tier: tier,
            rankPosition: rank
        )
    }
}
