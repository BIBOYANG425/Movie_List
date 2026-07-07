# C0 iOS Stub Write Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS writes a ticket stub to `movie_stubs` at the end of every rank flow, mirroring the web reference contract exactly as fixed in PR #30, ending the iOS-users-generate-no-stubs data loss.

**Architecture:** A pure contract layer (`StubWriteContract`) builds the two wire payloads and the user-local date string; a pure `PosterPalette` extracts up to 3 hex colors from poster image data via ImageIO/CoreGraphics; a thin `StubWriter` orchestrates insert-first → on unique-conflict update-subset → unstructured palette-refresh task, and `RankPersistence.save` chains it after a successful ranking insert. The unused legacy `insertStub`/`StubInsert` write path is deleted.

**Tech Stack:** Swift 5.9+ (SwiftPM package `ios/Spool`), supabase-swift, ImageIO + CoreGraphics (NO UIKit — the package also builds the `SpoolMac` target and tests run on macOS), XCTest.

## Global Constraints

- Branch `feat/ios-parity-c0-stub-write` cut from `main` AFTER PR #30 is merged (this plan mirrors the web contract that PR establishes).
- The write contract is defined by `docs/plans/audits/2026-07-07-c0-stub-web-audit.md` ("Reference semantics") and PR #30's shape: INSERT sends `user_id, media_type, tmdb_id, title, poster_path, tier, template_id, watched_date, updated_at` and NOTHING else (no `palette`, no `mood_tags`, no `stub_line`); on SQLSTATE 23505 the fallback UPDATE sends ONLY `title, poster_path, tier, template_id, updated_at`, keyed on `(user_id, media_type, tmdb_id)`.
- `watched_date` is the user's LOCAL calendar day `yyyy-MM-dd`. Never use `ISODate.yyyyMMdd` (it is GMT-pinned — that is the exact bug class PR #30 fixed on web).
- `media_type` is the constant `"movie"` in this cycle. `poster_path` passes through `movie.posterUrl` unchanged (full URL). `template_id` is `"s_tier_gold"` for S tier, else `"default"`.
- Stub failure must never fail or delay-fail the rank save (log-only, no toast, no throw out of `StubWriter`).
- Moods and one-liner continue to flow to `user_rankings.notes` (unchanged); neither client writes `mood_tags`/`stub_line` until Cycle 2.
- Test command: `swift test --package-path ios/Spool` (filter: `--filter <ClassName>`). Full suite must stay green (73 existing tests + new ones).
- Any touched file with a `Header last reviewed:` comment gets its summary updated and date bumped to the commit date.
- Conventional commits; end every commit message body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Pure contract layer — payloads, local date, template id, shared 23505 helper

**Files:**
- Create: `ios/Spool/Sources/Spool/Services/StubWriteContract.swift`
- Create: `ios/Spool/Sources/Spool/Services/PostgresErrors.swift`
- Modify: `ios/Spool/Sources/Spool/Services/FollowRepository.swift:179-187` (switch its private unique-violation check to the shared helper)
- Test: `ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift`

**Interfaces:**
- Consumes: `Movie` (fields `id: String`, `title: String`, `posterUrl: String?`), `Tier` (raw values "S"..."D") — both existing.
- Produces (Task 3 depends on these exact names):

```swift
public struct StubInsertPayload: Encodable, Equatable {
    let user_id: UUID; let media_type: String; let tmdb_id: String
    let title: String; let poster_path: String?; let tier: String
    let template_id: String; let watched_date: String; let updated_at: String
}
public struct StubConflictUpdatePayload: Encodable, Equatable {
    let title: String; let poster_path: String?; let tier: String
    let template_id: String; let updated_at: String
}
public enum StubWriteContract {
    static func templateID(for tier: Tier) -> String
    static func localDateString(from date: Date, calendar: Calendar) -> String
    static func insertPayload(userID: UUID, movie: Movie, tier: Tier, now: Date, calendar: Calendar) -> StubInsertPayload
    static func conflictUpdatePayload(movie: Movie, tier: Tier, now: Date) -> StubConflictUpdatePayload
}
public enum PostgresErrors { static func isUniqueViolation(_ error: Error) -> Bool }
```

