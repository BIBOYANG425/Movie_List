import Foundation

// Types used by the ranking algorithm. Kept in Algorithm/ to match the
// web's `types.ts` ranking additions without polluting view models.

public enum Bracket: String, Codable, Sendable, CaseIterable {
    case commercial = "Commercial"
    case artisan    = "Artisan"
    case documentary = "Documentary"
    case animation  = "Animation"
}

public enum EnginePhase: String, Codable, Sendable {
    case prediction
    case probe
    case escalation
    case crossGenre = "cross_genre"
    case settlement
    case complete
    case binarySearch = "binary_search"
}

public struct ScoreRange: Sendable, Equatable {
    public let min: Double
    public let max: Double
    public init(min: Double, max: Double) { self.min = min; self.max = max }
}

/// Full ranked item used by the algorithm. Separate from fixture `Movie`
/// because the algorithm needs tier + rank + genres + bracket.
public struct RankedItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var year: Int?
    public var director: String
    public var genres: [String]
    public var tier: Tier
    public var rank: Int
    public var bracket: Bracket?
    public var globalScore: Double?
    public var seed: Int
    public var posterUrl: String?

    public init(id: String, title: String, year: Int? = nil, director: String = "—",
                genres: [String] = [], tier: Tier, rank: Int,
                bracket: Bracket? = nil, globalScore: Double? = nil, seed: Int = 0,
                posterUrl: String? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.director = director
        self.genres = genres
        self.tier = tier
        self.rank = rank
        self.bracket = bracket
        self.globalScore = globalScore
        self.seed = seed
        self.posterUrl = posterUrl
    }
}

public struct PredictionSignals: Sendable, Equatable {
    public var genreAffinity: Double?
    public var globalScore: Double?
    public var bracketAffinity: Double?
    public var totalRanked: Int

    public init(genreAffinity: Double? = nil, globalScore: Double? = nil,
                bracketAffinity: Double? = nil, totalRanked: Int) {
        self.genreAffinity = genreAffinity
        self.globalScore = globalScore
        self.bracketAffinity = bracketAffinity
        self.totalRanked = totalRanked
    }
}

public struct ComparisonRequest: Sendable, Equatable {
    public let movieA: RankedItem
    public let movieB: RankedItem
    public let question: String
    public let phase: EnginePhase
    public let round: Int
}

public enum EngineResult: Sendable, Equatable {
    case comparison(ComparisonRequest)
    case done(finalRank: Int, finalScore: Double)
}

// MARK: Constants (mirror `constants.ts`)

public enum SpoolConstants {
    public static let tierScoreRanges: [Tier: ScoreRange] = [
        .S: .init(min: 9.0, max: 10.0),
        .A: .init(min: 7.0, max: 8.9),
        .B: .init(min: 5.0, max: 6.9),
        .C: .init(min: 3.0, max: 4.9),
        .D: .init(min: 0.1, max: 2.9),
    ]

    public static let newUserThreshold: Int = 15

    public static let tierComparisonPrompts: [Tier: String] = [
        .S: "Which one changed something in you?",
        .A: "Which experience stayed with you longer?",
        .B: "Which one did you enjoy more in the moment?",
        .C: "Which one disappointed you less?",
        .D: "Which one was more forgettable?",
    ]

    public static let genreComparisonPrompts: [String: String] = [
        "Horror":      "Which one unsettled you more?",
        "Romance":     "Which one made you feel more?",
        "Comedy":      "Which one actually made you laugh?",
        "Drama":       "Which one hit closer to home?",
        "Thriller":    "Which one kept you more on edge?",
        "Sci-Fi":      "Which world pulled you in deeper?",
        "Animation":   "Which one moved you more?",
        "Documentary": "Which one changed how you see things?",
    ]

    static let commercialSignalGenres: Set<String> = [
        "Action", "Adventure", "Sci-Fi", "Fantasy", "Horror",
        "Thriller", "Comedy", "Family", "Animation", "TV Movie",
    ]
}
