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

public struct Movie: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var year: Int
    public var director: String
    public var seed: Int
    public var rec: Bool
    public var genres: [String]
    public var posterUrl: String?

    public init(id: String, title: String, year: Int, director: String,
                seed: Int = 0, rec: Bool = false, genres: [String] = [],
                posterUrl: String? = nil) {
        self.id = id
        self.title = title
        self.year = year
        self.director = director
        self.seed = seed
        self.rec = rec
        self.genres = genres
        self.posterUrl = posterUrl
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
