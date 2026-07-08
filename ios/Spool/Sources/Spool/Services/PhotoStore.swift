import Foundation
import Supabase

/// Journal photo storage — upload + fresh signed URLs for the private
/// `journal-photos` bucket. Mirrors the Photos section of web
/// `services/journalService.ts` (`uploadJournalPhoto`, `extractJournalPhotoPath`,
/// `getJournalPhotoUrl(s)`) and the contract in `docs/contracts/shared-payloads.md`.
///
/// Contract (audit B4): the bucket is PRIVATE with owner-only storage RLS.
///  - `journal_entries.photo_paths` stores storage object PATHS, NEVER URLs.
///    The path is `{userId}/{entryId}/{index}.{ext}` — the middle segment is
///    the journal-entry UUID, not the tmdb_id. Web threads the upserted row's
///    `id` (`result.id` / `loadedEntryId`) into `uploadJournalPhoto`, never the
///    movie's `item.id` (JournalConversation.tsx L421-425; journalService.ts
///    L699 `${userId}/${entryId}/${index}.${ext}`).
///  - Rendering mints signed URLs (30-day TTL, `journalPhotoSignedURLTTL`) fresh
///    on every render — NOTHING persists a signed URL, so expiry never strands a
///    stored link.
///  - Legacy defense: if a full URL ever landed in `photo_paths` (old builds /
///    manual rows), `PhotoStoreLogic.extractPath` converts it back to a signable
///    path before signing, so those rows keep rendering after the bucket flip.
///
/// Scope this cycle: iOS renders ONLY the OWNER'S OWN journal photos (inside the
/// owner's Stubs tab), so owner-only storage SELECT is sufficient. No cross-user
/// photo surface is built here (that needs the storage-policy extension — out of
/// scope, ledgered).
///
/// PHPicker selection is a VIEW concern (Task 6 supplies the `Data` + ext); this
/// actor takes bytes and returns/consumes paths.
///
/// Header last reviewed: 2026-07-07
public actor PhotoStore {

    public static let shared = PhotoStore()

    public enum PhotoError: Error {
        case notConfigured
    }

    private var bucket: StorageFileApi {
        get throws {
            guard let client = SpoolClient.shared else { throw PhotoError.notConfigured }
            return client.storage.from(Self.bucketID)
        }
    }

    /// The private bucket id — web `JOURNAL_PHOTO_BUCKET = 'journal-photos'`.
    static let bucketID = "journal-photos"

    // MARK: upload

    /// Upload `data` for `(userID, entryID, index)` and return the stored PATH
    /// (never a URL — `photo_paths` holds paths). `upsert: true` so re-uploading
    /// the same slot overwrites, matching web `{ upsert: true }`. Path built by
    /// the pure `PhotoStoreLogic.photoPath`.
    public func upload(
        data: Data,
        userID: UUID,
        entryID: UUID,
        index: Int,
        ext: String
    ) async throws -> String {
        let path = PhotoStoreLogic.photoPath(userID: userID, entryID: entryID, index: index, ext: ext)
        do {
            _ = try await bucket.upload(
                path,
                data: data,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: Self.contentType(forExt: ext),
                    upsert: true
                )
            )
            return path
        } catch {
            NSLog("[PhotoStore] upload failed: \(error)")
            throw error
        }
    }

    // MARK: signed URLs (fresh, 30-day TTL, never persisted)

    /// A fresh 30-day signed URL for one stored value (path OR legacy full URL).
    /// Mirrors web `getJournalPhotoUrl`: normalize via `extractPath`, sign the
    /// path. Unsignable input (foreign/other-bucket/empty) throws so the caller
    /// renders a placeholder rather than a broken link.
    public func signedURL(forPath path: String) async throws -> URL {
        guard let normalized = PhotoStoreLogic.extractPath(fromStored: path) else {
            throw PhotoError.notConfigured
        }
        do {
            return try await bucket.createSignedURL(
                path: normalized,
                expiresIn: JournalConstants.journalPhotoSignedURLTTL
            )
        } catch {
            NSLog("[PhotoStore] signedURL failed: \(error)")
            throw error
        }
    }

    /// Batch fresh signed URLs — ONE round-trip for a grid of photos. Mirrors
    /// web `getJournalPhotoUrls`: the returned map is keyed by the ORIGINAL
    /// input string (path or legacy URL) so callers look up by exactly what they
    /// stored. Unsignable inputs are simply absent. The storage SDK returns URLs
    /// in input order, so results align by index with the signable subset.
    public func signedURLs(forPaths paths: [String]) async throws -> [String: URL] {
        // Keep each original alongside its normalized signable path; drop the
        // unsignable ones (they get no entry in the map).
        let signable: [(original: String, path: String)] = paths.compactMap { original in
            guard let path = PhotoStoreLogic.extractPath(fromStored: original) else { return nil }
            return (original, path)
        }
        guard !signable.isEmpty else { return [:] }

        do {
            let urls = try await bucket.createSignedURLs(
                paths: signable.map { $0.path },
                expiresIn: JournalConstants.journalPhotoSignedURLTTL
            )
            // Align by index — the SDK returns URLs in the input order.
            var map: [String: URL] = [:]
            for (entry, url) in zip(signable, urls) {
                map[entry.original] = url
            }
            return map
        } catch {
            NSLog("[PhotoStore] signedURLs failed: \(error)")
            throw error
        }
    }

    // MARK: content-type

    /// Best-effort `Content-Type` from the file extension for the upload header.
    /// Web reads it from the browser `File.type`; iOS derives it from the ext the
    /// PHPicker item reports. Defaults to `image/jpeg` (the web default ext is
    /// `jpg`).
    static func contentType(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "image/jpeg"
        }
    }
}

