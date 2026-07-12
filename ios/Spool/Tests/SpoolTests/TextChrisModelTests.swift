import XCTest
@testable import Spool

/// State-machine spec for `TextChrisModel` (P1 M2b) — the "text Chris" sheet's
/// pure view-model seam. Every transition (idle → minting → issued, linked →
/// unlinking → idle) and every error mapping is driven with injected stub
/// closures. No SwiftUI, no Supabase, no network.
@MainActor
final class TextChrisModelTests: XCTestCase {

    private let grant = LinkGrant(
        assignedPhoneNumber: "+13105551234", code: "AB12CD",
        expiresAt: "2026-07-11T20:00:00Z", alreadyRegistered: false
    )
    private let link = AgentLink(phone: "+13105551234", linkedAt: "2026-07-01T12:00:00Z")

    /// Build a model with per-closure overrides; unset closures default to
    /// benign no-ops. `errors` collects everything routed to `onError`.
    private func makeModel(
        mint: @escaping (String) async throws -> LinkGrant = { _ in
            LinkGrant(assignedPhoneNumber: "", code: "", expiresAt: "", alreadyRegistered: false)
        },
        status: @escaping () async -> [AgentLink] = { [] },
        unlink: @escaping () async throws -> Void = {},
        errors: ErrorSink
    ) -> TextChrisModel {
        TextChrisModel(mintFn: mint, statusFn: status, unlinkFn: unlink, onError: { errors.record($0) })
    }

    /// A tiny reference sink so the escaping `onError` closure can append without
    /// capturing a `var` (which `@Sendable`/escaping rules disallow cleanly).
    final class ErrorSink { var all: [AgentLinkClient.AgentLinkError] = []; func record(_ e: AgentLinkClient.AgentLinkError) { all.append(e) } }

    // MARK: - Initial state

    func testStartsIdle() {
        let sink = ErrorSink()
        let m = makeModel(errors: sink)
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - load()

    func testLoadEmptyStatusStaysIdle() async {
        let sink = ErrorSink()
        let m = makeModel(status: { [] }, errors: sink)
        await m.load()
        XCTAssertEqual(m.state, .idle)
    }

    func testLoadNonEmptyStatusGoesLinked() async {
        let sink = ErrorSink()
        let m = makeModel(status: { [self.link] }, errors: sink)
        await m.load()
        XCTAssertEqual(m.state, .linked([link]))
    }

    func testLoadDoesNotClobberIssuedState() async {
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in self.grant }, status: { [self.link] }, errors: sink)
        m.phoneInput = "3105551234"
        await m.mint()
        XCTAssertEqual(m.state, .issued(grant))
        // A late status read must NOT overwrite the freshly-issued code.
        await m.load()
        XCTAssertEqual(m.state, .issued(grant))
    }

    // MARK: - mint()

    func testMintSuccessGoesIssued() async {
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in self.grant }, errors: sink)
        m.phoneInput = "3105551234"
        await m.mint()
        XCTAssertEqual(m.state, .issued(grant))
        XCTAssertTrue(sink.all.isEmpty)
    }

    func testMintTrimsPhoneWhitespace() async {
        let sink = ErrorSink()
        var received = ""
        let m = makeModel(mint: { phone in received = phone; return self.grant }, errors: sink)
        m.phoneInput = "  3105551234  "
        await m.mint()
        XCTAssertEqual(received, "3105551234", "phone is trimmed before mint")
    }

    func testMintEmptyPhoneIsNoOp() async {
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in XCTFail("must not call mint on empty input"); return self.grant }, errors: sink)
        m.phoneInput = "   "
        await m.mint()
        XCTAssertEqual(m.state, .idle)
    }

    func testMintOnlyRunsFromIdle() async {
        let sink = ErrorSink()
        let m = makeModel(status: { [self.link] }, errors: sink)
        await m.load()  // → linked
        m.phoneInput = "3105551234"
        await m.mint()  // guarded: not idle
        XCTAssertEqual(m.state, .linked([link]), "mint is a no-op outside idle")
    }

    // MARK: - mint() error mapping (each typed error → idle + onError)

    private func assertMintError(_ thrown: AgentLinkClient.AgentLinkError) async {
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in throw thrown }, errors: sink)
        m.phoneInput = "3105551234"
        await m.mint()
        XCTAssertEqual(m.state, .idle, "a failed mint returns to idle")
        XCTAssertEqual(sink.all, [thrown], "the typed error is reported once")
    }

    func testMintInvalidPhoneErrorReturnsIdle() async { await assertMintError(.invalidPhone) }
    func testMintTooManyCodesErrorReturnsIdle() async { await assertMintError(.tooManyCodes) }
    func testMintPoolUnavailableErrorReturnsIdle() async { await assertMintError(.poolUnavailable) }
    func testMintSpectrumErrorReturnsIdle() async { await assertMintError(.spectrumError) }
    func testMintNotConfiguredErrorReturnsIdle() async { await assertMintError(.notConfigured) }
    func testMintNotAuthenticatedErrorReturnsIdle() async { await assertMintError(.notAuthenticated) }
    func testMintNetworkErrorReturnsIdle() async { await assertMintError(.network) }
    func testMintServerErrorReturnsIdle() async { await assertMintError(.server(status: 500)) }

    func testMintUnknownErrorMapsToNetwork() async {
        struct Weird: Error {}
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in throw Weird() }, errors: sink)
        m.phoneInput = "3105551234"
        await m.mint()
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(sink.all, [.network], "a non-typed throw surfaces as .network")
    }

    // MARK: - unlink()

    func testUnlinkSuccessGoesIdle() async {
        let sink = ErrorSink()
        let m = makeModel(status: { [self.link] }, unlink: {}, errors: sink)
        await m.load()  // → linked
        await m.unlink()
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(sink.all.isEmpty)
    }

    func testUnlinkFailureReturnsToLinked() async {
        let sink = ErrorSink()
        let m = makeModel(status: { [self.link] }, unlink: { throw AgentLinkClient.AgentLinkError.network }, errors: sink)
        await m.load()  // → linked
        await m.unlink()
        XCTAssertEqual(m.state, .linked([link]), "a failed unlink keeps the linked row")
        XCTAssertEqual(sink.all, [.network])
    }

    func testUnlinkOnlyRunsFromLinked() async {
        let sink = ErrorSink()
        let m = makeModel(unlink: { XCTFail("must not unlink from idle"); }, errors: sink)
        await m.unlink()  // state is idle
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - reset()

    func testResetFromIssuedGoesIdle() async {
        let sink = ErrorSink()
        let m = makeModel(mint: { _ in self.grant }, errors: sink)
        m.phoneInput = "3105551234"
        await m.mint()
        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    func testResetIsNoOpFromIdle() {
        let sink = ErrorSink()
        let m = makeModel(errors: sink)
        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - since-date label

    func testSinceLabelFormatsISO() {
        XCTAssertEqual(TextChrisSheet.sinceLabel("2026-07-01T12:00:00Z"), "jul 1, 2026")
    }

    func testSinceLabelFormatsFractionalISO() {
        XCTAssertEqual(TextChrisSheet.sinceLabel("2026-07-01T12:00:00.123456Z"), "jul 1, 2026")
    }

    func testSinceLabelFallsBackToRawOnGarbage() {
        XCTAssertEqual(TextChrisSheet.sinceLabel("not-a-date"), "not-a-date")
    }
}
