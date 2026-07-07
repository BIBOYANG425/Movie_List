import Foundation

/// Fixtures mirroring `hifi/data.jsx`. Swap these for Supabase repository
/// calls when wiring the real backend.
public enum SpoolData {
    public static let me = CurrentUser(
        handle: "@yurui", name: "yurui", stubs: 127,
        pronouns: "she/her", city: "bk",
        bioLine1: "crying in public is a genre.",
        bioLine2: "nyc · always cold · mostly a24."
    )

    public static let friends: [Friend] = [
        .init(handle: "@mei",  name: "mei",  twin: 72),
        .init(handle: "@jay",  name: "jay",  twin: 64),
        .init(handle: "@ana",  name: "ana",  twin: 58),
        .init(handle: "@theo", name: "theo", twin: 41),
    ]

    public static let sTier: [Movie] = [
        .init(id: "itmfl",       title: "In the Mood for Love",         year: 2000, director: "wong kar-wai",  seed: 2),
        .init(id: "portrait",    title: "Portrait of a Lady on Fire",   year: 2019, director: "céline sciamma", seed: 7),
        .init(id: "moonlight",   title: "Moonlight",                     year: 2016, director: "barry jenkins", seed: 4),
        .init(id: "paris-texas", title: "Paris, Texas",                  year: 1984, director: "wim wenders",   seed: 8),
    ]

    public static let subject = Movie(
        id: "past-lives", title: "Past Lives", year: 2023,
        director: "celine song", seed: 0
    )

    public static let searchResults: [Movie] = [
        .init(id: "past-lives", title: "Past Lives", year: 2023, director: "celine song", seed: 0, rec: true),
        .init(id: "past-tense", title: "Past Tense", year: 2024, director: "unknown",     seed: 3),
        .init(id: "passages",   title: "Passages",   year: 2023, director: "ira sachs",   seed: 7),
    ]

    public static let moods: [String] = [
        "tender","devastating","slow burn","thrilling","nostalgic","weird","funny",
        "quiet","romantic","scary","messy","perfect","lonely","horny","transcendent",
    ]

    public static let recent: [RankedStub] = [
        .init(title: "Past Lives",          year: 2023, director: "celine song", tier: .S, seed: 0),
        .init(title: "Challengers",         year: 2024, director: "luca g.",     tier: .A, seed: 5),
        .init(title: "La Chimera",          year: 2023, director: "rohrwacher",  tier: .A, seed: 6),
        .init(title: "Drive My Car",        year: 2021, director: "hamaguchi",   tier: .S, seed: 9),
        .init(title: "The Zone of Interest", year: 2023, director: "glazer",     tier: .B, seed: 1),
        .init(title: "Poor Things",         year: 2023, director: "lanthimos",   tier: .A, seed: 3),
    ]

    public static let feed: [FeedItem] = [
        FeedItem(
            actor: .init(handle: "@mei", when: "2h"),
            kind: .rank(title: "Past Lives", tier: .S,
                        line: "cried on the 6 train.",
                        moods: ["tender","devastating"],
                        seed: 0, stubNo: "#0342"),
            likes: 12, comments: 3, seen: "mei + 2 more saw this"
        ),
        FeedItem(
            actor: .init(handle: "@jay", when: "1d"),
            kind: .shuffle(line: "Dune 2 finally above Drive. fight me.",
                           titles: [
                            .init(title: "Dune Pt 2",  seed: 5, direction: .up),
                            .init(title: "Drive",      seed: 6, direction: .down),
                            .init(title: "BR 2049",    seed: 1, direction: .none),
                           ]),
            likes: 8, comments: 12, seen: "heated comments"
        ),
        FeedItem(
            actor: .init(handle: "@ana", when: "2d"),
            kind: .milestone(headline: "100 STUBS", sub: "ana hit a century ✨"),
            likes: 34, comments: 7, seen: "send a card →"
        ),
        FeedItem(
            actor: .init(handle: "@theo", when: "3d"),
            kind: .rank(title: "Challengers", tier: .A,
                        line: "the grunts. the GRUNTS.",
                        moods: ["horny","messy"],
                        seed: 5, stubNo: "#0088"),
            likes: 22, comments: 4, seen: "you agreed"
        ),
    ]