// MARK: - Pure marshalling seams (tested — PhotoStoreLogicTests)

/// The network-free bits of `PhotoStore`: the storage-path builder and the
/// legacy-URL → path normalizer. Extracted so both are unit-tested without a
/// live client — the storage network paths are covered by build + these pure
/// tests. Mirrors web `uploadJournalPhoto`'s path template and
/// `extractJournalPhotoPath`.
public enum PhotoStoreLogic {

    /// `{userId}/{entryId}/{index}.{ext}` — web `uploadJournalPhoto`
    /// (journalService.ts L699). The middle segment is the journal-entry UUID
    /// (`journal_entries.id`), NOT the tmdb_id. UUIDs lowercased (web ids are
    /// already lowercase; Swift uppercases, so we lowercase for cross-platform
    /// path stability).
    public static func photoPath(userID: UUID, entryID: UUID, index: Int, ext: String) -> String {
        "\(userID.uuidString.lowercased())/\(entryID.uuidString.lowercased())/\(index).\(ext)"
    }

    /// Every URL shape the Supabase storage API serves `journal-photos` objects
    /// under — web `JOURNAL_PHOTO_URL_MARKER`. Matches the segment BEFORE the
    /// bucket so the object path is everything after it:
    ///   /storage/v1/object/public/journal-photos/…
    ///   /storage/v1/object/sign/journal-photos/…?token=…
    ///   /storage/v1/object/authenticated/journal-photos/…
    ///   /storage/v1/object/journal-photos/…
    ///   /storage/v1/render/image/public/journal-photos/…
    private static let urlMarker = try! NSRegularExpression(
        pattern: #"/storage/v1/(?:object|render/image)/(?:public/|sign/|authenticated/)?journal-photos/"#
    )

    /// A URL scheme prefix (`https://`, `data:`…) — web `URL_SCHEME`.
    private static let urlScheme = try! NSRegularExpression(
        pattern: #"^[a-z][a-z0-9+.-]*://"#, options: [.caseInsensitive]
    )

    /// Pure. Normalize a `photo_paths` value to a signable storage path — web
    /// `extractJournalPhotoPath`:
    ///   - plain storage path → as-is (trimmed, leading slashes stripped);
    ///   - full journal-photos URL (any shape above) → the object path after the
    ///     bucket segment, query/hash stripped, percent-decoded per segment;
    ///   - anything else (other bucket, foreign URL, empty) → nil (unsignable).
    public static func extractPath(fromStored value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let marker = urlMarker.firstMatch(in: trimmed, range: full) {
            // Everything after the marker (i.e. after ".../journal-photos/").
            let afterMarker = marker.range.location + marker.range.length
            var rest = ns.substring(from: afterMarker)
            // Strip query / hash.
            if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                rest = String(rest[..<cut])
            }
            if rest.isEmpty { return nil }
            // Percent-decode per segment (mirror web's split('/').map(decode)).
            let decoded = rest.split(separator: "/", omittingEmptySubsequences: false)
                .map { seg -> String in String(seg).removingPercentEncoding ?? String(seg) }
                .joined(separator: "/")
            return decoded.isEmpty ? nil : decoded
        }

        // No bucket marker: a URL we cannot map to this bucket is unsignable.
        if urlScheme.firstMatch(in: trimmed, range: full) != nil || trimmed.hasPrefix("//") {
            return nil
        }

        // Plain path: strip leading slashes.
        var path = trimmed
        while path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? nil : path
    }
}
