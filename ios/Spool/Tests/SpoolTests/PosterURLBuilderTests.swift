import XCTest
@testable import Spool

/// Spec for `TMDBService.posterURL(from:)` — the one poster-value normalizer the
/// profile/friend-profile poster cards call before handing a URL to `PosterBlock`.
///
/// The DB stores FULL `https://image.tmdb.org/...` URLs (every web write path
/// builds `${TMDB_IMAGE_BASE}${poster_path}` before persisting), so the common
/// case is passthrough. The helper mirrors web's defensive `extractPalette`
/// guard (`services/stubService.ts`: `startsWith('http') ? url : base + url`) so
/// a legacy or partially-migrated bare-path row still resolves, and a poster-less
/// row yields nil (→ synthetic `PosterBlock` art rather than a broken image).
final class PosterURLBuilderTests: XCTestCase {

    func testFullHTTPSURLPassesThrough() {
        let full = "https://image.tmdb.org/t/p/w500/3bhkrj58Vtu7enYsRolD1fZdja1.jpg"
        XCTAssertEqual(TMDBService.posterURL(from: full), full)
    }

    func testFullHTTPURLPassesThrough() {
        // http (not https) is still absolute — must not be re-prefixed.
        let full = "http://example.com/poster.jpg"
        XCTAssertEqual(TMDBService.posterURL(from: full), full)
    }

    func testBarePathWithLeadingSlashGetsBasePrefix() {
        let path = "/abc123.jpg"
        XCTAssertEqual(TMDBService.posterURL(from: path),
                       TMDBService.imageBase + "/abc123.jpg")
    }

    func testBarePathWithoutLeadingSlashGetsExactlyOneSlash() {
        let path = "abc123.jpg"
        XCTAssertEqual(TMDBService.posterURL(from: path),
                       TMDBService.imageBase + "/abc123.jpg")
    }

    func testNilReturnsNil() {
        XCTAssertNil(TMDBService.posterURL(from: nil))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(TMDBService.posterURL(from: ""))
    }
}
