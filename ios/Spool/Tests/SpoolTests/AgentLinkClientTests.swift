import XCTest
import Foundation
@testable import Spool

/// Pure unit spec for the `agent-link` client (P1 M2b): wire-type decode/encode,
/// the `FunctionsError` → typed `AgentLinkError` mapping (every server error body
/// code + the HTTP-status fallback), and the `SMSLink` deep-link composition.
///
/// No network, no Supabase client, no SwiftUI. Mirrors the frozen contract in
/// `supabase/functions/agent-link/index.ts` + `_shared.ts`.
final class AgentLinkClientTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Wire decode

    func testDecodesLinkGrant() throws {
        let json = """
        {
          "assignedPhoneNumber": "+13105551234",
          "code": "AB12CD",
          "expiresAt": "2026-07-11T20:00:00Z",
          "alreadyRegistered": false
        }
        """.data(using: .utf8)!
        let grant = try decoder.decode(LinkGrant.self, from: json)
        XCTAssertEqual(grant.assignedPhoneNumber, "+13105551234")
        XCTAssertEqual(grant.code, "AB12CD")
        XCTAssertEqual(grant.expiresAt, "2026-07-11T20:00:00Z")
        XCTAssertFalse(grant.alreadyRegistered)
    }

    func testDecodesAlreadyRegisteredGrant() throws {
        let json = """
        {"assignedPhoneNumber":"+441234567890","code":"ZZ99YY","expiresAt":"x","alreadyRegistered":true}
        """.data(using: .utf8)!
        let grant = try decoder.decode(LinkGrant.self, from: json)
        XCTAssertTrue(grant.alreadyRegistered)
    }

    func testDecodesStatusResponseWithLinks() throws {
        let json = """
        {"links":[{"phone":"+13105551234","linkedAt":"2026-07-01T12:00:00Z"}]}
        """.data(using: .utf8)!
        let resp = try decoder.decode(AgentLinkStatusResponse.self, from: json)
        XCTAssertEqual(resp.links.count, 1)
        XCTAssertEqual(resp.links[0].phone, "+13105551234")
        XCTAssertEqual(resp.links[0].linkedAt, "2026-07-01T12:00:00Z")
        XCTAssertEqual(resp.links[0].id, "+13105551234", "id is the phone for ForEach identity")
    }

    func testDecodesEmptyStatusResponse() throws {
        let json = "{\"links\":[]}".data(using: .utf8)!
        let resp = try decoder.decode(AgentLinkStatusResponse.self, from: json)
        XCTAssertTrue(resp.links.isEmpty, "empty array = unlinked")
    }

    func testMintRequestEncodesPhone() throws {
        let data = try JSONEncoder().encode(AgentLinkMintRequest(phone: "3105551234"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["phone"] as? String, "3105551234")
    }

    // MARK: - Error-body decode

    func testDecodesErrorCodeFromBody() {
        let data = "{\"error\":\"too_many_codes\"}".data(using: .utf8)!
        XCTAssertEqual(AgentLinkClient.decodeErrorCode(from: data), "too_many_codes")
    }

    func testDecodesNilErrorCodeFromEmptyBody() {
        XCTAssertNil(AgentLinkClient.decodeErrorCode(from: Data()))
    }

    func testDecodesNilErrorCodeFromNonErrorBody() {
        // A 204 or an HTML gateway page → no `{error}` field → nil.
        let data = "<html>gateway timeout</html>".data(using: .utf8)!
        XCTAssertNil(AgentLinkClient.decodeErrorCode(from: data))
    }

    // MARK: - Error mapping: server body code is authoritative

    func testMapsInvalidPhoneBody() {
        XCTAssertEqual(AgentLinkClient.map(status: 400, errorCode: "invalid_phone"), .invalidPhone)
    }

    func testMapsTooManyCodesBody() {
        XCTAssertEqual(AgentLinkClient.map(status: 429, errorCode: "too_many_codes"), .tooManyCodes)
    }

    func testMapsPoolUnavailableBody() {
        XCTAssertEqual(AgentLinkClient.map(status: 503, errorCode: "pool_unavailable"), .poolUnavailable)
    }

    func testMapsSpectrumErrorBody() {
        XCTAssertEqual(AgentLinkClient.map(status: 502, errorCode: "spectrum_error"), .spectrumError)
    }

    func testMapsNotConfiguredBody() {
        XCTAssertEqual(AgentLinkClient.map(status: 500, errorCode: "not_configured"), .notConfigured)
    }

    func testMapsMintFailedBodyToServer500() {
        // 500 mint_failed has no dedicated case → generic server(500).
        XCTAssertEqual(AgentLinkClient.map(status: 500, errorCode: "mint_failed"), .server(status: 500))
    }

    // MARK: - Error mapping: HTTP-status fallback when body has no known code

    func testFallsBackToStatus400WhenNoBodyCode() {
        XCTAssertEqual(AgentLinkClient.map(status: 400, errorCode: nil), .invalidPhone)
    }

    func testFallsBackToStatus429WhenNoBodyCode() {
        XCTAssertEqual(AgentLinkClient.map(status: 429, errorCode: nil), .tooManyCodes)
    }

    func testFallsBackToStatus502WhenNoBodyCode() {
        XCTAssertEqual(AgentLinkClient.map(status: 502, errorCode: nil), .spectrumError)
    }

    func testFallsBackToStatus503WhenNoBodyCode() {
        XCTAssertEqual(AgentLinkClient.map(status: 503, errorCode: nil), .poolUnavailable)
    }

    func testFallsBackTo401AsServer() {
        // 401 has no dedicated typed case → server(401) (the sheet gates on auth
        // separately; a 401 mid-flow is a generic server failure).
        XCTAssertEqual(AgentLinkClient.map(status: 401, errorCode: nil), .server(status: 401))
    }

    func testUnknownBodyCodeFallsBackToStatus() {
        // A server code the client has never seen → ignore it, use the status.
        XCTAssertEqual(AgentLinkClient.map(status: 429, errorCode: "brand_new_code"), .tooManyCodes)
        XCTAssertEqual(AgentLinkClient.map(status: 418, errorCode: "brand_new_code"), .server(status: 418))
    }

    // MARK: - FunctionsError → AgentLinkError (full path incl. body decode)

    func testMapsFunctionsHttpErrorViaBody() {
        let data = "{\"error\":\"pool_unavailable\"}".data(using: .utf8)!
        let mapped = AgentLinkClient.map(.httpError(code: 503, data: data))
        XCTAssertEqual(mapped, .poolUnavailable)
    }

    func testMapsFunctionsHttpErrorViaStatusWhenBodyEmpty() {
        let mapped = AgentLinkClient.map(.httpError(code: 429, data: Data()))
        XCTAssertEqual(mapped, .tooManyCodes)
    }

    func testMapsRelayErrorTo502() {
        XCTAssertEqual(AgentLinkClient.map(.relayError), .server(status: 502))
    }

    // MARK: - SMSLink composition (pure)

    func testComposesSMSStringWithAmpersandBodyForm() {
        // The `&body=` form (george's convention), NOT `?body=`.
        let s = SMSLink.composeString(number: "+13105551234", body: "AB12CD")
        XCTAssertEqual(s, "sms:+13105551234&body=AB12CD")
    }

    func testComposeStringUsesAmpersandNotQuestionMark() {
        let s = SMSLink.composeString(number: "+1", body: "X")
        XCTAssertTrue(s.contains("&body="), "must use the & separator")
        XCTAssertFalse(s.contains("?body="), "must NOT use the ? separator")
    }

    func testComposeURLencodesBodyReservedChars() {
        // A body with `&` and `+` must be percent-encoded so a receiver can't
        // read them as delimiters. (Codes are alnum today; this is defensive.)
        XCTAssertEqual(SMSLink.encode("A&B+C"), "A%26B%2BC")
    }

    func testComposeURLencodesSpace() {
        // Space in a body encodes as %20 (urlQueryAllowed does not include space).
        XCTAssertEqual(SMSLink.encode("A B"), "A%20B")
    }

    func testComposeReturnsValidURL() {
        let url = SMSLink.compose(number: "+13105551234", body: "AB12CD")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "sms")
        XCTAssertEqual(url?.absoluteString, "sms:+13105551234&body=AB12CD")
    }

    func testComposePreservesPlainAlnumCode() {
        // The common case: a 6-char alnum code survives encoding untouched.
        XCTAssertEqual(SMSLink.encode("Q7XM2P"), "Q7XM2P")
    }
}
