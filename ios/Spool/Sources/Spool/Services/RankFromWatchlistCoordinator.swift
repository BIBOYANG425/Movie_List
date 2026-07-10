import Foundation

/// Orchestrates the rank-from-watchlist flow's TAIL — the confirmed-save →
/// bookmark-removal step (C3-iOS Part A, Task 4) with the B5-CORRECTED
/// semantics. Extracted from `SpoolAppRoot`'s view body so the decision logic
/// ("did the rank save land? did it originate from the watchlist? then, and
/// ONLY then, delete the bookmark") is unit-testable with injected closures
/// instead of buried in a SwiftUI `onFinish`.
///
/// ── The B5 contract (each branch has a test) ────────────────────────────────
///
///  * Save SUCCEEDED and the rank ORIGINATED from a watchlist item →
///    fire-and-forget `removeBookmark`, then `reloadWatchlist` so the ranked
///    item disappears from the queue.
///  * Save FAILED (or preview-queued) → the bookmark STAYS; the user can rank
///    it again. `RankPersistence.save` returns `false` for both.
///  * A PLAIN add (no `watchlistOrigin`) → NOTHING is ever removed, even on a
///    successful save. A search→rank must never delete a bookmark.
///  * The removal NEVER gates the rank outcome: a failing `removeBookmark` is
///    logged loudly and swallowed — the item self-heals via the owned-filter on
///    the next load.
///
/// All IO is injected (mirrors `WatchlistModel` / `JournalListModel`): the
/// production wiring in `SpoolAppRoot` binds `save` to `RankPersistence.save`,
/// `removeBookmark` to `WatchlistRepository.remove`, and `reloadWatchlist` to
/// the watchlist tab's reload seam.
///
/// Header last reviewed: 2026-07-10
///
/// Defense-in-depth: `finish` guards the ranked id against the origin before
/// removing the bookmark. A stale origin (from a Watchlist→tier→back→search
/// detour) logs loudly and skips the remove without affecting the rank result.
/// The match accepts an exact id OR the season-of-this-show prefix
/// (`origin.id + "_s"`) so a whole-show TV bookmark ranked through the season
/// grid still clears its bookmark (audit §3.9, C5-iOS Task 6).
@MainActor
public final class RankFromWatchlistCoordinator {

    /// `RankPersistence.save` — returns whether a CONFIRMED write landed. The
    /// argument order matches `RankPersistence.save`'s positional call.
    public typealias Save = (
        _ movie: Movie, _ tier: Tier, _ rank: Int,
        _ moods: [String], _ line: String, _ writeJournalQuickEntry: Bool
    ) async -> Bool
    /// `WatchlistRepository.remove(tmdbId:media:)` — throws on failure so the
    /// coordinator can log-and-swallow (fire-and-forget).
    public typealias RemoveBookmark = (_ tmdbId: String, _ media: WatchlistMediaType) async throws -> Void
    /// Refresh the watchlist tab so the just-ranked item drops out of the queue.
    public typealias ReloadWatchlist = () async -> Void

    private let save: Save
    private let removeBookmark: RemoveBookmark
    private let reloadWatchlist: ReloadWatchlist

    public init(
        save: @escaping Save,
        removeBookmark: @escaping RemoveBookmark,
        reloadWatchlist: @escaping ReloadWatchlist
    ) {
        self.save = save
        self.removeBookmark = removeBookmark
        self.reloadWatchlist = reloadWatchlist
    }

