import XCTest
@testable import Spool

/// C7-iOS Task 5 — the pure inbound deep-link router (`ProfileDeepLink.route`).
/// It classifies a URL from BOTH the `spool://` custom scheme and real universal
/// links on `rankspool.com` into `.profile(username:)`, `.authCallback`, or
/// `.unhandled`, with no I/O — so the whole predicate is test-enforced here.
///
/// The matrix covers: both link surfaces resolving the same username, the
/// `www.` variant, `@`-prefix normalisation, the OAuth callback pass-through
/// (byte-for-byte untouched, only recognised), and rejection of every garbage
/// / wrong-host / wrong-path / deeper-path class.
final class ProfileDeepLinkTests: XCTestCase {

    private func route(_ string: String) -> ProfileDeepLink.Route {
        guard let url = URL(string: string) else {
            return XCTFail("bad test URL: \(string)") as? ProfileDeepLink.Route ?? .unhandled
        }
        return ProfileDeepLink.route(for: url)
    }

    // MARK: - Custom scheme: spool://u/{username}

    func testCustomSchemeProfileResolvesUsername() {
        XCTAssertEqual(route("spool://u/bobby"), .profile(username: "bobby"))
    }

    func testCustomSchemeProfileStripsLeadingAt() {
        XCTAssertEqual(route("spool://u/@bobby"), .profile(username: "bobby"))
    }

    func testCustomSchemePercentDecodesUsername() {
        // %40 → '@', then normalised away, leaving the bare handle.
        XCTAssertEqual(route("spool://u/%40bobby"), .profile(username: "bobby"))
    }

    func testCustomSchemeDoesNotDoubleDecodePercent() {
        // %2540 is a literal percent-encoded '%40' (i.e. the two-char sequence
        // "%40" in the username, NOT an '@'). URLComponents.path is already
        // percent-decoded once by the system, so %25 → '%' and %40 stays as
        // "%40" — the username becomes "%40bobby", NOT "@bobby" (which double-
        // decoding would produce). Stripping the leading '@' rule does not fire
        // here because the leading character is '%', so the result must NOT be
        // `.profile(username: "bobby")`.
        let result = route("spool://u/%2540bobby")
        XCTAssertNotEqual(result, .profile(username: "bobby"),
            "double-percent-decode bug: %2540 must not collapse to 'bobby' (via @bobby)")
        // It should resolve to a profile with the literal %40 in the name.
        XCTAssertEqual(result, .profile(username: "%40bobby"))
    }

    func testUniversalLinkDoesNotDoubleDecodePercent() {
        // Same invariant for the universal-link surface.
        let result = route("https://rankspool.com/u/%2540bobby")
        XCTAssertNotEqual(result, .profile(username: "bobby"),
            "double-percent-decode bug: %2540 must not collapse to 'bobby' (via @bobby)")
        XCTAssertEqual(result, .profile(username: "%40bobby"))
    }

    func testCustomSchemeBareProfilePathIsUnhandled() {
        XCTAssertEqual(route("spool://u/"), .unhandled)
        XCTAssertEqual(route("spool://u"), .unhandled)
    }

    func testCustomSchemeDeeperProfilePathIsUnhandled() {
        XCTAssertEqual(route("spool://u/bobby/extra"), .unhandled)
    }

    func testCustomSchemeLoneAtIsUnhandled() {
        // "@" alone normalises to empty → not a profile.
        XCTAssertEqual(route("spool://u/@"), .unhandled)
    }

    func testCustomSchemeOtherHostIsUnhandled() {
        XCTAssertEqual(route("spool://settings/theme"), .unhandled)
    }

    // MARK: - OAuth callback pass-through (must NOT be treated as a profile)

    func testAuthCallbackIsRecognisedNotHandledAsProfile() {
        XCTAssertEqual(route("spool://auth-callback"), .authCallback)
    }

    func testAuthCallbackWithQueryStillClassifiesAsAuthCallback() {
        // Supabase appends tokens as a fragment/query — still the auth route.
        XCTAssertEqual(
            route("spool://auth-callback#access_token=abc&refresh_token=def"),
            .authCallback
        )
    }

    // MARK: - Universal link: https://rankspool.com/u/{username}

    func testUniversalLinkProfileResolvesUsername() {
        XCTAssertEqual(route("https://rankspool.com/u/bobby"), .profile(username: "bobby"))
    }

    func testUniversalLinkWwwVariantResolvesUsername() {
        XCTAssertEqual(route("https://www.rankspool.com/u/bobby"), .profile(username: "bobby"))
    }

    func testUniversalLinkStripsLeadingAt() {
        XCTAssertEqual(route("https://rankspool.com/u/@bobby"), .profile(username: "bobby"))
    }

    func testUniversalLinkHostIsCaseInsensitive() {
        XCTAssertEqual(route("https://RankSpool.com/u/bobby"), .profile(username: "bobby"))
    }

    func testUniversalLinkTrailingSlashUsernameStillResolves() {
        XCTAssertEqual(route("https://rankspool.com/u/bobby/"), .profile(username: "bobby"))
    }

    func testUniversalLinkBareProfilePathIsUnhandled() {
        XCTAssertEqual(route("https://rankspool.com/u/"), .unhandled)
        XCTAssertEqual(route("https://rankspool.com/u"), .unhandled)
    }

    func testUniversalLinkDeeperPathIsUnhandled() {
        XCTAssertEqual(route("https://rankspool.com/u/bobby/extra"), .unhandled)
    }

    func testUniversalLinkNonProfilePathIsUnhandled() {
        XCTAssertEqual(route("https://rankspool.com/about"), .unhandled)
        XCTAssertEqual(route("https://rankspool.com/"), .unhandled)
    }

    func testUniversalLinkForeignHostIsUnhandled() {
        XCTAssertEqual(route("https://evil.com/u/bobby"), .unhandled)
        XCTAssertEqual(route("https://rankspool.com.evil.com/u/bobby"), .unhandled)
    }

    func testHttpSchemeIsUnhandled() {
        // Only https is claimed as a universal link (AASA/entitlement are https).
        XCTAssertEqual(route("http://rankspool.com/u/bobby"), .unhandled)
    }

    // MARK: - Garbage

    func testUnknownSchemeIsUnhandled() {
        XCTAssertEqual(route("mailto:bobby@rankspool.com"), .unhandled)
        XCTAssertEqual(route("ftp://rankspool.com/u/bobby"), .unhandled)
    }
}
