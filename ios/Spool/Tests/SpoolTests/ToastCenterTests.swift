import XCTest
@testable import Spool

@MainActor
final class ToastCenterTests: XCTestCase {

    /// An "instant" sleeper so auto-dismiss resolves without real wall time.
    /// Returning immediately lets us await `show`'s pending dismiss task by
    /// yielding once after the call.
    private let instantSleeper: @Sendable (TimeInterval) async -> Void = { _ in }

    func testShowSetsCurrent() {
        let center = ToastCenter.makeForTesting(sleeper: neverSleeper)
        center.show("hello", level: .info)

        XCTAssertNotNil(center.current)
        XCTAssertEqual(center.current?.text, "hello")
        XCTAssertEqual(center.current?.level, .info)
    }

    func testShowTwiceReplacesLatestWins() {
        let center = ToastCenter.makeForTesting(sleeper: neverSleeper)
        center.show("first", level: .info)
        let firstId = center.current?.id
        XCTAssertNotNil(firstId)

        center.show("second", level: .error)

        XCTAssertEqual(center.current?.text, "second")
        XCTAssertEqual(center.current?.level, .error)
        XCTAssertNotEqual(center.current?.id, firstId, "latest show should replace with a new message id")
    }

    func testDismissClearsCurrent() {
        let center = ToastCenter.makeForTesting(sleeper: neverSleeper)
        center.show("bye", level: .success)
        XCTAssertNotNil(center.current)

        center.dismiss()
        XCTAssertNil(center.current)
    }

    func testAutoDismissClearsCurrentAfterDurationElapses() async {
        let center = ToastCenter.makeForTesting(sleeper: instantSleeper)
        center.show("poof", level: .info, duration: 1)
        XCTAssertNotNil(center.current)

        // Yield until the pending dismiss task finishes. The sleeper returns
        // immediately, so one `Task.yield` cycle is usually enough, but we
        // loop a few times to be resilient to scheduler ordering.
        for _ in 0..<10 {
            if center.current == nil { break }
            await Task.yield()
        }

        XCTAssertNil(center.current, "auto-dismiss should clear current after the sleeper resolves")
    }

    // A sleeper that never returns, so auto-dismiss stays pending forever and
    // tests can observe `show`/`dismiss` state without a race.
    private let neverSleeper: @Sendable (TimeInterval) async -> Void = { _ in
        // Sleep indefinitely; caller is expected to cancel via `pendingDismiss?.cancel()`.
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }
}