    /// Commit the rank, then apply the B5-corrected bookmark-removal gate.
    /// Returns whether the rank itself was saved (the caller uses this only for
    /// diagnostics / tests — the flow already dismisses regardless, matching the
    /// existing fire-and-forget `onFinish`).
    @discardableResult
    public func finish(
        movie: Movie,
        tier: Tier,
        rank: Int,
        moods: [String],
        line: String,
        writeJournalQuickEntry: Bool = true,
        watchlistOrigin: WatchlistItem?
    ) async -> Bool {
        let saved = await save(movie, tier, rank, moods, line, writeJournalQuickEntry)

        // B5 gate: only a CONFIRMED save AND a real watchlist origin removes the
        // bookmark. A plain add (origin == nil) never deletes anything.
        guard RankPersistence.shouldRemoveBookmarkAfterRank(saveSucceeded: saved),
              let origin = watchlistOrigin else {
            return saved
        }

        // Defense-in-depth: if a stale origin survived a Watchlist → tier →
        // back → search detour and the user ranked a DIFFERENT item, the ids
        // diverge. Removing origin.id here would delete the wrong bookmark and
        // leave the original item in neither list — the exact data-loss class
        // C3 Task 4 prevents. Log loudly and skip the remove; the rank result
        // is unaffected.
        //
        // WHOLE-SHOW IDENTITY (audit §3.9, C5-iOS Task 6): a whole-show TV
        // bookmark (`tv_{n}`) is ranked through the season grid, so the ranked
        // Movie carries the SEASON id (`tv_{n}_s{k}`) — a DIFFERENT id than the
        // origin, yet the SAME item. Web removes the whole-show bookmark on such
        // a rank; iOS must too. So the identity match accepts either an exact id
        // match OR the season-of-this-show prefix (`origin.id + "_s"`). A movie/
        // book origin never has the `_s` suffix so this widens nothing for them,
        // and a genuinely stale origin (a different show / a movie) still fails
        // both clauses and is correctly skipped.
        guard Self.originMatchesRankedItem(originId: origin.id, rankedId: movie.id) else {
            NSLog("[RankFromWatchlist] stale origin detected — origin.id '\(origin.id)' does not match ranked id '\(movie.id)'; skipping bookmark remove to prevent data loss")
            return saved
        }

        // Fire-and-forget: a failed remove is logged, never fatal — the owned-
        // filter drops the now-ranked item on the next watchlist load anyway.
        do {
            try await removeBookmark(origin.id, origin.mediaType)
        } catch {
            NSLog("[RankFromWatchlistCoordinator] bookmark remove failed for \(origin.id) — self-heals on next load: \(error)")
        }
        // Refresh regardless of the remove's fate so the tab reflects reality.
        await reloadWatchlist()
        return saved
    }

    // MARK: - Pure identity helper (audit §3.9)

    /// Whether a ranked item's id belongs to the same watchlist origin, so the
    /// origin's bookmark should be removed after a confirmed save. Matches an
    /// EXACT id (movie/book/season-of-a-season bookmark) OR the season-of-this-
    /// show prefix (`origin.id + "_s"`) so a WHOLE-SHOW TV bookmark (`tv_{n}`)
    /// ranked through the season grid (producing `tv_{n}_s{k}`) still clears the
    /// bookmark — web parity. Pure so the whole-show/stale matrix is testable.
    ///
    /// A movie/book origin id never gains an `_s` suffix, so this widens nothing
    /// for them. A genuinely stale origin (different show, or a movie whose id
    /// isn't the ranked id) fails both clauses and is correctly rejected.
    static func originMatchesRankedItem(originId: String, rankedId: String) -> Bool {
        originId == rankedId || rankedId.hasPrefix(originId + "_s")
    }

    // MARK: - Pure mapping helpers (WatchlistItem → Movie)

    /// Map a MOVIE watchlist item into the `Movie` the ceremony consumes.
    /// Returns `nil` for tv/book items — a data-integrity invariant: only movies
    /// may enter the movie-only rank ceremony (C3 Global Constraints, Task 3
    /// review binding condition 1). `voteAverage` is nil here; the caller
    /// enriches it from TMDB before presenting (Task 3 review binding
    /// condition 2). `seed` uses the digit-parsing `stableSeed` so the poster
    /// palette is stable across launches (not a process-seeded `hashValue`).
    public static func movie(from item: WatchlistItem) -> Movie? {
        guard item.mediaType == .movie else { return nil }
        return Movie(
            id: item.id,
            title: item.title,
            year: Int(item.year) ?? 0,
            director: item.director ?? "—",
            seed: stableSeed(item.id),
            genres: item.genres,
            posterUrl: item.posterUrl.isEmpty ? nil : item.posterUrl
        )
    }

    /// Parse the numeric TMDB id out of a movie watchlist id (`tmdb_{n}`) for the
    /// vote_average enrichment fetch. Returns `nil` for non-movie ids or a
    /// malformed `tmdb_` with no digits.
    public static func numericTmdbId(_ id: String) -> Int? {
        guard id.hasPrefix("tmdb_") else { return nil }
        let digits = id.dropFirst("tmdb_".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// Deterministic 0-19 poster-palette seed, stable across launches. Mirrors
    /// `WatchlistCard.stableSeed` / `StubsScreen.stableSeed`: parse a trailing
    /// integer from the id when possible, else a djb2 digest. NEVER `hashValue`
    /// (process-seeded → reshuffles the palette every cold launch).
    static func stableSeed(_ id: String) -> Int {
        if let digits = id.split(separator: "_").last.flatMap({ Int($0.filter(\.isNumber)) }) {
            return abs(digits) % 20
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 20)
    }
}
