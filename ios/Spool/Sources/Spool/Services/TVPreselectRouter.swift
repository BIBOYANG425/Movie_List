import Foundation

/// Pure preselect-routing seam for the rank-from-watchlist TV path (C5-iOS
/// Task 6). Port of web `services/watchlistRankHelpers.ts`'s
/// `resolveTVPreselectRoute` / `healTVPreselect` / `showTmdbIdFromTVId`
/// (audit B1 defense-in-depth + the C5-Task-2 self-heal seam).
///
/// When a user taps "Rank It" on a TV watchlist bookmark, the flow must decide:
///  * a WHOLE-SHOW bookmark (real-or-derivable `showTmdbId`, no `seasonNumber`)
///    → open the season grid first, then the ceremony;
///  * a SEASON bookmark (`seasonNumber` set) → straight to the ceremony.
///
/// Legacy corrupt rows carry `show_tmdb_id = 0` but a well-formed
/// `tv_{n}` / `tv_{n}_s{k}` id. The router DERIVES the real show id from the id
/// so the season-grid fetch (and the eventual `tv_rankings` write) never re-mint
/// a season-less `tv_{n}` row with `show_tmdb_id = 0` (the B1 trap the old
/// `showTmdbId`-truthiness check missed). `heal(...)` stamps the derived id back
/// onto the item so completion persists the real show id.
///
/// iOS bookmarks do NOT carry a `notes` prefill (web's season-preselect path
/// carried notes into the tier step). The `WatchlistItem` model has no notes
/// column, so the iOS season path opens the ceremony with no prefill — noted
/// here as a deliberate parity gap, not an oversight.
///
/// All of it is a pure function of the preselect fields — no client, no I/O —
/// so the routing predicate is compiler- and test-enforced
/// (`TVPreselectRouterTests`).
///
/// Header last reviewed: 2026-07-10
public enum TVPreselectRouter {

    /// Where a TV preselect should route.
    public enum Route: String, Equatable, Sendable {
        /// Whole-show preselect → open the show detail / season picker first.
        case seasonGrid
        /// Season already chosen → go straight to the ceremony (tier step).
        case tier
    }

    /// The resolved routing decision + the REAL numeric show id to fetch
    /// details / global-score with (derived from the id when the field is
    /// 0/absent, so legacy corrupt rows self-heal).
    public struct Resolution: Equatable, Sendable {
        public let route: Route
        /// `nil` only when neither `showTmdbId` nor the id yields a show id.
        public let showTmdbId: Int?

        public init(route: Route, showTmdbId: Int?) {
            self.route = route
            self.showTmdbId = showTmdbId
        }
    }

    /// The minimal preselect shape the router reads: an id plus the optional
    /// `showTmdbId` / `seasonNumber` fields. A `WatchlistItem` (and any test
    /// fixture) maps into this trivially.
    public struct Preselect: Equatable, Sendable {
        public let id: String
        public let showTmdbId: Int?
        public let seasonNumber: Int?

        public init(id: String, showTmdbId: Int? = nil, seasonNumber: Int? = nil) {
            self.id = id
            self.showTmdbId = showTmdbId
            self.seasonNumber = seasonNumber
        }
    }

    /// Extract the numeric TMDB show id embedded in a tv ranking/watchlist id.
    /// Accepts BOTH the whole-show form `tv_{n}` and the season form
    /// `tv_{n}_s{k}`; returns `nil` for any other shape. Mirror of web
    /// `showTmdbIdFromTVId` (regex `^tv_(\d+)(?:_s\d+)?$`). Pure — used to DERIVE
    /// the real show id when a legacy row carries `showTmdbId = 0`/absent.
    public static func showTmdbIdFromTVId(_ id: String) -> Int? {
        guard id.hasPrefix("tv_") else { return nil }
        let rest = id.dropFirst(3)                       // after "tv_"
        // Split on the optional `_s{k}` season suffix.
        if let sRange = rest.range(of: "_s") {
            let showDigits = rest[..<sRange.lowerBound]
            let seasonDigits = rest[sRange.upperBound...]
            guard !showDigits.isEmpty, showDigits.allSatisfy(\.isNumber),
                  !seasonDigits.isEmpty, seasonDigits.allSatisfy(\.isNumber)
            else { return nil }
            return Int(showDigits)
        }
        // Whole-show form `tv_{n}` — the whole remainder must be digits.
        guard !rest.isEmpty, rest.allSatisfy(\.isNumber) else { return nil }
        return Int(rest)
    }

