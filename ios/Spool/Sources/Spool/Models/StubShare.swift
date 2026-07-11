import Foundation

// The share-card payload + its pure mappers. Carries the REAL fields a shared
// stub renders (title / tier / review line / moods / date / sequence number /
// director / year / handle) so `StubShareScreen` and `StubImageRenderer` never
// fall back to demo constants. The `from(row:)` / `from(day:)` factories are
// pure so the StubRow → share mapping is unit-testable without a live fetch.
// Date + number formatting is delegated to `StubFormat` (the ONE implementation
// the calendar's "last watched" card also uses), so the share card's
// "APR · 18 · 2026" / "#0042" match the rest of the app byte-for-byte.

/// Shared stub-string formatters. Extracted from `StubsScreen` (where they were
/// `private static admitDate`/`stubNumber`) so the share payload and the stubs
/// calendar format dates and sequence numbers identically — one source of truth,
/// no drift between the on-screen card and the exported image.
public enum StubFormat {
    private static let monthAbbrev = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "yyyy-MM-dd" → "APR · 18 · 2026". Falls back to the uppercased input when
    /// the string isn't a 3-part date (so a malformed value degrades to itself
    /// rather than a misleading placeholder).
    public static func admitDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateString.uppercased() }
        let m = (1...12).contains(month) ? monthAbbrev[month] : "—"
        return "\(m) · \(String(format: "%02d", day)) · \(parts[0])"
    }

    /// Global stub count → zero-padded "#0042" sequence label.
    public static func stubNumber(_ count: Int) -> String {
        "#" + String(format: "%04d", max(count, 0))
    }
}

/// The fully-resolved payload a share card renders. Every field is REAL data —
/// there are no demo defaults here on purpose: a signed-in user sharing their
/// stub gets their own line/moods/date/number/handle, never "@yurui" or
/// "cried on the 6 train.".
public struct StubShare: Equatable, Sendable {
    public var title: String
    public var tier: Tier
    /// The user's own review line. May be empty (no line written) — the card
    /// omits the quote block when empty rather than inventing one.
    public var line: String
    public var moods: [String]
    /// Preformatted "APR · 18 · 2026" (via `StubFormat.admitDate`).
    public var date: String
    /// Preformatted "#0042" sequence label (via `StubFormat.stubNumber`).
    public var stubNo: String
    /// Director/creator/author. Empty when the source carries no attribution —
    /// the card shows the "—" placeholder the rest of the app uses rather than a
    /// fabricated name.
    public var director: String
    public var year: Int
    /// Poster art, when the source row has one.
    public var posterUrl: String?
    /// "@handle" of the sharer. Resolved from the real profile; `handleFallback`
    /// is used only until the profile fetch lands (see `StubShareScreen`).
    public var handle: String

    public init(title: String, tier: Tier, line: String, moods: [String],
                date: String, stubNo: String, director: String, year: Int,
                posterUrl: String? = nil, handle: String) {
        self.title = title
        self.tier = tier
        self.line = line
        self.moods = moods
        self.date = date
        self.stubNo = stubNo
        self.director = director
        self.year = year
        self.posterUrl = posterUrl
        self.handle = handle
    }

    /// The `Movie` the share card / renderer draw. Built from the payload's own
    /// real fields — never the old `Movie(year: 2023, director: "celine song")`
    /// literal.
    public var movie: Movie {
        Movie(id: title, title: title, year: year, director: director,
              seed: 0, posterUrl: posterUrl)
    }

    /// REAL-DATA mapping from a fetched `StubRow`. This is the primary path:
    /// every field comes off the row (line, moods, poster, watched_date) or the
    /// caller-supplied real handle + global stub count. Pure → unit-tested.
    ///
    /// - `stubCount`: the sharer's global stub total, formatted to the same
    ///   "#0042" label the "last watched" card uses. Pass `StubRepository`'s
    ///   `countStubs` result.
    public static func from(row: StubRow, stubCount: Int, handle: String) -> StubShare {
        StubShare(
            title: row.title,
            tier: Tier(rawValue: row.tier) ?? .S,
            line: row.stub_line ?? "",
            moods: row.mood_tags,
            date: StubFormat.admitDate(row.watched_date),
            stubNo: StubFormat.stubNumber(stubCount),
            // Stub rows don't persist director; leave the attribution to the
            // app's "—" placeholder rather than inventing a name.
            director: "—",
            // watched_date is the watch date, not the release year, but it's the
            // only real year the row carries; parse it rather than hardcode 2023.
            year: Self.year(from: row.watched_date),
            posterUrl: row.poster_path,
            handle: handle
        )
    }

    /// Fixture / preview-mode mapping from a lossy `WatchedDay`. A `WatchedDay`
    /// carries no review line, moods, or director (they were dropped in
    /// `rowToDay`), so those render empty rather than as demo constants. Used
    /// only when no real `StubRow` is available (preview mode, fixtures).
    public static func from(day: WatchedDay, stubCount: Int, handle: String) -> StubShare {
        StubShare(
            title: day.title,
            tier: day.tier,
            line: "",
            moods: [],
            date: Self.admitDate(day: day),
            stubNo: StubFormat.stubNumber(stubCount),
            director: "—",
            year: day.year ?? Calendar.current.component(.year, from: Date()),
            posterUrl: nil,
            handle: handle
        )
    }

    /// Format a `WatchedDay`'s day/month/year into the "APR · 18 · 2026" shape,
    /// reusing `StubFormat.admitDate` by rebuilding the "yyyy-MM-dd" string it
    /// expects. Falls back to a day-only label when month/year are missing.
    private static func admitDate(day: WatchedDay) -> String {
        guard let month = day.month, let year = day.year else {
            return "DAY · \(String(format: "%02d", max(day.day, 0)))"
        }
        let iso = String(format: "%04d-%02d-%02d", year, month, day.day)
        return StubFormat.admitDate(iso)
    }

    private static func year(from watchedDate: String) -> Int {
        let parts = watchedDate.split(separator: "-")
        return parts.first.flatMap { Int($0) } ?? Calendar.current.component(.year, from: Date())
    }
}