- [ ] **Step 1: Write the failing tests**

Create `ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift`:

```swift
import XCTest
@testable import Spool

final class StubWriteContractTests: XCTestCase {

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var movie: Movie {
        Movie(id: "603", title: "The Matrix",
              posterUrl: "https://image.tmdb.org/t/p/w500/matrix.jpg")
    }
    // 2026-07-07T02:00:00Z == 2026-07-06 19:00 in America/Los_Angeles (PDT)
    private let eveningUTC = Date(timeIntervalSince1970: 1_783_389_600)

    private func calendar(_ tzID: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tzID)!
        return c
    }

    private func jsonKeys<T: Encodable>(_ payload: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Set(obj.keys)
    }

    // MARK: local date — pinned to a named timezone so a GMT regression
    // fails deterministically regardless of the runner's timezone.

    func testLocalDateStringUsesLocalCalendarDay() {
        let la = StubWriteContract.localDateString(from: eveningUTC, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(la, "2026-07-06", "evening UTC must land on the LA calendar day")
        let utc = StubWriteContract.localDateString(from: eveningUTC, calendar: calendar("UTC"))
        XCTAssertEqual(utc, "2026-07-07")
    }

    // MARK: template id

    func testTemplateIDGoldOnlyForSTier() {
        XCTAssertEqual(StubWriteContract.templateID(for: .S), "s_tier_gold")
        for tier in [Tier.A, .B, .C, .D] {
            XCTAssertEqual(StubWriteContract.templateID(for: tier), "default", "\(tier)")
        }
    }

    // MARK: insert payload — exact key set per audit §1.1 + PR #30

    func testInsertPayloadKeySetAndValues() throws {
        let p = StubWriteContract.insertPayload(
            userID: uid, movie: movie, tier: .S,
            now: eveningUTC, calendar: calendar("America/Los_Angeles")
        )
        XCTAssertEqual(try jsonKeys(p), [
            "user_id", "media_type", "tmdb_id", "title", "poster_path",
            "tier", "template_id", "watched_date", "updated_at",
        ], "no palette, no mood_tags, no stub_line — DB defaults own those")
        XCTAssertEqual(p.media_type, "movie")
        XCTAssertEqual(p.tmdb_id, "603")
        XCTAssertEqual(p.poster_path, "https://image.tmdb.org/t/p/w500/matrix.jpg")
        XCTAssertEqual(p.tier, "S")
        XCTAssertEqual(p.template_id, "s_tier_gold")
        XCTAssertEqual(p.watched_date, "2026-07-06")
        XCTAssertTrue(p.updated_at.hasPrefix("2026-07-07T"), "updated_at is an ISO8601 instant, not a local day")
    }

    // MARK: conflict-update payload — refresh subset ONLY (audit §1.2)

    func testConflictUpdatePayloadOmitsPreservedColumns() throws {
        let p = StubWriteContract.conflictUpdatePayload(movie: movie, tier: .B, now: eveningUTC)
        XCTAssertEqual(try jsonKeys(p), ["title", "poster_path", "tier", "template_id", "updated_at"],
                       "watched_date/palette/mood_tags/stub_line must be preserved on re-rank")
        XCTAssertEqual(p.template_id, "default")
    }

    // MARK: shared unique-violation classifier

    func testIsUniqueViolationMatchesSQLState() {
        struct Fake: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(PostgresErrors.isUniqueViolation(Fake(description: "PostgrestError code 23505")))
        XCTAssertTrue(PostgresErrors.isUniqueViolation(Fake(description: "duplicate key value violates unique constraint")))
        XCTAssertFalse(PostgresErrors.isUniqueViolation(Fake(description: "PostgrestError code 42501 RLS")))
    }
}
```

Note: check the real `Movie` initializer before using the literal above (`grep -n "struct Movie" -A 20 ios/Spool/Sources/Spool/Models/Models.swift`) and adapt the two-argument spots (extra required fields get sensible literals). Do not change `Movie` itself.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ios/Spool --filter StubWriteContractTests`
Expected: BUILD FAILURE — `StubWriteContract` / `PostgresErrors` unresolved.

- [ ] **Step 3: Implement the contract layer**

Create `ios/Spool/Sources/Spool/Services/StubWriteContract.swift`:

```swift
import Foundation

