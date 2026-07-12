import Foundation
import Supabase

/// Client for the `agent-link` edge function (P1 M2b) — the iOS half of the
/// iMessage-companion (Chris) linking handshake.
///
/// Chris is Spool's iMessage friend. On Photon's shared pool there is no static
/// agent number: `agent-link` registers the user's phone as a Photon shared user
/// and returns THAT phone's personal `assignedPhoneNumber` plus a 6-char link
/// code. The Settings "text Chris" sheet (`TextChrisSheet`) drives this client.
///
/// One endpoint, three methods (mirrors `supabase/functions/agent-link/index.ts`):
///   POST   {phone} → 200 {assignedPhoneNumber, code, expiresAt, alreadyRegistered}
///          errors 400 invalid_phone / 401 / 429 too_many_codes /
///          500 not_configured|mint_failed / 502 spectrum_error / 503 pool_unavailable
///   GET    → 200 {links: [{phone, linkedAt}]}  (empty array = unlinked)
///   DELETE → 204 (unlink)
///
/// Auth: `functions.invoke` auto-attaches the session JWT (Bearer) + anon apikey
/// via the client's auth-state listener, exactly as `SuggestionsClient` does. A
/// signed-out caller has no session, so we short-circuit BEFORE the network with
/// `AgentLinkError.notAuthenticated` rather than send the bare anon key (which the
/// function would 401 anyway).
///
/// Error posture: the function returns a JSON `{error: "<code>"}` body on non-2xx.
/// `functions.invoke` surfaces that as `FunctionsError.httpError(code, data)`; we
/// decode the `error` string from `data` and map it to a typed `AgentLinkError`
/// case so the sheet can show distinct copy for `too_many_codes` /
/// `pool_unavailable` vs a generic failure. Transport / connectivity failures
/// surface as `.network`. Cancellation propagates (never swallowed).
///
/// Header last reviewed: 2026-07-11
public enum AgentLinkClient {

    /// Typed error surface for the sheet. The raw server `{error}` codes collapse
    /// into the cases the UI actually branches on; everything unrecognised is
    /// `.server(status:)` so a new server code never crashes an old client.
    public enum AgentLinkError: Error, Equatable {
        /// No client configured (missing SUPABASE_URL / anon key).
        case notConfigured
        /// No signed-in session — the sheet must gate on auth before minting.
        case notAuthenticated
        /// 400 invalid_phone — the typed number could not be normalised to E.164.
        case invalidPhone
        /// 429 too_many_codes — the per-user live-code cap was hit.
        case tooManyCodes
        /// 503 pool_unavailable — Photon's shared number pool is exhausted.
        case poolUnavailable
        /// 502 spectrum_error — Photon (Spectrum) upstream failed.
        case spectrumError
        /// A non-2xx status the client doesn't special-case (401, 500 mint_failed,
        /// unknown codes). `status` is the HTTP code for diagnostics.
        case server(status: Int)
        /// Transport-level failure (offline, DNS, timeout, TLS).
        case network
    }

    // MARK: - Mint (POST)

    /// Register `phone` and mint a link code. Returns the grant the sheet shows
    /// (the number to text + the 6-char code + expiry).
    ///
    /// - Throws: `.notConfigured` / `.notAuthenticated` before any network call;
    ///   `.invalidPhone` / `.tooManyCodes` / `.poolUnavailable` / `.spectrumError`
    ///   / `.server(status:)` on the mapped non-2xx bodies; `.network` on a
    ///   transport failure; `CancellationError` if the task is cancelled.
    public static func mint(phone: String) async throws -> LinkGrant {
        let client = try requireClient()
        try await requireSession(client)
        do {
            let grant: LinkGrant = try await client.functions.invoke(
                "agent-link",
                options: FunctionInvokeOptions(method: .post, body: AgentLinkMintRequest(phone: phone))
            )
            return grant
        } catch let error as FunctionsError {
            throw map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[AgentLinkClient] mint: transport error (\(error))")
            throw AgentLinkError.network
        }
    }

    // MARK: - Status (GET)

    /// Read the caller's current links. Never throws: any failure (no session,
    /// network, non-2xx) resolves to an empty array so the sheet falls back to
    /// its unlinked state rather than stranding the user on an error. The sheet
    /// gates minting on its own auth check, so a soft-empty status here is safe.
    public static func status() async -> [AgentLink] {
        guard let client = SpoolClient.shared else {
            NSLog("[AgentLinkClient] status: no client (not configured)")
            return []
        }
        guard (try? await client.auth.session) != nil else {
            NSLog("[AgentLinkClient] status: no session")
            return []
        }
        do {
            let response: AgentLinkStatusResponse = try await client.functions.invoke(
                "agent-link",
                options: FunctionInvokeOptions(method: .get)
            )
            return response.links
        } catch {
            NSLog("[AgentLinkClient] status: failed (\(error))")
            return []
        }
    }

