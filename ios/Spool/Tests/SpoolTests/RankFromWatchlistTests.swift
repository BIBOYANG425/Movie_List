import XCTest
@testable import Spool

/// C3-iOS Part A, Task 4 — rank-from-watchlist with B5-CORRECTED semantics:
/// the watchlist bookmark is deleted ONLY after a confirmed rank save (the
/// `RankPersistence.save` write landed), never on failure or cancel, and never
/// for a plain add that never came from the watchlist queue.
///
/// Two layers under test, both network-free:
///
///  1. `RankPersistence.shouldRemoveBookmarkAfterRank(saveSucceeded:)` — the
///     pure decision gate, mirroring web's post-save removal condition (audit
///     finding B5). A trivial truth table, but it pins the contract.
///
///  2. `RankFromWatchlistCoordinator.finish(...)` — the flow-level orchestration.
///     All IO is injected as closures so we exercise every branch with fakes:
///     save success WITH a watchlist origin → remove called (right id/media) +
///     reload; save failure → remove NOT called; a plain add (no origin) →
///     remove NEVER called even on save success. The removal is fire-and-forget:
///     a failing remove never flips the reported rank outcome.
@MainActor
final class RankFromWatchlistTests: XCTestCase {

    // MARK: - 1. Pure decision gate (B5 truth table)

    func testShouldRemoveBookmarkWhenSaveSucceeded() {
        XCTAssertTrue(RankPersistence.shouldRemoveBookmarkAfterRank(saveSucceeded: true))
    }

    func testShouldNotRemoveBookmarkWhenSaveFailed() {
        XCTAssertFalse(RankPersistence.shouldRemoveBookmarkAfterRank(saveSucceeded: false))
    }

    // MARK: - fixtures

    private func fixtureMovie(id: String = "tmdb_603") -> Movie {
        Movie(id: id, title: "The Matrix", year: 1999, director: "The Wachowskis",
              genres: ["Sci-Fi"], voteAverage: 8.2)
    }

