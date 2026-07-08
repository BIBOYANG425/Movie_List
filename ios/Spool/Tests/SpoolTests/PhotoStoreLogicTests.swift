import XCTest
@testable import Spool

/// Pure tests for `PhotoStoreLogic` — the network-free half of the journal
/// `PhotoStore`. Two seams, both mirroring web `services/journalService.ts`:
///
///  - `photoPath(userID:entryID:index:ext:)` mirrors web `uploadJournalPhoto`'s
///    `const path = \`${userId}/${entryId}/${index}.${ext}\`` (journalService.ts
///    L699). NOTE the middle segment is the journal-entry UUID, NOT the tmdb_id
///    — web threads `result.id` / `loadedEntryId` (the `journal_entries.id`)
///    into the upload, never `item.id` (see JournalConversation.tsx L421-425).
///  - `extractPath(fromStored:)` mirrors `extractJournalPhotoPath` (L600): plain
///    path passthrough (trimmed, leading slashes stripped); full journal-photos
///    URL (public/sign/authenticated/render shapes) → the object path after the
///    bucket, query/hash stripped, percent-decoded; foreign/other-bucket/empty
///    → nil (unsignable).
final class PhotoStoreLogicTests: XCTestCase {

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let entryID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    // MARK: photoPath — "{userId}/{entryId}/{index}.{ext}"

    /// Web: `${userId}/${entryId}/${index}.${ext}`. UUIDs lowercased on the wire
    /// (web ids are already lowercase; Swift's UUID uppercases, so the seam must
    /// lowercase to keep paths stable across platforms).
    func testPhotoPathFormat() {
        let path = PhotoStoreLogic.photoPath(userID: uid, entryID: entryID, index: 0, ext: "jpg")
        XCTAssertEqual(path, "\(uid.uuidString.lowercased())/\(entryID.uuidString.lowercased())/0.jpg")
    }

    /// The middle segment is the ENTRY uuid, not a tmdb_id — a different entry
    /// for the same movie lands under a different folder.
    func testPhotoPathUsesEntryIDNotTmdb() {
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let a = PhotoStoreLogic.photoPath(userID: uid, entryID: entryID, index: 1, ext: "png")
        let b = PhotoStoreLogic.photoPath(userID: uid, entryID: other, index: 1, ext: "png")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, "\(uid.uuidString.lowercased())/\(entryID.uuidString.lowercased())/1.png")
    }

    /// Index increments the filename, extension is preserved verbatim.
    func testPhotoPathIndexAndExt() {
        XCTAssertEqual(
            PhotoStoreLogic.photoPath(userID: uid, entryID: entryID, index: 5, ext: "heic"),
            "\(uid.uuidString.lowercased())/\(entryID.uuidString.lowercased())/5.heic"
        )
    }

    // MARK: extractPath — plain path passthrough

    /// A plain storage path is returned as-is.
    func testExtractPathPlainPassthrough() {
        XCTAssertEqual(
            PhotoStoreLogic.extractPath(fromStored: "u/entry/0.jpg"),
            "u/entry/0.jpg"
        )
    }

    /// A single leading slash is stripped and surrounding whitespace trimmed
    /// (web `trimmed.replace(/^\/+/, '')`).
    func testExtractPathStripsLeadingSlashAndTrims() {
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: "  /u/e/0.jpg  "), "u/e/0.jpg")
    }

    /// A `//`-prefixed value is a protocol-relative URL to web
    /// (`trimmed.startsWith('//')` → null), NOT a path with extra slashes — so
    /// it is unsignable → nil. Mirror that exactly (do NOT strip `//` to a path).
    func testExtractPathProtocolRelativeNil() {
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: "///u/e/0.jpg"))
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: "//u/e/0.jpg"))
    }

    // MARK: extractPath — full journal-photos URL → path

    /// Legacy public URL → the object path after the bucket segment.
    func testExtractPathFromPublicURL() {
        let url = "https://proj.supabase.co/storage/v1/object/public/journal-photos/u/e/0.jpg"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/0.jpg")
    }

    /// Expired signed URL → the object path, query token stripped.
    func testExtractPathFromSignedURLStripsQuery() {
        let url = "https://proj.supabase.co/storage/v1/object/sign/journal-photos/u/e/0.jpg?token=abc.def"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/0.jpg")
    }

    /// Authenticated read URL → path.
    func testExtractPathFromAuthenticatedURL() {
        let url = "https://proj.supabase.co/storage/v1/object/authenticated/journal-photos/u/e/1.png"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/1.png")
    }

    /// Bare object download URL (older SDK, no public/sign/authenticated
    /// segment) → path.
    func testExtractPathFromBareObjectURL() {
        let url = "https://proj.supabase.co/storage/v1/object/journal-photos/u/e/2.jpg"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/2.jpg")
    }

    /// Image-render transformation URL → path.
    func testExtractPathFromRenderURL() {
        let url = "https://proj.supabase.co/storage/v1/render/image/public/journal-photos/u/e/3.jpg"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/3.jpg")
    }

    /// A hash fragment is stripped like a query.
    func testExtractPathStripsHash() {
        let url = "https://proj.supabase.co/storage/v1/object/public/journal-photos/u/e/0.jpg#frag"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/e/0.jpg")
    }

    /// Percent-encoded segments are decoded (web maps decodeURIComponent per
    /// segment).
    func testExtractPathPercentDecodes() {
        let url = "https://proj.supabase.co/storage/v1/object/public/journal-photos/u/my%20entry/0.jpg"
        XCTAssertEqual(PhotoStoreLogic.extractPath(fromStored: url), "u/my entry/0.jpg")
    }

    // MARK: extractPath — unsignable → nil

    /// A URL into another bucket cannot be mapped to journal-photos → nil.
    func testExtractPathForeignBucketNil() {
        let url = "https://proj.supabase.co/storage/v1/object/public/avatars/u/0.jpg"
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: url))
    }

    /// A completely foreign http(s) URL (no storage marker) → nil.
    func testExtractPathForeignURLNil() {
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: "https://evil.example.com/pic.jpg"))
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: "//cdn.example.com/pic.jpg"))
    }

    /// Empty / whitespace-only → nil.
    func testExtractPathEmptyNil() {
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: ""))
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: "   "))
    }

    /// A URL whose marker is present but with no object remainder → nil.
    func testExtractPathMarkerOnlyNil() {
        let url = "https://proj.supabase.co/storage/v1/object/public/journal-photos/"
        XCTAssertNil(PhotoStoreLogic.extractPath(fromStored: url))
    }
}