    // MARK: - Unlink (DELETE)

    /// Unlink the caller's phone (DELETE → 204). Throws the same typed errors as
    /// `mint` so the sheet can toast a failure and keep the linked row.
    public static func unlink() async throws {
        let client = try requireClient()
        try await requireSession(client)
        do {
            // No decodable body on 204 — use the no-response invoke overload.
            try await client.functions.invoke(
                "agent-link",
                options: FunctionInvokeOptions(method: .delete)
            )
        } catch let error as FunctionsError {
            throw map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[AgentLinkClient] unlink: transport error (\(error))")
            throw AgentLinkError.network
        }
    }

    // MARK: - Internals

    private static func requireClient() throws -> SupabaseClient {
        guard let client = SpoolClient.shared else {
            NSLog("[AgentLinkClient] no client (not configured)")
            throw AgentLinkError.notConfigured
        }
        return client
    }

    private static func requireSession(_ client: SupabaseClient) async throws {
        guard (try? await client.auth.session) != nil else {
            NSLog("[AgentLinkClient] no session (not authenticated)")
            throw AgentLinkError.notAuthenticated
        }
    }

    /// Map a `FunctionsError` (the SDK's non-2xx / relay surface) to the typed
    /// `AgentLinkError`. For `.httpError` we decode the server `{error}` code from
    /// the body FIRST (authoritative), falling back to the HTTP status when the
    /// body is absent or unrecognised. Extracted (`map(status:errorCode:)` does
    /// the pure decision) so the mapping is unit-tested with no network.
    static func map(_ error: FunctionsError) -> AgentLinkError {
        switch error {
        case let .httpError(code, data):
            let serverCode = decodeErrorCode(from: data)
            return map(status: code, errorCode: serverCode)
        case .relayError:
            return .server(status: 502)
        }
    }

    /// Decode the `{error: "<code>"}` field from a non-2xx body, or nil when the
    /// body is empty / not that shape (204, HTML gateway error, etc.).
    static func decodeErrorCode(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(AgentLinkErrorBody.self, from: data))?.error
    }

    /// Pure status + server-code → typed error decision. The server `error` code
    /// is authoritative (it disambiguates 500 not_configured vs mint_failed, and
    /// names 429/502/503 precisely); the HTTP status is the fallback when the
    /// body carried no recognised code.
    static func map(status: Int, errorCode: String?) -> AgentLinkError {
        switch errorCode {
        case "invalid_phone":     return .invalidPhone
        case "too_many_codes":    return .tooManyCodes
        case "pool_unavailable":  return .poolUnavailable
        case "spectrum_error":    return .spectrumError
        case "not_configured":    return .notConfigured
        default:
            break
        }
        // No recognised body code — fall back to the HTTP status.
        switch status {
        case 400: return .invalidPhone
        case 429: return .tooManyCodes
        case 502: return .spectrumError
        case 503: return .poolUnavailable
        default:  return .server(status: status)
        }
    }
}

// MARK: - Wire types

/// POST request body for `agent-link` (`{phone}`).
public struct AgentLinkMintRequest: Codable, Sendable {
    public let phone: String
    public init(phone: String) { self.phone = phone }
}

/// The 200 POST body: the number to text + the minted code + its expiry.
/// Field names match the frozen `buildLinkResponse` contract exactly.
public struct LinkGrant: Codable, Sendable, Equatable {
    /// The Photon pool number the user texts (the `sms:` recipient).
    public let assignedPhoneNumber: String
    /// The 6-char link code the user sends as the first message body.
    public let code: String
    /// ISO-8601 expiry timestamp for the code (server-authored).
    public let expiresAt: String
    /// True when the phone was already registered (reused its assignment).
    public let alreadyRegistered: Bool

    public init(assignedPhoneNumber: String, code: String, expiresAt: String, alreadyRegistered: Bool) {
        self.assignedPhoneNumber = assignedPhoneNumber
        self.code = code
        self.expiresAt = expiresAt
        self.alreadyRegistered = alreadyRegistered
    }
}

/// One linked phone from GET (`{phone, linkedAt}`).
public struct AgentLink: Codable, Sendable, Equatable, Identifiable {
    public let phone: String
    /// ISO-8601 timestamp the link was established (server-authored).
    public let linkedAt: String

    /// Stable identity for `ForEach` — the phone is unique per user link row.
    public var id: String { phone }

    public init(phone: String, linkedAt: String) {
        self.phone = phone
        self.linkedAt = linkedAt
    }
}

/// GET response envelope (`{links: [...]}`).
public struct AgentLinkStatusResponse: Codable, Sendable {
    public let links: [AgentLink]
    public init(links: [AgentLink]) { self.links = links }
}

/// Non-2xx error body shape (`{error: "<code>"}`).
struct AgentLinkErrorBody: Codable {
    let error: String
}