    private func fixtureItem(id: String = "tmdb_603") -> WatchlistItem {
        WatchlistItem(
            id: id, title: "The Matrix", year: "1999", posterUrl: "",
            mediaType: .movie, genres: ["Sci-Fi"],
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), director: "The Wachowskis"
        )
    }

    /// Build a coordinator with recording spies; override just the save outcome.
    private func makeCoordinator(
        saveSucceeds: Bool
    ) -> (RankFromWatchlistCoordinator, Spies) {
        let spies = Spies()
        let coord = RankFromWatchlistCoordinator(
            save: { _, _, _, _, _, _ in
                spies.saveCalls += 1
                return saveSucceeds
            },
            removeBookmark: { id, media in
                spies.removeCalls.append((id, media))
            },
            reloadWatchlist: {
                spies.reloadCalls += 1
            }
        )
        return (coord, spies)
    }

    private final class Spies {
        var saveCalls = 0
        var removeCalls: [(String, WatchlistMediaType)] = []
        var reloadCalls = 0
    }

    // MARK: - 2. save success WITH a watchlist origin → remove + reload

    func testFinishSaveSucceededWithOriginRemovesBookmarkAndReloads() async {
        let (coord, spies) = makeCoordinator(saveSucceeds: true)

        let outcome = await coord.finish(
            movie: fixtureMovie(), tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: fixtureItem()
        )

        XCTAssertTrue(outcome)                        // rank reported as saved
        XCTAssertEqual(spies.saveCalls, 1)
        XCTAssertEqual(spies.removeCalls.count, 1)
        XCTAssertEqual(spies.removeCalls.first?.0, "tmdb_603")   // right tmdb id
        XCTAssertEqual(spies.removeCalls.first?.1, .movie)       // right media
        XCTAssertEqual(spies.reloadCalls, 1)          // queue refreshed
    }

    // MARK: - 3. save FAILURE with an origin → bookmark stays

    func testFinishSaveFailedWithOriginDoesNotRemoveOrReload() async {
        let (coord, spies) = makeCoordinator(saveSucceeds: false)

        let outcome = await coord.finish(
            movie: fixtureMovie(), tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: fixtureItem()
        )

        XCTAssertFalse(outcome)
        XCTAssertEqual(spies.saveCalls, 1)
        XCTAssertTrue(spies.removeCalls.isEmpty)       // bookmark stays on failure
        XCTAssertEqual(spies.reloadCalls, 0)
    }

    // MARK: - 4. plain add (NO watchlist origin) → never removes anything

    func testFinishPlainAddNeverRemovesEvenOnSaveSuccess() async {
        let (coord, spies) = makeCoordinator(saveSucceeds: true)

        let outcome = await coord.finish(
            movie: fixtureMovie(), tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: nil                        // a plain search→rank
        )

        XCTAssertTrue(outcome)                          // still a successful rank
        XCTAssertEqual(spies.saveCalls, 1)
        XCTAssertTrue(spies.removeCalls.isEmpty)        // NOTHING deleted
        XCTAssertEqual(spies.reloadCalls, 0)
    }

    // MARK: - 5. fire-and-forget: a failing remove never fails the rank

    func testFinishRemoveFailureDoesNotFailTheRank() async {
        let spies = Spies()
        struct Boom: Error {}
        let coord = RankFromWatchlistCoordinator(
            save: { _, _, _, _, _, _ in spies.saveCalls += 1; return true },
            removeBookmark: { _, _ in spies.removeCalls.append(("boom", .movie)); throw Boom() },
            reloadWatchlist: { spies.reloadCalls += 1 }
        )

        let outcome = await coord.finish(
            movie: fixtureMovie(), tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: fixtureItem()
        )

        // The rank still reports success — a failed bookmark delete is swallowed
        // (loudly logged); the item self-heals via the owned-filter later. The
        // reload still fires so the tab reflects whatever DID persist.
        XCTAssertTrue(outcome)
        XCTAssertEqual(spies.removeCalls.count, 1)
        XCTAssertEqual(spies.reloadCalls, 1)
    }

    // MARK: - 6. stale-origin mismatch guard (defense-in-depth)

    /// Watchlist → tier → back → search detour: user initially tapped "Rank It"
    /// on movie X (origin = X), backed out to the search entry screen, and then
    /// picked a DIFFERENT movie Y. SpoolAppRoot clears origin on onPick, but the
    /// coordinator's own guard is the last line of defense. When origin.id != movie.id
    /// the remove must NOT fire, and the rank result must still be true.
    func testFinishStaleOriginMismatchSkipsRemoveAndStillReturnsSuccess() async {
        let (coord, spies) = makeCoordinator(saveSucceeds: true)

        // Origin = movie X (tmdb_603), actual ranked movie = movie Y (tmdb_27205)
        let movieY = fixtureMovie(id: "tmdb_27205")
        let originX = fixtureItem(id: "tmdb_603")

        let outcome = await coord.finish(
            movie: movieY, tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: originX
        )

        XCTAssertTrue(outcome, "rank outcome must be unaffected by the stale-origin skip")
        XCTAssertEqual(spies.saveCalls, 1)
        XCTAssertTrue(spies.removeCalls.isEmpty, "stale origin must NOT remove any bookmark")
        XCTAssertEqual(spies.reloadCalls, 0, "no reload when remove is skipped")
    }

    /// Matching-origin happy path: origin.id == movie.id → remove fires as normal.
    /// Pins that the guard does not break the expected watchlist-origin flow.
    func testFinishMatchingOriginStillRemovesBookmark() async {
        let (coord, spies) = makeCoordinator(saveSucceeds: true)

        let movie = fixtureMovie(id: "tmdb_603")
        let origin = fixtureItem(id: "tmdb_603")

        let outcome = await coord.finish(
            movie: movie, tier: .A, rank: 1, moods: [], line: "",
            watchlistOrigin: origin
        )

        XCTAssertTrue(outcome)
        XCTAssertEqual(spies.removeCalls.count, 1, "matching origin must trigger remove")
        XCTAssertEqual(spies.removeCalls.first?.0, "tmdb_603")
        XCTAssertEqual(spies.reloadCalls, 1)
    }

    // MARK: - 8. the watchlist→Movie mapping guards media + carries the seed

    /// Non-movie items must never map into a Movie / enter the ceremony — a
    /// data-integrity invariant (the ceremony is movie-only until C5). The
    /// mapper returns nil for tv/book.
    func testWatchlistMovieMappingRejectsNonMovie() {
        let tv = WatchlistItem(
            id: "tv_1399_s1", title: "GoT", year: "2011", posterUrl: "",
            mediaType: .tv, genres: [], addedAt: Date(),
            showTmdbId: 1399, seasonNumber: 1
        )
        XCTAssertNil(RankFromWatchlistCoordinator.movie(from: tv))
    }

    func testWatchlistMovieMappingUsesStableDigitSeed() {
        let item = fixtureItem(id: "tmdb_603")
        let movie = RankFromWatchlistCoordinator.movie(from: item)
        XCTAssertNotNil(movie)
        // 603 % 20 == 3 — the digit-parsing stableSeed, NOT a process-seeded
        // hashValue (which would reshuffle the poster palette every launch).
        XCTAssertEqual(movie?.seed, 3)
        // voteAverage is nil at mapping time; enrichment fills it before the
        // ceremony (the mapping itself never invents a rating).
        XCTAssertNil(movie?.voteAverage)
    }

    // MARK: - 9. tmdb-id parsing for the enrichment fetch

    func testNumericTmdbIdParsedFromMovieId() {
        XCTAssertEqual(RankFromWatchlistCoordinator.numericTmdbId("tmdb_603"), 603)
        XCTAssertEqual(RankFromWatchlistCoordinator.numericTmdbId("tmdb_27205"), 27205)
        XCTAssertNil(RankFromWatchlistCoordinator.numericTmdbId("ol_OL123W"))
        XCTAssertNil(RankFromWatchlistCoordinator.numericTmdbId("tmdb_"))
    }
}
