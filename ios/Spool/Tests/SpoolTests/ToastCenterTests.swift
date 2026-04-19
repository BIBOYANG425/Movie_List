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

        // Deterministic wait via the test hook on ToastCenter — awaits the
        // pending dismiss Task directly instead of yield-looping.
        await center.waitForPendingDismiss()

        XCTAssertNil(center.current, "auto-dismiss should clear current after the sleeper resolves")
    }

    // A sleeper that awaits cancellation rather than burning a fixed-duration
    // timer. Cooperates with `Task.isCancelled` in `show`'s dismiss Task so a
    // follow-up `show`/`dismiss` call returns this immediately — no 60-second
    // leaked sleep hanging around after the test exits.
    private let neverSleeper: @Sendable (TimeInterval) async -> Void = { _ in
        try? await Task.sleep(nanoseconds: .max)
    }
}