// Wire payloads for `movie_stubs`, mirroring the web contract fixed in
// PR #30 (docs/plans/audits/2026-07-07-c0-stub-web-audit.md §1):
//  - INSERT carries an explicit user-LOCAL watched_date and never touches
//    palette/mood_tags/stub_line (DB defaults own them).
//  - The 23505 fallback UPDATE refreshes only title/poster_path/tier/
//    template_id/updated_at so re-ranks preserve the user's stub history.

public struct StubInsertPayload: Encodable, Equatable {
    let user_id: UUID
    let media_type: String
    let tmdb_id: String
    let title: String
    let poster_path: String?
    let tier: String
    let template_id: String
    let watched_date: String
    let updated_at: String
}

public struct StubConflictUpdatePayload: Encodable, Equatable {
    let title: String
    let poster_path: String?
    let tier: String
    let template_id: String
    let updated_at: String
}

public enum StubWriteContract {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func templateID(for tier: Tier) -> String {
        tier == .S ? "s_tier_gold" : "default"
    }

    /// User-local calendar day. Deliberately NOT `ISODate.yyyyMMdd`, which
    /// is GMT-pinned — the exact bug PR #30 fixed on web (evening ranks
    /// landing on tomorrow's date).
    public static func localDateString(from date: Date = Date(),
                                       calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func insertPayload(userID: UUID, movie: Movie, tier: Tier,
                                     now: Date = Date(),
                                     calendar: Calendar = .current) -> StubInsertPayload {
        StubInsertPayload(
            user_id: userID,
            media_type: "movie",
            tmdb_id: movie.id,
            title: movie.title,
            poster_path: movie.posterUrl,
            tier: tier.rawValue,
            template_id: templateID(for: tier),
            watched_date: localDateString(from: now, calendar: calendar),
            updated_at: iso8601.string(from: now)
        )
    }

    public static func conflictUpdatePayload(movie: Movie, tier: Tier,
                                             now: Date = Date()) -> StubConflictUpdatePayload {
        StubConflictUpdatePayload(
            title: movie.title,
            poster_path: movie.posterUrl,
            tier: tier.rawValue,
            template_id: templateID(for: tier),
            updated_at: iso8601.string(from: now)
        )
    }
}
```

Create `ios/Spool/Sources/Spool/Services/PostgresErrors.swift`:

```swift
import Foundation

/// Shared Postgres error classification for supabase-swift call sites.
/// Extracted from FollowRepository's proven private check so every
/// repository detects unique violations the same way.
public enum PostgresErrors {
    /// SQLSTATE 23505 (unique_violation), surfaced through supabase-swift
    /// error descriptions in slightly different shapes per version.
    public static func isUniqueViolation(_ error: Error) -> Bool {
        let s = String(describing: error)
        return s.contains("23505") || s.lowercased().contains("duplicate key")
    }
}
```

In `ios/Spool/Sources/Spool/Services/FollowRepository.swift`, replace the body of its private unique-violation helper (lines ~179-187) with a delegation call `PostgresErrors.isUniqueViolation(error)` (keep the private function name and signature so its call sites are untouched), and bump the file's `Header last reviewed:` date if it carries one.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ios/Spool --filter StubWriteContractTests`
Expected: 5 tests PASS. Then `swift test --package-path ios/Spool` — full suite green (FollowRepository behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add ios/Spool/Sources/Spool/Services/StubWriteContract.swift ios/Spool/Sources/Spool/Services/PostgresErrors.swift ios/Spool/Sources/Spool/Services/FollowRepository.swift ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift
git commit -m "feat(ios): stub write contract payloads + shared unique-violation classifier"
```

---

### Task 2: Poster palette extraction (pure, no UIKit)

**Files:**
- Create: `ios/Spool/Sources/Spool/Services/PosterPalette.swift`
- Test: `ios/Spool/Tests/SpoolTests/PosterPaletteTests.swift`

**Interfaces:**
- Produces (Task 3 depends on this exact name): `public enum PosterPalette { static func extract(from data: Data, maxColors: Int = 3) -> [String] }` — returns up to `maxColors` lowercase `"#rrggbb"` strings ordered by pixel-count dominance; `[]` on any failure (undecodable data, zero opaque pixels).

- [ ] **Step 1: Write the failing tests**

Create `ios/Spool/Tests/SpoolTests/PosterPaletteTests.swift`:

```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Spool

final class PosterPaletteTests: XCTestCase {

    /// PNG-encoded solid or striped test image, built without UIKit.
    private func pngData(stripes: [(CGColor, CGFloat)], size: CGSize = .init(width: 32, height: 48)) throws -> Data {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        var y: CGFloat = 0
        for (color, fraction) in stripes {
            let h = size.height * fraction
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: h))
            y += h
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, 1])!
    }

    func testSolidRedYieldsRedFirst() throws {
        let data = try pngData(stripes: [(rgb(1, 0, 0), 1.0)])
        let colors = PosterPalette.extract(from: data)
        XCTAssertEqual(colors.first, "#ff0000")
        XCTAssertLessThanOrEqual(colors.count, 3)
    }

    func testTwoToneOrdersByDominance() throws {
        // 75% blue, 25% red → blue must rank first
        let data = try pngData(stripes: [(rgb(0, 0, 1), 0.75), (rgb(1, 0, 0), 0.25)])
        let colors = PosterPalette.extract(from: data)
        XCTAssertEqual(colors.first, "#0000ff")
        XCTAssertTrue(colors.contains("#ff0000"), "second stripe should appear: \(colors)")
    }

    func testHexFormatIsLowercaseSixDigit() throws {
        let data = try pngData(stripes: [(rgb(0.5, 0.25, 0.75), 1.0)])
        let colors = PosterPalette.extract(from: data)
        for c in colors {
            XCTAssertTrue(c.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil, c)
        }
    }

    func testGarbageDataReturnsEmpty() {
        XCTAssertEqual(PosterPalette.extract(from: Data([0xDE, 0xAD, 0xBE, 0xEF])), [])
        XCTAssertEqual(PosterPalette.extract(from: Data()), [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path ios/Spool --filter PosterPaletteTests`
Expected: BUILD FAILURE — `PosterPalette` unresolved.

- [ ] **Step 3: Implement the extractor**

Create `ios/Spool/Sources/Spool/Services/PosterPalette.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO

/// Dominant-color extraction for stub palettes. Mirrors the web's
/// canvas-downsample + bucket approach (stubService extraction): decode,
/// downsample to a tiny bitmap, quantize to 4 bits/channel buckets, take
/// the top buckets by pixel count, emit each bucket's mean color as
/// lowercase "#rrggbb". Colors are display-only; cross-platform pixel
/// equality with web is NOT a goal — the [] -on-failure contract is.
/// Pure CoreGraphics/ImageIO so it runs in SwiftPM tests and SpoolMac.
public enum PosterPalette {

    public static func extract(from data: Data, maxColors: Int = 3) -> [String] {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }

        // Downsample to at most 24x36 (poster aspect) for stable, cheap counting.
        let targetW = 24, targetH = 36
        guard let ctx = CGContext(
            data: nil, width: targetW, height: targetH,
            bitsPerComponent: 8, bytesPerRow: targetW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let pixels = ctx.data else { return [] }

        // Bucket key: 4 bits per channel. Track count + component sums per bucket.
        var counts: [UInt16: (count: Int, r: Int, g: Int, b: Int)] = [:]
        let buf = pixels.bindMemory(to: UInt8.self, capacity: targetW * targetH * 4)
        for i in 0..<(targetW * targetH) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            let a = Int(buf[i * 4 + 3])
            if a < 128 { continue } // skip transparent
            let key = UInt16(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4))
            var entry = counts[key] ?? (0, 0, 0, 0)
            entry = (entry.count + 1, entry.r + r, entry.g + g, entry.b + b)
            counts[key] = entry
        }
        guard !counts.isEmpty else { return [] }

        // Top buckets by count; deterministic tie-break on bucket key.
        let top = counts.sorted { lhs, rhs in
            lhs.value.count != rhs.value.count
                ? lhs.value.count > rhs.value.count
                : lhs.key < rhs.key
        }.prefix(maxColors)

        return top.map { _, v in
            String(format: "#%02x%02x%02x", v.r / v.count, v.g / v.count, v.b / v.count)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path ios/Spool --filter PosterPaletteTests`
Expected: 4 tests PASS. Note: if `UniformTypeIdentifiers` is unavailable at the package's platform floor, use the literal `"public.png" as CFString` in the test helper instead and drop that import.

- [ ] **Step 5: Commit**

```bash
git add ios/Spool/Sources/Spool/Services/PosterPalette.swift ios/Spool/Tests/SpoolTests/PosterPaletteTests.swift
git commit -m "feat(ios): poster palette extraction via ImageIO downsample buckets"
```

---

### Task 3: StubWriter orchestration, RankPersistence wiring, legacy write-path deletion

**Files:**
- Create: `ios/Spool/Sources/Spool/Services/StubWriter.swift`
- Modify: `ios/Spool/Sources/Spool/Services/RankPersistence.swift:59-73` (chain the stub write; replace the TODO; bump header)
- Modify: `ios/Spool/Sources/Spool/Services/RankingRepository.swift:144-170, 203-230, 299+` (delete `insertStub`, `StubInsert`, `StubPayload` — the never-called legacy path that violates the contract)
- Modify: `ios/Spool/Sources/Spool/Services/StubRepository.swift:5-6,13-14` (doc comment references the deleted `insertStub`; point it at `StubWriter`; bump header)

**Interfaces:**
- Consumes: `StubWriteContract.insertPayload/conflictUpdatePayload`, `PostgresErrors.isUniqueViolation` (Task 1), `PosterPalette.extract` (Task 2), `SpoolClient.shared`, `SpoolClient.currentUserID()` (existing).
- Produces: `public enum StubWriter { static func writeStub(movie: Movie, tier: Tier) async }` — never throws; all failures logged with `[StubWriter]` prefix.

- [ ] **Step 1: Verify the legacy write path is dead before deleting**

Run: `grep -rn "insertStub\|StubInsert\b" ios/Spool/Sources ios/Spool/Tests --include="*.swift" | grep -v "StubWriter\|doc comment"`
Expected: hits ONLY in `RankingRepository.swift` (the definition) and `StubRepository.swift` (doc comments). If ANY other caller exists, STOP and report BLOCKED with the call site.

- [ ] **Step 2: Implement StubWriter**

Create `ios/Spool/Sources/Spool/Services/StubWriter.swift`:

```swift
import Foundation

/// Stub write orchestration — the iOS mirror of web `createStub` +
/// `insertStubOrUpdateOnConflict` as fixed in PR #30:
///
///  1. INSERT with explicit user-local watched_date, no palette field.
///  2. On unique violation (23505): UPDATE only the refresh subset
///     (title/poster_path/tier/template_id/updated_at) keyed on
///     (user_id, media_type, tmdb_id) — preserving watched_date,
///     palette, mood_tags, stub_line.
///  3. Either way, kick an unstructured palette-refresh task (fetch
///     poster → PosterPalette → UPDATE palette only). Extraction failure
///     leaves the palette untouched.
///
/// Fire-and-forget: nothing here throws to the caller; a stub failure
/// must never fail a rank save. Contract source of truth:
/// docs/contracts/shared-payloads.md.
///
/// Header last reviewed: 2026-07-07
public enum StubWriter {

    public static func writeStub(movie: Movie, tier: Tier) async {
        guard let client = SpoolClient.shared,
              let userID = await SpoolClient.currentUserID() else { return }

        let insert = StubWriteContract.insertPayload(userID: userID, movie: movie, tier: tier)
        do {
            try await client.from("movie_stubs").insert(insert).execute()
        } catch where PostgresErrors.isUniqueViolation(error) {
            let update = StubWriteContract.conflictUpdatePayload(movie: movie, tier: tier)
            do {
                try await client.from("movie_stubs")
                    .update(update)
                    .eq("user_id", value: userID.uuidString)
                    .eq("media_type", value: "movie")
                    .eq("tmdb_id", value: movie.id)
                    .execute()
            } catch {
                NSLog("[StubWriter] conflict update failed: \(error)")
                return
            }
        } catch {
            NSLog("[StubWriter] insert failed: \(error)")
            return
        }

        // Palette refresh runs detached so the rank-flow finish path never
        // waits on an image download. Mirrors web's unawaited extraction.
        Task.detached(priority: .utility) {
            await refreshPalette(userID: userID, movie: movie)
        }
    }

    private struct PaletteUpdatePayload: Encodable {
        let palette: [String]
    }

    private static func refreshPalette(userID: UUID, movie: Movie) async {
        guard let client = SpoolClient.shared,
              let urlString = movie.posterUrl,
              let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }

        let colors = PosterPalette.extract(from: data)
        guard !colors.isEmpty else { return } // failure leaves palette as-is

        do {
            try await client.from("movie_stubs")
                .update(PaletteUpdatePayload(palette: colors))
                .eq("user_id", value: userID.uuidString)
                .eq("media_type", value: "movie")
                .eq("tmdb_id", value: movie.id)
                .execute()
        } catch {
            NSLog("[StubWriter] palette update failed: \(error)")
        }
    }
}
```

Before building, verify the `.update(...).eq(...)` chain shape against an existing repository update call (`grep -rn "\.update(" ios/Spool/Sources/Spool/Services/` — ProfileRepository has one); match its argument style exactly.

- [ ] **Step 3: Wire RankPersistence and delete the legacy path**

In `RankPersistence.swift`, replace lines 59-73 (the `do/catch` around `insertRanking` plus the TODO comment) with:

```swift
            do {
                _ = try await RankingRepository.shared.insertRanking(insert)
            } catch {
                NSLog("[RankPersistence] insertRanking failed: \(error)")
                await MainActor.run {
                    ToastCenter.shared.show(
                        "couldn't save your rank — check connection",
                        level: .error
                    )
                }
                return
            }
            // Stub write mirrors web createStub (PR #30 contract). Fire-and-
            // forget inside StubWriter: a stub failure never fails the rank
            // save, and palette extraction runs detached.
            await StubWriter.writeStub(movie: movie, tier: tier)
            return
```

Note the added `return` inside the catch: previously a failed rank insert fell through to the TODO and returned; now it must not proceed to a stub write for a rank that didn't save (web's stub creation also only follows a successful rank upsert).

Update the file's header comment: add the stub-write chaining to the flow description and bump `Header last reviewed:` to the commit date.

In `RankingRepository.swift`: delete `insertStub` (lines ~144-170), `StubInsert` (~203-230), and `StubPayload` (~299+). `StubRow` stays (the read side uses it).

In `StubRepository.swift`: update the two doc-comment references from `RankingRepository.insertStub` to `StubWriter` and bump its header date.

- [ ] **Step 4: Full suite + grep gates**

Run: `swift test --package-path ios/Spool`
Expected: all green (73 pre-existing + 9 new = 82).
Run: `grep -rn "insertStub\|StubInsert\b\|StubPayload" ios/Spool/Sources ios/Spool/Tests --include="*.swift"`
Expected: zero hits.
Run: `grep -rn "ISODate" ios/Spool/Sources/Spool/Services/StubWriter.swift ios/Spool/Sources/Spool/Services/StubWriteContract.swift`
Expected: zero hits (GMT-pinned formatter not used).

- [ ] **Step 5: Commit**

```bash
git add ios/Spool/Sources/Spool/Services/StubWriter.swift ios/Spool/Sources/Spool/Services/RankPersistence.swift ios/Spool/Sources/Spool/Services/RankingRepository.swift ios/Spool/Sources/Spool/Services/StubRepository.swift
git commit -m "feat(ios): write movie stubs on rank save via StubWriter, delete legacy insertStub path"
```

---

### Task 4: Shared-payloads contract doc + ledger update

**Files:**
- Create: `docs/contracts/shared-payloads.md`
- Modify: `docs/plans/2026-07-07-ios-parity-ledger.md` (C0 row + findings)

**Interfaces:** none — documentation task, mandated by the program design's drift-prevention rule 2.

- [ ] **Step 1: Write the contract doc**

Create `docs/contracts/shared-payloads.md`:

```markdown
# Shared Payload Contracts

Shapes BOTH clients write to shared tables. Any PR that changes a shape on
one platform updates this file and the other platform in the same cycle.
Program rule source: docs/plans/2026-07-07-ios-parity-program-design.md.

## movie_stubs (since PR #30 / C0)

One stub per `(user_id, media_type, tmdb_id)` — unique index; rewatches are
not representable. `media_type` ∈ {"movie", "tv_season"}; books never get
stubs (CHECK constraint). `poster_path` holds a FULL image URL (w500), not
a bare TMDB path.

**INSERT** (first rank of an item) — exactly these columns:
`user_id, media_type, tmdb_id, title, poster_path, tier, template_id,
watched_date, updated_at`.
- `watched_date`: the user's LOCAL calendar day, `yyyy-MM-dd`. Never UTC.
- `template_id`: `"s_tier_gold"` when tier = S, else `"default"`.
- `palette`, `mood_tags`, `stub_line`: NEVER sent — DB defaults own them
  (`palette text[] NOT NULL DEFAULT '{}'`). Reserved until C2 decides
  whether moods/one-liner move onto stubs.

**On unique violation (SQLSTATE 23505)** — UPDATE exactly
`title, poster_path, tier, template_id, updated_at`, keyed on
`(user_id, media_type, tmdb_id)`. `watched_date`, `palette`, `mood_tags`,
`stub_line` are preserved: a re-rank must not rewrite stub history.

**Palette refresh** (async, after either path): fetch poster, extract up to
3 lowercase `#rrggbb` colors, UPDATE `palette` only. Extraction failure
leaves the existing value. Renderers require length ≥ 2 and fall back to
tier colors otherwise. Cross-platform color equality is NOT required.

**Failure semantics:** stub writes are fire-and-forget on both platforms —
a stub failure never fails or delays a rank save.

Implementations: web `services/stubService.ts`
(`buildStubInsertPayload` / `buildStubConflictUpdatePayload` /
`insertStubOrUpdateOnConflict`); iOS
`ios/Spool/Sources/Spool/Services/StubWriteContract.swift` + `StubWriter.swift`.
Tests: `services/__tests__/stubService.test.ts`,
`ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift`.
```

- [ ] **Step 2: Update the ledger**

In `docs/plans/2026-07-07-ios-parity-ledger.md`, set the C0 row's iOS PR column to this branch's PR number once known (the controller fills it at PR time; leave the row's status as `iOS build in review`), and append under Audit findings:

```markdown
- [C0] [resolved] iOS legacy insertStub violated the write contract (sent palette/mood_tags/stub_line, GMT dates, no conflict handling) — deleted; StubWriter is the only stub write path
```

- [ ] **Step 3: Commit**

```bash
git add docs/contracts/shared-payloads.md docs/plans/2026-07-07-ios-parity-ledger.md
git commit -m "docs: shared-payloads contract for movie_stubs + C0 ledger update"
```

---

## Self-Review Notes

- **Spec coverage:** insert-with-local-date-no-palette (Task 1 payload + Task 3 write), 23505 update-subset (Tasks 1+3), full-URL poster pass-through (Task 1 test), template_id rule (Task 1), fire-and-forget (Task 3 StubWriter never throws; rank-failure early-returns before stub write), palette async contract (Tasks 2+3), no ISODate usage (Task 3 grep gate), contract doc + ledger (Task 4). The audit's B1/B2 equivalents cannot recur on iOS by construction: palette is absent from both payload types, and the date test pins a named timezone.
- **Verification-first gates:** Task 3 Step 1 (legacy path truly dead), Task 1 note (Movie initializer), Task 3 note (update-chain shape) — each with a stop-and-report instruction.
- **Type consistency:** `StubInsertPayload`/`StubConflictUpdatePayload`/`localDateString`/`templateID`/`isUniqueViolation`/`extract` names match across Tasks 1→3 and the tests.
- **Known asymmetry (accepted):** palette colors will differ between platforms for the same poster (different decoders/quantizers); the contract doc declares color equality a non-goal.
