import XCTest
@testable import Spool

/// Regression pin for the FeedScreen mode-switch race (Task 5 review fix).
///
/// The bug: `loadNextPage()` guards mode at entry, then suspends inside
/// `assembler.assemblePage(.friends, …)` across the network RPC. If the user
/// taps a different mode while that load is suspended, `assembleFromStart`
/// resets cards/cursor to the new (explore) stream — and then the friends load
/// resumes and APPENDS friends cards onto the explore list (id-dedupe misses
/// them, different ids) and overwrites the cursor with the wrong-stream value.
///
/// The fix is a monotonic `generation` token: reset ops bump it, and each
/// awaiting body re-checks it after resuming, dropping stale-stream results.
/// This test drives exactly that interleave with a gated fake `fetchPage` and
/// asserts the explore list is NOT contaminated and the cursor is explore's.
@MainActor
final class FeedFeedModelTests: XCTestCase {

    private let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let friendActor = UUID(uuidString: "F0000000-0000-0000-0000-0000000000F1")!
    private let exploreActor = UUID(uuidString: "E0000000-0000-0000-0000-0000000000E1")!

    // Stable ids so we can assert exactly which cards landed.
    private let friendA = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
    private let friendB = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000002")!
    private let friendNext = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000003")!
    private let exploreOne = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000001")!

    private func row(id: UUID, actor: UUID, boost: String) -> FeedEventRow {
        FeedEventRow(id: id, actor_id: actor, event_type: "ranking_add",
                     media_tmdb_id: nil, media_title: nil, media_tier: nil,
                     media_poster_url: nil, metadata: nil,
                     created_at: "2026-07-07T12:00:00+00:00", boosted_ts: boost)
    }

    /// One-shot async gate — `wait()` suspends until `open()` is called.
    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume() }
                else { waiters.append(c); lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true
            let pending = waiters; waiters.removeAll(); lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    func testModeSwitchMidPageLoadDoesNotContaminateExploreStream() async {
        let gate = AsyncGate()

        // Fake fetchPage: pageSize 2.
        //  friends + nil cursor  → the initial friends page (2 rows → hasMore).
        //  friends + non-nil     → the SLOW next page: parks on the gate, then
        //                          returns a friends row (this is the stale
        //                          load that must be discarded).
        //  explore (any cursor)  → fast: one explore row.
        let assembler = FeedPageAssembler(
            fetchPage: { mode, cursor, _ in
                switch (mode, cursor) {
                case (.friends, .none):
                    return [self.row(id: self.friendA, actor: self.friendActor, boost: "b1"),
                            self.row(id: self.friendB, actor: self.friendActor, boost: "b2")]
                case (.friends, .some):
                    await gate.wait()   // suspend across the "RPC"
                    return [self.row(id: self.friendNext, actor: self.friendActor, boost: "b3")]
                case (.explore, _):
                    return [self.row(id: self.exploreOne, actor: self.exploreActor, boost: "e1")]
                }
            },
            fetchMutes: { ([], []) },
            fetchProfiles: { _ in [:] },
            fetchScores: { _ in [:] },
            config: FeedAssemblerConfig(pageSize: 2, maxRPCPages: 10)
        )

        let model = FeedFeedModel(assembler: assembler, resolveSession: { self.me })

        // 1. Initial friends page: 2 cards, hasMore true.
        await model.loadInitialIfNeeded()
        XCTAssertEqual(model.mode, .friends)
        XCTAssertEqual(model.cards.map(\.id), [friendA, friendB])
        XCTAssertTrue(model.hasMore)

        // 2. Kick off the friends next-page load; it parks inside the gate.
        let pageLoad = Task { await model.loadNextPage() }
        // Let the load reach its suspension point.
        while !model.loadingMore { await Task.yield() }

        // 3. User switches to explore MID-FLIGHT. This bumps the generation,
        //    cancels the in-flight task, and assembles the explore page.
        await model.switchMode(.explore)
        XCTAssertEqual(model.mode, .explore)
        XCTAssertEqual(model.cards.map(\.id), [exploreOne], "explore page assembled")
        let exploreCursor = model.cursor

        // 4. Release the parked friends load and let it resume.
        gate.open()
        await pageLoad.value

        // 5. The stale friends result must have been DROPPED:
        //    - no friends card appended onto the explore list,
        //    - cursor still points at the explore stream.
        XCTAssertEqual(model.cards.map(\.id), [exploreOne],
                       "friends next-page card must NOT contaminate the explore list")
        XCTAssertFalse(model.cards.contains { $0.id == friendNext })
        XCTAssertEqual(model.cursor, exploreCursor,
                       "cursor must stay on the explore stream, not the friends cursor")
    }
}
