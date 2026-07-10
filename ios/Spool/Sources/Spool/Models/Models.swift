import Foundation

public enum Tier: String, CaseIterable, Identifiable, Sendable, Codable {
    case S, A, B, C, D
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .S: return "masterpiece"
        case .A: return "loved it"
        case .B: return "good"
        case .C: return "meh"
        case .D: return "no"
        }
    }

    public var sub: String {
        switch self {
        case .S: return "obsessed. tell everyone."
        case .A: return "would rewatch."
        case .B: return "glad i watched."
        case .C: return "wouldn't recommend."
        case .D: return "get it away from me."
        }
    }
}

/// Which vertical a rankable `Movie` actually belongs to. The DISCRIMINATOR
/// that makes the ceremony media-generic (C5-iOS Task 5): the ceremony screens
/// and `RankPersistence.save` read this to pick the right `RankingMedia`
/// payload, stub decision, quick-entry gate, and H2H pool table. Defaults to
/// `.movie` on `Movie.init`, so every pre-C5 movie call site (search, watchlist,
/// discover, re-rank, fixtures) stays a movie with no code change. Task 6's
/// tv/book search + season UI sets it to `.tv`/`.book` when it builds the
/// rankable item.
public enum RankMedia: String, Sendable, Hashable, CaseIterable {
    case movie, tv, book

    /// The `media:` string the parameterized reads / RPCs expect
    /// (`RankingRepository.rankingsTable(forType:)` / `pMedia(forType:)`),
    /// keeping the H2H pool read SAME-MEDIA (a tv rank compares only against
    /// tv_rankings, etc.).
    public var mediaParam: String { rawValue }
}

public struct Movie: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var year: Int
    public var director: String
    public var seed: Int
    public var rec: Bool
    public var genres: [String]
    public var posterUrl: String?
    /// TMDB `vote_average` on a 0-10 scale. Feeds the ranking engine's
    /// prediction signal (weight 0.35) and is the ONLY signal used for
    /// new users below NEW_USER_THRESHOLD — web carries it end-to-end;
    /// iOS was dropping it until this field existed, which meant the
    /// predicted score defaulted to the tier midpoint for every new
    /// user on iOS.
    public var voteAverage: Double?

    // MARK: - Media awareness (C5-iOS Task 5)
    // These make the ONE rankable model media-generic without a per-media type
    // explosion. All optional / defaulted → every existing movie call site
    // compiles unchanged and behaves as a movie. Task 6 populates them when it
    // builds a tv-season / book rankable from the search + season UI.

    /// Which vertical this item ranks into. `.movie` by default — the pre-C5
    /// behavior. `RankPersistence.save` derives `RankingMedia` from this, and the
    /// H2H pool read keys its `media:` param off it (same-media pool).
    public var mediaType: RankMedia

    // tv-season fields (only read when `mediaType == .tv`). `showTmdbId` +
    // `seasonNumber` are the `tv_rankings` NOT-NULL identity columns; `movie.id`
    // itself is the composite `tv_{showId}_s{n}` id (the stub/ranking `tmdb_id`).
    public var showTmdbId: Int?
    public var seasonNumber: Int?
    /// The season's own title line (e.g. "Season 3" / a named-season title);
    /// shown under the SHOW name on the ceremony cards for a tv item.
    public var seasonTitle: String?
    /// TV creator(s), the `.tv` attribution shown where a movie shows director.
    public var creator: String?
    public var episodeCount: Int?

    // book fields (only read when `mediaType == .book`). `movie.id` is the
    // `ol_{workKey}` id. `author` is the `.book` attribution shown where a movie
    // shows director.
    public var author: String?
    public var pageCount: Int?
    public var isbn: String?
    public var olWorkKey: String?
    /// OpenLibrary `ratings_average` (0-5). The book ceremony seeds the engine's
    /// global score from THIS (never TMDB `voteAverage`, which is nil for ol_
    /// ids). `RankH2HScreen` maps it to a 0-10 `globalScore` (×2), mirroring
    /// web (`ratings_average * 2`).
    public var olRatingsAverage: Double?

    public init(id: String, title: String, year: Int, director: String,
                seed: Int = 0, rec: Bool = false, genres: [String] = [],
                posterUrl: String? = nil, voteAverage: Double? = nil,
                mediaType: RankMedia = .movie,
                showTmdbId: Int? = nil, seasonNumber: Int? = nil,
                seasonTitle: String? = nil, creator: String? = nil,
                episodeCount: Int? = nil,
                author: String? = nil, pageCount: Int? = nil, isbn: String? = nil,
                olWorkKey: String? = nil, olRatingsAverage: Double? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.director = director
        self.seed = seed
        self.rec = rec
        self.genres = genres
        self.posterUrl = posterUrl
        self.voteAverage = voteAverage
        self.mediaType = mediaType
        self.showTmdbId = showTmdbId
        self.seasonNumber = seasonNumber
        self.seasonTitle = seasonTitle
        self.creator = creator
        self.episodeCount = episodeCount
        self.author = author
        self.pageCount = pageCount
        self.isbn = isbn
        self.olWorkKey = olWorkKey
        self.olRatingsAverage = olRatingsAverage
    }
}

