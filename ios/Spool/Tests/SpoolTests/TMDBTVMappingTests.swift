import XCTest
@testable import Spool

/// RED-first spec for the TV decode + mapping seams (search row, show detail,
/// season detail). Swift mirror of the TV mappers in `services/tmdbService.ts`
/// (`searchTVShows` row map, `getTVShowDetails`, `getTVSeasonDetails`).
///
/// Pure: decode a fixture payload with the internal Raw types, run the extracted
/// mapper, and assert the mapped shape — no network. Pins the load-bearing
/// parity facts the review checks: `tv_<id>` show-id mint, name/first-air-year,
/// poster URL composition, season-0 ("Specials") filtering, raw detail genres,
/// creators from `created_by`, and `episodeCount` derived from the season
/// `episodes` array length.
final class TMDBTVMappingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - search/tv row mapping

    func testSearchRowMintsTVIdAndMapsCoreFields() throws {
        let json = """
        {
          "id": 1396,
          "name": "Breaking Bad",
          "first_air_date": "2008-01-20",
          "poster_path": "/p.jpg",
          "backdrop_path": "/b.jpg",
          "genre_ids": [18, 80],
          "overview": "A chemistry teacher.",
          "vote_average": 8.9
        }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVRaw.self, from: Data(json.utf8))
        let show = TMDBService.mapTVSearchResult(raw)

        XCTAssertEqual(show.id, "tv_1396", "show id is the tv_<tmdbId> mint")
        XCTAssertEqual(show.tmdbId, 1396)
        XCTAssertEqual(show.name, "Breaking Bad")
        XCTAssertEqual(show.year, "2008")
        XCTAssertEqual(show.posterUrl, "\(TMDBService.imageBase)/p.jpg")
        XCTAssertEqual(show.backdropUrl, "\(TMDBService.imageBase)/b.jpg")
        XCTAssertEqual(show.genres, ["Drama", "Crime"])
        XCTAssertEqual(show.overview, "A chemistry teacher.")
        // Search results carry no season/status/creator data.
        XCTAssertEqual(show.seasonCount, 0)
        XCTAssertEqual(show.status, "")
        XCTAssertEqual(show.creators, [])
        XCTAssertEqual(show.voteAverage, 8.9)
        XCTAssertNil(show.seasons)
    }

    func testSearchRowMissingFirstAirDateYieldsEmDashYear() throws {
        let json = """
        { "id": 1, "name": "Untitled", "poster_path": "/p.jpg" }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVRaw.self, from: Data(json.utf8))
        let show = TMDBService.mapTVSearchResult(raw)
        XCTAssertEqual(show.year, "—")
        XCTAssertEqual(show.overview, "")
        XCTAssertNil(show.voteAverage)
        XCTAssertNil(show.backdropUrl)
    }

    // MARK: - tv/{id} detail mapping

    func testDetailFiltersSeasonZeroSpecials() throws {
        let json = """
        {
          "id": 1396,
          "name": "Breaking Bad",
          "first_air_date": "2008-01-20",
          "poster_path": "/p.jpg",
          "overview": "ov",
          "status": "Ended",
          "vote_average": 8.9,
          "genres": [{"name": "Drama"}, {"name": "Crime"}],
          "created_by": [{"name": "Vince Gilligan"}],
          "seasons": [
            {"season_number": 0, "name": "Specials", "poster_path": "/sp.jpg", "episode_count": 5, "air_date": "2009-02-01"},
            {"season_number": 1, "name": "Season 1", "poster_path": "/s1.jpg", "episode_count": 7, "air_date": "2008-01-20"},
            {"season_number": 2, "name": "Season 2", "poster_path": null, "episode_count": 13, "air_date": "2009-03-08"}
          ]
        }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVDetailRaw.self, from: Data(json.utf8))
        let show = TMDBService.mapTVDetail(raw)

        XCTAssertEqual(show.id, "tv_1396")
        XCTAssertEqual(show.year, "2008")
        XCTAssertEqual(show.status, "Ended")
        // Raw TMDB detail genre names (not id-mapped).
        XCTAssertEqual(show.genres, ["Drama", "Crime"])
        XCTAssertEqual(show.creators, ["Vince Gilligan"])

        // Season 0 "Specials" is filtered; only numbered seasons remain.
        let seasons = try XCTUnwrap(show.seasons)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2])
        XCTAssertEqual(show.seasonCount, 2, "seasonCount reflects the filtered count")
        XCTAssertEqual(seasons[0].name, "Season 1")
        XCTAssertEqual(seasons[0].posterUrl, "\(TMDBService.imageBase)/s1.jpg")
        XCTAssertEqual(seasons[0].episodeCount, 7)
        XCTAssertEqual(seasons[0].airDate, "2008-01-20")
        // Posterless season maps to a nil posterUrl (not an empty-string URL).
        XCTAssertNil(seasons[1].posterUrl)
    }

    func testDetailDefaultsWhenFieldsAbsent() throws {
        let json = """
        { "id": 7, "name": "Bare Show" }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVDetailRaw.self, from: Data(json.utf8))
        let show = TMDBService.mapTVDetail(raw)
        XCTAssertEqual(show.year, "—")
        XCTAssertEqual(show.overview, "")
        XCTAssertEqual(show.status, "")
        XCTAssertEqual(show.genres, [])
        XCTAssertEqual(show.creators, [])
        XCTAssertEqual(show.seasonCount, 0)
        XCTAssertEqual(show.seasons, [])
        XCTAssertNil(show.posterUrl)
        XCTAssertNil(show.voteAverage)
    }

    // MARK: - tv/{id}/season/{n} mapping

    func testSeasonDetailDerivesEpisodeCountFromEpisodesArray() throws {
        let json = """
        {
          "id": 3572,
          "season_number": 1,
          "name": "Season 1",
          "poster_path": "/s1.jpg",
          "air_date": "2008-01-20",
          "overview": "ov",
          "episodes": [{}, {}, {}, {}, {}, {}, {}]
        }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVSeasonRaw.self, from: Data(json.utf8))
        let season = TMDBService.mapTVSeason(raw, showId: 1396, requestedSeason: 1, showName: "Breaking Bad")

        XCTAssertEqual(season.id, 3572)
        XCTAssertEqual(season.showTmdbId, 1396)
        XCTAssertEqual(season.seasonNumber, 1)
        XCTAssertEqual(season.name, "Season 1")
        XCTAssertEqual(season.showName, "Breaking Bad")
        XCTAssertEqual(season.posterUrl, "\(TMDBService.imageBase)/s1.jpg")
        // episodeCount is the length of the episodes array (web parity).
        XCTAssertEqual(season.episodeCount, 7)
        XCTAssertEqual(season.airDate, "2008-01-20")
        XCTAssertEqual(season.overview, "ov")
    }

    func testSeasonDetailFallsBackToSeasonNumberNameAndZeroEpisodes() throws {
        // No "name", no "episodes" → name defaults to "Season {requested}",
        // episodeCount defaults to 0.
        let json = """
        { "id": 10, "season_number": 4 }
        """
        let raw = try decoder.decode(TMDBService.TMDBTVSeasonRaw.self, from: Data(json.utf8))
        let season = TMDBService.mapTVSeason(raw, showId: 99, requestedSeason: 4, showName: "")
        XCTAssertEqual(season.name, "Season 4")
        XCTAssertEqual(season.episodeCount, 0)
        XCTAssertEqual(season.overview, "")
        XCTAssertNil(season.posterUrl)
        XCTAssertNil(season.airDate)
    }

    // MARK: - query builder

    func testTVSearchQueryTargetsSearchTVPathWithEncodedParams() {
        let path = TMDBService.buildTVSearchQuery(term: "the office")
        XCTAssertTrue(path.hasPrefix("search/tv?"), "targets the search/tv endpoint")
        XCTAssertTrue(path.contains("query=the%20office"), "query is percent-encoded")
        XCTAssertTrue(path.contains("page=1"))
        XCTAssertTrue(path.contains("include_adult=false"))
    }

    func testTVSearchQueryForcesPlusToPercent2B() {
        // Same `+`→`%2B` fix as the movie builder so a "9+1"-style title survives
        // the proxy's URLSearchParams decode.
        let path = TMDBService.buildTVSearchQuery(term: "9+1")
        XCTAssertTrue(path.contains("query=9%2B1"), "raw + must be %2B, got: \(path)")
        XCTAssertFalse(path.contains("query=9+1"))
    }
}