    /// Demo `get_feed_page` rows for the ticket-wall preview/fixture path
    /// (no session). Mapped through `FeedCards.card` so preview mode exercises
    /// the exact same card pipeline the live feed uses — one row per variant.
    /// `boosted_ts` mirrors `created_at` (no boost in fixtures); metadata
    /// carries the notes/review/list/milestone fields the ticket front reads.
    public static let feedEventRows: [FeedEventRow] = [
        FeedEventRow(
            id: UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!,
            actor_id: UUID(uuidString: "A0000000-0000-0000-0000-0000000000A1")!,
            event_type: "ranking_add",
            media_tmdb_id: "tmdb_0", media_title: "Past Lives", media_tier: "S",
            media_poster_url: nil,
            metadata: ["notes": .string("cried on the 6 train.")],
            created_at: "2026-07-07T14:00:00+00:00",
            boosted_ts: "2026-07-07T14:00:00+00:00"
        ),
        FeedEventRow(
            id: UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!,
            actor_id: UUID(uuidString: "A0000000-0000-0000-0000-0000000000B2")!,
            event_type: "review",
            media_tmdb_id: "tmdb_5", media_title: "Challengers", media_tier: "A",
            media_poster_url: nil,
            metadata: ["reviewBody": .string("the grunts. the GRUNTS."),
                       "containsSpoilers": .bool(false)],
            created_at: "2026-07-06T14:00:00+00:00",
            boosted_ts: "2026-07-06T14:00:00+00:00"
        ),
        FeedEventRow(
            id: UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!,
            actor_id: UUID(uuidString: "A0000000-0000-0000-0000-0000000000C3")!,
            event_type: "list_create",
            media_tmdb_id: nil, media_title: nil, media_tier: nil,
            media_poster_url: nil,
            metadata: ["listTitle": .string("comfort rewatches"), "listItemCount": .integer(12)],
            created_at: "2026-07-05T14:00:00+00:00",
            boosted_ts: "2026-07-05T14:00:00+00:00"
        ),
        FeedEventRow(
            id: UUID(uuidString: "F0000000-0000-0000-0000-000000000004")!,
            actor_id: UUID(uuidString: "A0000000-0000-0000-0000-0000000000D4")!,
            event_type: "milestone",
            media_tmdb_id: nil, media_title: nil, media_tier: nil,
            media_poster_url: nil,
            metadata: ["badgeIcon": .string("🏆"),
                       "milestoneDescription": .string("100 films ranked")],
            created_at: "2026-07-04T14:00:00+00:00",
            boosted_ts: "2026-07-04T14:00:00+00:00"
        ),
    ]

    /// Usernames for the fixture actor ids above — the preview card path
    /// hydrates handles from this map (no network in preview mode).
    public static let feedFixtureUsernames: [UUID: String] = [
        UUID(uuidString: "A0000000-0000-0000-0000-0000000000A1")!: "mei",
        UUID(uuidString: "A0000000-0000-0000-0000-0000000000B2")!: "theo",
        UUID(uuidString: "A0000000-0000-0000-0000-0000000000C3")!: "ana",
        UUID(uuidString: "A0000000-0000-0000-0000-0000000000D4")!: "jay",
    ]

    public static let aprilWatched: [WatchedDay] = [
        .init(day: 2,  tier: .A, title: "La Chimera"),
        .init(day: 5,  tier: .B, title: "Zone of Interest"),
        .init(day: 8,  tier: .S, title: "Drive My Car"),
        .init(day: 10, tier: .A, title: "Poor Things"),
        .init(day: 12, tier: .C, title: "Madame Web"),
        .init(day: 15, tier: .A, title: "Challengers"),
        .init(day: 17, tier: .B, title: "Monkey Man"),
        .init(day: 18, tier: .S, title: "Past Lives"),
        .init(day: 21, tier: .A, title: "Love Lies Bleeding"),
        .init(day: 24, tier: .B, title: "Evil Does Not Exist"),
        .init(day: 25, tier: .S, title: "Perfect Days"),
    ]

    public static let twinShared: [TwinEntry] = [
        .init(t: "Past Lives",   s: 0),
        .init(t: "Portrait",     s: 7),
        .init(t: "Moonlight",    s: 4),
        .init(t: "Drive My Car", s: 9),
        .init(t: "Aftersun",     s: 1),
        .init(t: "Lady Bird",    s: 3),
    ]

    public static let twinFights: [TwinFight] = [
        .init(t: "Challengers",         s: 5, yours: .D, theirs: .S),
        .init(t: "Anatomy of a Fall",   s: 2, yours: .A, theirs: .C),
    ]

    public static let twinRecs: [TwinEntry] = [
        .init(t: "Maborosi",        s: 8),
        .init(t: "Tokyo Story",     s: 6),
        .init(t: "Days of Being Wild", s: 4),
        .init(t: "Happy Together",  s: 1),
    ]

    public static let topFour: [TopFourEntry] = [
        .init(title: "In the Mood for Love",       seed: 2),
        .init(title: "Portrait of a Lady on Fire", seed: 7),
        .init(title: "Moonlight",                  seed: 4),
        .init(title: "Past Lives",                 seed: 0),
    ]
}