public extension Movie {

    /// The subtitle attribution the ceremony cards show for THIS media: the
    /// creator for a tv season, the author for a book, else the director.
    /// Mirrors `RankingRow.attribution` (`director ?? creator ?? author`) but
    /// media-keyed so a movie with an incidental non-nil `creator` still shows
    /// its director. Never empty — falls back through to `director`.
    var attribution: String {
        switch mediaType {
        case .tv:   return (creator?.isEmpty == false ? creator! : director)
        case .book: return (author?.isEmpty == false ? author! : director)
        case .movie: return director
        }
    }

    /// The engine's global-score seed for THIS media. TV seeds from the show's
    /// TMDB `vote_average` (Task 3 `tvShowGlobalScore`, carried on `voteAverage`);
    /// a book seeds from OpenLibrary `ratings_average` scaled 0-5 → 0-10 (×2,
    /// web parity — NEVER TMDB `voteAverage` for an ol_ id); a movie keeps its
    /// TMDB `voteAverage`. Pure so the ceremony seam is unit-testable.
    var rankGlobalScore: Double? {
        switch mediaType {
        case .book: return olRatingsAverage.map { $0 * 2 }
        case .tv, .movie: return voteAverage
        }
    }

    /// Build the correct per-media `RankingInsert` for this item. The ONE seam
    /// `RankPersistence.save` uses so a movie can never mint a tv/book row (and
    /// vice-versa). For `.tv` the required `show_tmdb_id`/`season_number` are
    /// pulled from `showTmdbId`/`seasonNumber` (falling back to 0 only if a
    /// malformed tv item somehow reached here — the DB NOT-NULL still holds a
    /// value); `director` only reaches the movie payload.
    func rankingInsert(
        year: String?, genres: [String], director: String?,
        tier: Tier, rankPosition: Int, notes: String?,
        watchedWithUserIds: [UUID]? = nil
    ) -> RankingInsert {
        switch mediaType {
        case .movie:
            return .movie(
                tmdbId: id, title: title, year: year, posterURL: posterUrl,
                genres: genres, director: director, tier: tier,
                rankPosition: rankPosition, notes: notes,
                watchedWithUserIds: watchedWithUserIds)
        case .tv:
            return .tv(
                tmdbId: id, title: title, year: year, posterURL: posterUrl,
                genres: genres, showTmdbId: showTmdbId ?? 0,
                season: seasonNumber ?? 0, seasonTitle: seasonTitle,
                creator: creator, episodeCount: episodeCount, tier: tier,
                rankPosition: rankPosition, notes: notes,
                watchedWithUserIds: watchedWithUserIds)
        case .book:
            return .book(
                tmdbId: id, title: title, year: year, posterURL: posterUrl,
                genres: genres, author: author, pageCount: pageCount, isbn: isbn,
                olWorkKey: olWorkKey, olRatingsAverage: olRatingsAverage,
                tier: tier, rankPosition: rankPosition, notes: notes,
                watchedWithUserIds: watchedWithUserIds)
        }
    }
}

public extension Movie {