    /// Hardened preselect router (audit B1). Mirror of web
    /// `resolveTVPreselectRoute`.
    ///
    /// - A whole-show preselect (no `seasonNumber`) with a well-formed `tv_{n}`
    ///   id AND a resolvable show id routes to the season grid — even if the
    ///   `showTmdbId` field was 0/absent (the corrupt-row case).
    /// - A season preselect (`seasonNumber` set) routes to the ceremony (tier),
    ///   with its show id likewise derived from a `tv_{n}_s{k}` id when the
    ///   field is 0/absent, so re-ranking a legacy corrupt row feeds the
    ///   global-score fetch the REAL id.
    ///
    /// Returns `nil` for a nil preselect (parity with web's `if (!preselect)`).
    public static func resolve(_ preselect: Preselect?) -> Resolution? {
        guard let preselect else { return nil }
        let derived = showTmdbIdFromTVId(preselect.id)
        let showTmdbId: Int? = (preselect.showTmdbId ?? 0) > 0 ? preselect.showTmdbId : derived

        // A whole-show preselect has no season yet. A `tv_{n}` id (no `_s{k}`)
        // with a resolvable show id is whole-show even when `showTmdbId` was
        // 0/absent — the B1 corrupt-row case.
        let hasSeason = (preselect.seasonNumber ?? 0) != 0
        let isWholeShow = !hasSeason && showTmdbId != nil && isWholeShowId(preselect.id)

        return Resolution(
            route: isWholeShow ? .seasonGrid : .tier,
            showTmdbId: showTmdbId
        )
    }

    /// Stamp the derived show id back onto a season-class preselect's numeric
    /// show id before it is seeded into the tier step (C5-Task-2 self-heal).
    /// Mirror of web `healTVPreselect`. Returns the healed show id to persist:
    /// the route's derived id wins when valid, else the item's own valid id,
    /// else the route's (possibly nil) id. A no-op when the item already has a
    /// valid (> 0) id and the route agrees, or when the route produced no id.
    public static func heal(itemShowTmdbId: Int?, route: Resolution?) -> Int? {
        guard let route else { return itemShowTmdbId }
        let healed: Int?
        if let rid = route.showTmdbId, rid > 0 {
            healed = rid
        } else if let iid = itemShowTmdbId, iid > 0 {
            healed = iid
        } else {
            healed = route.showTmdbId
        }
        return healed
    }

    /// The set of season numbers of `showTmdbId` that are ALREADY ranked, parsed
    /// from a collection of tv ranking ids (`tv_{show}_s{season}`). The season
    /// grid DISABLES these rows (web parity — a show's already-ranked season is
    /// not re-rankable from the grid; the user re-ranks it from the shelf). Ids
    /// for other shows / non-season shapes are ignored. Pure so the grid's
    /// disabled-state is testable without a live read.
    public static func rankedSeasonNumbers(
        showTmdbId: Int, rankedTVIds: some Sequence<String>
    ) -> Set<Int> {
        let prefix = "tv_\(showTmdbId)_s"
        var out = Set<Int>()
        for id in rankedTVIds where id.hasPrefix(prefix) {
            let seasonPart = id.dropFirst(prefix.count)
            guard !seasonPart.isEmpty, seasonPart.allSatisfy(\.isNumber),
                  let n = Int(seasonPart) else { continue }
            out.insert(n)
        }
        return out
    }

    /// Infer the vertical of a shelf/ranking id from its prefix: `tv_…` → tv,
    /// `ol_…` → book, everything else (`tmdb_…` or a bare numeric) → movie. Used
    /// by the shelf re-rank hand-off (C5-iOS Task 6) to route a `RankedItem` (which
    /// carries no `mediaType`) into the correct per-media ceremony. Pure/testable.
    public static func mediaForRankingId(_ id: String) -> RankMedia {
        if id.hasPrefix("tv_") { return .tv }
        if id.hasPrefix("ol_") { return .book }
        return .movie
    }

    /// Parse `(showId, season)` out of a season id `tv_{n}_s{k}` for the shelf
    /// re-rank path (the RankedItem carries the composite id but not the split
    /// fields). Returns nil for any non-season shape. Pure/testable.
    public static func showAndSeason(fromSeasonId id: String) -> (show: Int, season: Int)? {
        guard id.hasPrefix("tv_") else { return nil }
        let rest = id.dropFirst(3)
        guard let sRange = rest.range(of: "_s") else { return nil }
        let showDigits = rest[..<sRange.lowerBound]
        let seasonDigits = rest[sRange.upperBound...]
        guard !showDigits.isEmpty, showDigits.allSatisfy(\.isNumber),
              !seasonDigits.isEmpty, seasonDigits.allSatisfy(\.isNumber),
              let show = Int(showDigits), let season = Int(seasonDigits)
        else { return nil }
        return (show, season)
    }

    // MARK: - private

    /// True for a whole-show id `tv_{n}` (digits only, no `_s{k}` suffix).
    /// Mirror of web's `/^tv_\d+$/` test.
    private static func isWholeShowId(_ id: String) -> Bool {
        guard id.hasPrefix("tv_") else { return false }
        let rest = id.dropFirst(3)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
}
