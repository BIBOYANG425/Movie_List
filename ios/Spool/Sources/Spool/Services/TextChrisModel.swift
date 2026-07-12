import Foundation

/// View-model seam for the Settings "text Chris" sheet (P1 M2b).
///
/// Owns the linking state machine and the SMS-deeplink composition as PURE,
/// injectable logic so both are unit-tested without SwiftUI, a live Supabase
/// client, or the network. `TextChrisSheet` binds to an instance and drives it;
/// the sheet holds ZERO business logic beyond rendering `state`.
///
/// State machine:
///   idle ──mint()──▶ minting ──success──▶ issued(grant)
///                              └─failure──▶ idle (+ error surfaced to onError)
///   linked(links) ──unlink()──▶ unlinking ──success──▶ idle
///                                          └─failure──▶ linked (+ onError)
///   (on appear) load() reads status: non-empty → linked, empty → idle
///
/// The client calls are injected as closures (`mintFn` / `statusFn` / `unlinkFn`)
/// so tests drive every transition and error mapping with stubs. Production wires
/// them to `AgentLinkClient`. `onError` is the toast seam — the model reports a
/// typed error and the sheet maps it to copy; the model never owns UI strings.
///
/// Header last reviewed: 2026-07-11
@MainActor
public final class TextChrisModel: ObservableObject {

    /// The rendered state of the sheet. `Equatable` so tests assert transitions
    /// directly and SwiftUI can diff cheaply.
    public enum State: Equatable {
        /// No link yet — show the phone input + CTA.
        case idle
        /// A mint round-trip is in flight — show the spinner.
        case minting
        /// A code was issued — show the big code + "open messages".
        case issued(LinkGrant)
        /// The user already has links — show the linked row + unlink.
        case linked([AgentLink])
        /// An unlink round-trip is in flight.
        case unlinking([AgentLink])
    }

    @Published public private(set) var state: State = .idle

    /// The phone the user is typing (bound to the input field). Kept on the model
    /// so the sheet's `TextField` has a single source of truth and `mint()` reads
    /// it without a parameter.
    @Published public var phoneInput: String = ""

    private let mintFn: (String) async throws -> LinkGrant
    private let statusFn: () async -> [AgentLink]
    private let unlinkFn: () async throws -> Void
    private let onError: (AgentLinkClient.AgentLinkError) -> Void

    /// Designated init with injected client closures. Production callers use the
    /// `live` factory; tests pass stubs.
    public init(
        mintFn: @escaping (String) async throws -> LinkGrant,
        statusFn: @escaping () async -> [AgentLink],
        unlinkFn: @escaping () async throws -> Void,
        onError: @escaping (AgentLinkClient.AgentLinkError) -> Void
    ) {
        self.mintFn = mintFn
        self.statusFn = statusFn
        self.unlinkFn = unlinkFn
        self.onError = onError
    }

    /// Production wiring: the closures call `AgentLinkClient`; `onError` toasts.
    @MainActor
    public static func live(onError: @escaping (AgentLinkClient.AgentLinkError) -> Void) -> TextChrisModel {
        TextChrisModel(
            mintFn: { try await AgentLinkClient.mint(phone: $0) },
            statusFn: { await AgentLinkClient.status() },
            unlinkFn: { try await AgentLinkClient.unlink() },
            onError: onError
        )
    }

    // MARK: - Transitions

    /// Read link status on appear and route to `.linked` or `.idle`. A no-op if a
    /// mint/unlink is already in flight (so a slow status read can't clobber a
    /// user action that raced it).
    public func load() async {
        switch state {
        case .minting, .unlinking, .issued:
            return
        case .idle, .linked:
            let links = await statusFn()
            state = links.isEmpty ? .idle : .linked(links)
        }
    }

    /// Mint a code for `phoneInput`. Guards on non-empty input and a settled
    /// state. On success → `.issued`; on failure → back to `.idle` and the error
    /// is reported via `onError`.
    public func mint() async {
        guard case .idle = state else { return }
        let phone = phoneInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return }
        state = .minting
        do {
            let grant = try await mintFn(phone)
            state = .issued(grant)
        } catch let error as AgentLinkClient.AgentLinkError {
            state = .idle
            onError(error)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .idle
            onError(.network)
        }
    }

    /// Unlink the current link(s). Only valid from `.linked`. On success → `.idle`;
    /// on failure → back to `.linked` with the same links and the error reported.
    public func unlink() async {
        guard case let .linked(links) = state else { return }
        state = .unlinking(links)
        do {
            try await unlinkFn()
            state = .idle
        } catch let error as AgentLinkClient.AgentLinkError {
            state = .linked(links)
            onError(error)
        } catch is CancellationError {
            state = .linked(links)
        } catch {
            state = .linked(links)
            onError(.network)
        }
    }

    /// Return to the input state after the user dismisses an issued code without
    /// linking (e.g. taps "done"). From `.issued` only.
    public func reset() {
        if case .issued = state { state = .idle }
    }
}

// MARK: - SMS deep-link composition (pure)

/// Pure composition of the `sms:` deep link the "open messages" button opens.
///
/// iOS parses `sms:` bodies inconsistently across versions: some accept `?body=`,
/// others only `&body=` or `;body=`. george (Bobby's proven iMessage code) uses
/// the `sms:NUMBER&body=` form, so we match it. The body (the 6-char code) is
/// percent-encoded for URL query safety. Kept pure + `internal` so the encoding
/// and the `&` separator are unit-tested with no `UIApplication`.
enum SMSLink {
    /// Build `sms:<number>&body=<url-encoded-code>` as a `URL`, or nil if the
    /// composed string somehow fails to parse (defensive — a valid number + a
    /// 6-char alnum code always parses).
    static func compose(number: String, body: String) -> URL? {
        URL(string: composeString(number: number, body: body))
    }

    /// The raw `sms:` string, exposed for unit tests to assert the exact shape
    /// (the `&body=` separator + the percent-encoding) without a `URL` round-trip
    /// normalising it away.
    static func composeString(number: String, body: String) -> String {
        "sms:\(number)&body=\(encode(body))"
    }

    /// Percent-encode a message body for the `sms:` query. `.urlQueryAllowed`
    /// minus `&` and `+` (which a receiver could read as a query delimiter / a
    /// space), so a code containing them survives round-trip. The 6-char link
    /// codes are alnum today; this stays correct if that ever changes.
    static func encode(_ body: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+")
        return body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
    }
}