    /// Build the rankable `Movie` for a chosen TV SEASON, following T5's tv
    /// construction conventions (C5-iOS Task 6). `movie.id` is the composite
    /// `tv_{showId}_s{n}` stub/ranking id; `showTmdbId`/`seasonNumber` are the
    /// REAL `tv_rankings` identity columns; `voteAverage` carries the show's
    /// global score (Task 3 `tvShowGlobalScore`) so the ceremony seeds the
    /// engine from it via `rankGlobalScore`. `genres` are the show's genres
    /// already normalized via `TMDBTVGenres.normalize`; `title` is the SHOW name
    /// (`seasonTitle` carries the season line). `creator` is the `.tv`
    /// attribution. `year` parses the season's air date, falling back to the
    /// show's year, else 0.
    ///
    /// Pure so the season-selection wiring is unit-testable without a live fetch.
    static func tvSeason(
        show: TMDBTVShow,
        season: TMDBTVSeason,
        showGlobalScore: Double?
    ) -> Movie {
        let id = WatchlistContract.tvSeasonId(showId: show.tmdbId, season: season.seasonNumber)
        // Season air-date year → else show year → else 0.
        let seasonYear = season.airDate.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil }
        let year = seasonYear ?? Int(show.year) ?? 0
        let creator = show.creators.first
        return Movie(
            id: id,
            title: show.name,
            year: year,
            director: creator ?? "—",
            seed: Movie.stableSeed(id),
            genres: TMDBTVGenres.normalize(show.genres),
            posterUrl: season.posterUrl ?? show.posterUrl,
            voteAverage: showGlobalScore,
            mediaType: .tv,
            showTmdbId: show.tmdbId,
            seasonNumber: season.seasonNumber,
            seasonTitle: season.name,
            creator: creator,
            episodeCount: season.episodeCount
        )
    }

    /// Build the rankable `Movie` for a chosen BOOK, following T5's book
    /// construction conventions (C5-iOS Task 6). `movie.id` is the `ol_{workKey}`
    /// id; `author` is the `.book` attribution; `olRatingsAverage` seeds the
    /// engine (×2) — `voteAverage` stays nil (never TMDB for an ol_ id). `genres`
    /// come pre-normalized from the OpenLibrary client. Pure / testable.
    static func book(_ book: OpenLibraryBook) -> Movie {
        Movie(
            id: book.id,
            title: book.title,
            year: Int(book.year) ?? 0,
            director: book.author,
            seed: Movie.stableSeed(book.id),
            genres: book.genres,
            posterUrl: book.posterUrl.isEmpty ? nil : book.posterUrl,
            voteAverage: nil,
            mediaType: .book,
            author: book.author,
            pageCount: book.pageCount,
            isbn: book.isbn,
            olWorkKey: book.olWorkKey,
            olRatingsAverage: book.olRatingsAverage
        )
    }

    /// Deterministic 0-999 poster-palette seed, stable across launches — mirrors
    /// `RankEntryScreen.stableSeed`. Parses a trailing integer from the id when
    /// present, else a djb2 digest. NEVER `hashValue` (process-seeded).
    static func stableSeed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }
}

public struct Friend: Identifiable, Hashable, Sendable {
    public var id: String { handle }
    public let handle: String
    public let name: String
    public let twin: Int
    /// Supabase user ID when the friend came from a real follow edge.
    /// `nil` for fixture friends — callers that need DB access should
    /// treat `nil` as "preview only, don't fetch."
    public let userID: UUID?

    public init(handle: String, name: String, twin: Int, userID: UUID? = nil) {
        self.handle = handle
        self.name = name
        self.twin = twin
        self.userID = userID
    }
}

public struct FeedActor: Hashable, Sendable {
    public let handle: String
    public let when: String
}

public enum FeedItemKind: Sendable, Hashable {
    case rank(title: String, tier: Tier, line: String, moods: [String], seed: Int, stubNo: String)
    case shuffle(line: String, titles: [ShuffleTitle])
    case milestone(headline: String, sub: String)
}

public struct ShuffleTitle: Hashable, Sendable {
    public let title: String
    public let seed: Int
    public let direction: ShuffleDir
}

public enum ShuffleDir: Sendable, Hashable { case up, down, none }

public struct FeedItem: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let actor: FeedActor
    public let kind: FeedItemKind
    public let likes: Int
    public let comments: Int
    public let seen: String
}

public struct WatchedDay: Identifiable, Hashable, Sendable {
    public var id: Int { day }
    public let day: Int
    public let tier: Tier
    public let title: String
    /// Year and month of the watched_date so detail screens can format the
    /// full "APR · 18 · 2026" string instead of hardcoding one. Optional to
    /// keep fixture constructors ergonomic.
    public let year: Int?
    public let month: Int?

    public init(day: Int, tier: Tier, title: String, year: Int? = nil, month: Int? = nil) {
        self.day = day
        self.tier = tier
        self.title = title
        self.year = year
        self.month = month
    }
}

public struct TwinEntry: Hashable, Sendable {
    public let t: String
    public let s: Int
}

public struct TwinFight: Hashable, Sendable {
    public let t: String
    public let s: Int
    public let yours: Tier
    public let theirs: Tier
}

public struct RankedStub: Hashable, Sendable {
    public let title: String
    public let year: Int
    public let director: String
    public let tier: Tier
    public let seed: Int
}

public struct TopFourEntry: Hashable, Sendable {
    public let title: String
    public let seed: Int
}

public struct CurrentUser: Sendable {
    public let handle: String
    public let name: String
    public let stubs: Int
    public let pronouns: String
    public let city: String
    public let bioLine1: String
    public let bioLine2: String
}
