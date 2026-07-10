import SwiftUI

/// The social Discover screen (C3-iOS Part A, Task 5) — two Supabase-only,
/// TMDB-free sections in the app's ticket/paper idiom:
///
///  1. "from your friends" — `DiscoverRepository.friendRecommendations`:
///     movies friends ranked S/A that the viewer hasn't ranked or watchlisted,
///     aggregated per movie with a friendCount, top-tier badge, and ≤3 friend
///     avatars/usernames.
///  2. "trending with friends" — `DiscoverRepository.trendingAmongFriends`:
///     movies ≥2 distinct friends ranked in the last 30 days, numbered by
///     ranker count.
///
/// Ports web `DiscoverView` (`components/social/DiscoverView.tsx`); card field
/// lists are the C3 audit §1.2. State is owned by a `DiscoverModel`
/// (`@MainActor ObservableObject`, iOS-16 floor — the `FeedFeedModel` /
/// `WatchlistModel` precedent), with all IO injected as closures so the load
/// choreography is testable with zero network. This view is pure layout.
///
/// Loading / empty / error states are distinct (a thrown read is `.failed`,
/// not `.empty` — the feed convention); a no-friends viewer gets a dedicated
/// empty state that nudges toward follows. Pull-to-refresh reloads both
/// sections. The suggestion-engine grid (Part B) mounts in the marked slot
/// below the two sections — no dead UI ships for it here.
///
/// Header last reviewed: 2026-07-09
public struct DiscoverScreen: View {

    @StateObject private var model: DiscoverModel

    /// Route to a friend's profile from a chip tap (the parent turns the id +
    /// handle into a `Friend`/`FriendProfileScreen` route, like the feed's
    /// `onOpenActor`). Optional — chips are inert when unset.
    private let onOpenActor: ((UUID, String?) -> Void)?
    /// Nudge the no-friends empty state toward the follow surface.
    private let onFindFriends: (() -> Void)?
    /// Dismiss (the sheet's close affordance).
    private let onClose: (() -> Void)?

    /// Production entry — the model binds its two loads to `DiscoverRepository`.
    public init(onOpenActor: ((UUID, String?) -> Void)? = nil,
                onFindFriends: (() -> Void)? = nil,
                onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: DiscoverModel())
        self.onOpenActor = onOpenActor
        self.onFindFriends = onFindFriends
        self.onClose = onClose
    }

    /// Test/preview seam — inject a pre-built (fixture-loaded) model.
    init(model: DiscoverModel,
         onOpenActor: ((UUID, String?) -> Void)? = nil,
         onFindFriends: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.onOpenActor = onOpenActor
        self.onFindFriends = onFindFriends
        self.onClose = onClose
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "discover") {
                    if onClose != nil {
                        closeButton
                    }
                }
                content
            }
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: header trailing

    private var closeButton: some View {
        SpoolThemeReader { t, _ in
            Button { onClose?() } label: {
                Text("close")
                    .font(SpoolFonts.mono(12))
                    .tracking(1.5)
                    .foregroundStyle(t.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: content state machine

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            loadingState
        case .failed:
            failedState
        case .noFriends:
            noFriendsState
        case .loaded(let recs, let trending):
            loaded(recs: recs, trending: trending)
        }
    }

    @ViewBuilder
    private func loaded(recs: [FriendRecommendation], trending: [TrendingMovie]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                friendsSection(recs)
                trendingSection(trending)

                // Part B: suggestion engine grid mounts here (provenance chips).
                // The 5-pool edge-function suggestions surface is a later plan;
                // no placeholder UI ships until it exists.

                if recs.isEmpty && trending.isEmpty {
                    quietState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
        }
        .refreshable { await model.reload() }
    }

    // MARK: sections

    @ViewBuilder
    private func friendsSection(_ recs: [FriendRecommendation]) -> some View {
        if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("from your friends",
                              sub: "loved by people you follow")
                ForEach(recs) { rec in
                    FriendRecCard(rec: rec, onOpenActor: onOpenActor)
                }
            }
        }
    }

    @ViewBuilder
    private func trendingSection(_ trending: [TrendingMovie]) -> some View {
        if !trending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("trending with friends",
                              sub: "most-ranked this month")
                ForEach(trending) { movie in
                    TrendingCard(movie: movie, onOpenActor: onOpenActor)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, sub: String) -> some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Text(sub)
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
            }
        }
    }

    // MARK: states

    private var loadingState: some View {
        SpoolThemeReader { t, _ in
            VStack {
                Spacer(minLength: 60)
                ProgressView().tint(t.inkSoft)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var failedState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 14) {
                Spacer(minLength: 60)
                Text("couldn't load discover")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("try again", size: .sm) { Task { await model.reload() } }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    private var noFriendsState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                Spacer(minLength: 60)
                Image(systemName: "person.2")
                    .font(.system(size: 30))
                    .foregroundStyle(t.inkSoft)
                Text("follow some people")
                    .font(SpoolFonts.serif(20))
                    .foregroundStyle(t.ink)
                Text("discover fills up with what your friends love once you follow a few")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                if onFindFriends != nil {
                    SpoolPill("find friends", filled: true, size: .sm) { onFindFriends?() }
                        .padding(.top, 4)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
        }
    }

    /// Has friends, but they've ranked nothing new the viewer hasn't seen.
    private var quietState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Spacer(minLength: 40)
                Text("nothing new from your friends yet")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Text("check back after they rank a few more")
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Friend recommendation card

/// One "from your friends" card: poster, title/year, top-2 genres, a top-tier
/// badge, and a friendCount + ≤3 friend chips (avatar + username).
private struct FriendRecCard: View {
    let rec: FriendRecommendation
    let onOpenActor: ((UUID, String?) -> Void)?

    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .top, spacing: 12) {
                DiscoverPoster(id: rec.tmdbId, title: rec.title, year: rec.year,
                               posterUrl: rec.posterUrl)
                    .frame(width: 68)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(rec.title)
                            .font(SpoolFonts.serif(17))
                            .tracking(-0.3)
                            .foregroundStyle(t.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        TierBadge(tier: rec.topTier)
                    }

                    Text(DiscoverCardCopy.metaLine(year: rec.year, genres: rec.topGenres))
                        .font(SpoolFonts.mono(10))
                        .tracking(1)
                        .foregroundStyle(t.inkSoft)

                    FriendChipRow(chips: rec.friends,
                                  summary: DiscoverCardCopy.friendCountLine(rec.friendCount,
                                                                            avgTier: rec.avgTier),
                                  onOpenActor: onOpenActor)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.ink, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - Trending card

/// One "trending with friends" card: adds a rank # and a rankerCount line to
/// the shared card shape.
private struct TrendingCard: View {
    let movie: TrendingMovie
    let onOpenActor: ((UUID, String?) -> Void)?

    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .top, spacing: 12) {
                Text("#\(movie.rank)")
                    .font(SpoolFonts.serif(20))
                    .foregroundStyle(t.inkSoft)
                    .frame(width: 30, alignment: .leading)
                    .padding(.top, 2)

                DiscoverPoster(id: movie.tmdbId, title: movie.title, year: movie.year,
                               posterUrl: movie.posterUrl)
                    .frame(width: 62)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(movie.title)
                            .font(SpoolFonts.serif(17))
                            .tracking(-0.3)
                            .foregroundStyle(t.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        TierBadge(tier: movie.avgTier)
                    }

                    Text(DiscoverCardCopy.metaLine(year: movie.year, genres: movie.topGenres))
                        .font(SpoolFonts.mono(10))
                        .tracking(1)
                        .foregroundStyle(t.inkSoft)

                    FriendChipRow(chips: movie.recentRankers,
                                  summary: DiscoverCardCopy.rankerCountLine(movie.rankerCount,
                                                                           avgTier: movie.avgTier),
                                  onOpenActor: onOpenActor)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.ink, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - Shared card pieces

/// The synthetic/real poster block, seeded stably from the id (WatchlistCard
/// precedent).
private struct DiscoverPoster: View {
    let id: String
    let title: String
    let year: String?
    let posterUrl: String?

    var body: some View {
        PosterBlock(
            title: title,
            year: year.flatMap { Int($0) },
            director: "—",
            seed: DiscoverCardCopy.stableSeed(id),
            cornerRadius: 4,
            posterUrl: (posterUrl?.isEmpty == false) ? posterUrl : nil
        )
    }
}

/// A small tier badge (S/A/…) in the tier color, ticket idiom.
private struct TierBadge: View {
    let tier: String
    var body: some View {
        SpoolThemeReader { t, _ in
            Text(tier)
                .font(SpoolFonts.mono(11, weight: .bold))
                .foregroundStyle(t.cream)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DiscoverCardCopy.tierColor(tier, palette: t)))
                .overlay(Circle().stroke(t.ink, lineWidth: 1.2))
        }
    }
}

/// A row of ≤3 friend avatars with the summary count line beneath. Tapping a
/// chip opens that friend's profile when a route is wired.
private struct FriendChipRow: View {
    let chips: [FriendProfileChip]
    let summary: String
    let onOpenActor: ((UUID, String?) -> Void)?

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: -6) {
                    ForEach(chips) { chip in
                        Button {
                            onOpenActor?(chip.userId, chip.username.isEmpty ? nil : chip.username)
                        } label: {
                            ChipAvatar(url: chip.avatarUrl)
                        }
                        .buttonStyle(.plain)
                        .disabled(onOpenActor == nil)
                        .accessibilityLabel(chip.username.isEmpty ? "friend" : chip.username)
                    }
                }
                Text(summary)
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                    .lineLimit(1)
            }
        }
    }
}

/// A 24pt circular avatar over the chip's loadable URL, with a striped
/// placeholder while it loads / on failure.
private struct ChipAvatar: View {
    let url: String
    var body: some View {
        SpoolThemeReader { t, _ in
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    StripePattern(a: t.cream3, b: t.cream2, spacing: 3)
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            .overlay(Circle().stroke(t.ink, lineWidth: 1.2))
        }
    }
}

// MARK: - Pure card copy + color (kept out of the view so it's testable)

/// Pure formatting for Discover cards — meta lines, count lines, the tier
/// color map, and the poster seed. No SwiftUI state, so a later test target
/// can pin the copy without a render.
enum DiscoverCardCopy {

    /// "2010 · ACTION · SCI-FI" — year then up-to-two genres, omitting a blank
    /// year. Genres upper-cased to match the mono meta idiom.
    static func metaLine(year: String?, genres: [String]) -> String {
        var parts: [String] = []
        if let y = year, !y.isEmpty { parts.append(y) }
        parts.append(contentsOf: genres.map { $0.uppercased() })
        return parts.joined(separator: " · ")
    }

    /// "3 friends · avg A" (or "1 friend · …").
    static func friendCountLine(_ count: Int, avgTier: String) -> String {
        let noun = count == 1 ? "friend" : "friends"
        return "\(count) \(noun) · avg \(avgTier)"
    }

    /// "4 ranked · avg B".
    static func rankerCountLine(_ count: Int, avgTier: String) -> String {
        "\(count) ranked · avg \(avgTier)"
    }

    /// Tier letter → the palette's tier color (default B if unknown).
    static func tierColor(_ tier: String, palette t: SpoolPalette) -> Color {
        switch tier {
        case "S": return t.tierS
        case "A": return t.tierA
        case "B": return t.tierB
        case "C": return t.tierC
        case "D": return t.tierD
        default:  return t.tierB
        }
    }

    /// Deterministic 0-19 poster seed from a `tmdb_`/`tv_` id (WatchlistCard
    /// precedent — trailing digits, else a djb2 digest).
    static func stableSeed(_ id: String) -> Int {
        if let digits = id.split(separator: "_").last.flatMap({ Int($0.filter(\.isNumber)) }) {
            return abs(digits) % 20
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 20)
    }
}

// MARK: - Model

/// The Discover screen state model (C3-iOS Part A, Task 5) — drives
/// `DiscoverScreen`. `@MainActor final class … ObservableObject` (iOS-16 floor
/// — the `WatchlistModel` / `FeedFeedModel` precedent), all IO injected as
/// closures so the load choreography is testable with zero network.
///
/// One combined load fetches both sections. A thrown read lands `.failed`
/// (feed convention — distinct from a successful empty). When both sections
/// come back empty, the model inspects `hasFriends` to choose between the
/// no-friends nudge and the "nothing new" quiet state.
@MainActor
public final class DiscoverModel: ObservableObject {

    public enum State: Equatable {
        case loading
        case loaded([FriendRecommendation], [TrendingMovie])
        case noFriends
        case failed
    }

    /// Injected loads. Both throw so a broken read → `.failed`.
    public typealias LoadRecs = () async throws -> [FriendRecommendation]
    public typealias LoadTrending = () async throws -> [TrendingMovie]
    /// Whether the viewer follows anyone — decides the empty branch. Defaults
    /// true when unknowable so an all-empty result reads as "nothing new"
    /// rather than falsely telling a well-connected user to find friends.
    public typealias HasFriends = () async -> Bool

    @Published public private(set) var state: State = .loading

    private let loadRecs: LoadRecs
    private let loadTrending: LoadTrending
    private let hasFriends: HasFriends
    private var didLoad = false

    public init(loadRecs: @escaping LoadRecs,
                loadTrending: @escaping LoadTrending,
                hasFriends: @escaping HasFriends) {
        self.loadRecs = loadRecs
        self.loadTrending = loadTrending
        self.hasFriends = hasFriends
    }

    /// Production init — bind to `DiscoverRepository`. `hasFriends` probes the
    /// same follow edge the repository reads; a failure there is treated as
    /// "unknown → assume connected" so a transient blip never mislabels the
    /// empty state.
    public convenience init() {
        self.init(
            loadRecs: { try await DiscoverRepository.shared.friendRecommendations(limit: 20) },
            loadTrending: { try await DiscoverRepository.shared.trendingAmongFriends(limit: 15, days: 30) },
            hasFriends: { await DiscoverRepository.shared.hasFollows() }
        )
    }

    /// First appearance — load once. Re-appearances keep the loaded state.
    public func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload()
    }

    /// (Re)fetch both sections. Sets `.loading`, then `.loaded` / `.noFriends`
    /// / `.failed`. Both loads run concurrently; either throwing lands `.failed`.
    public func reload() async {
        state = .loading
        async let recsTask = loadRecs()
        async let trendingTask = loadTrending()
        do {
            let (recs, trending) = try await (recsTask, trendingTask)
            if recs.isEmpty && trending.isEmpty {
                let connected = await hasFriends()
                state = connected ? .loaded([], []) : .noFriends
            } else {
                state = .loaded(recs, trending)
            }
        } catch {
            state = .failed
        }
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewModel(
    recs: [FriendRecommendation] = [],
    trending: [TrendingMovie] = [],
    hasFriends: Bool = true,
    fail: Bool = false
) -> DiscoverModel {
    DiscoverModel(
        loadRecs: {
            if fail { struct Boom: Error {}; throw Boom() }
            return recs
        },
        loadTrending: {
            if fail { struct Boom: Error {}; throw Boom() }
            return trending
        },
        hasFriends: { hasFriends }
    )
}

private func chip(_ n: Int, _ name: String) -> FriendProfileChip {
    FriendProfileChip(userId: UUID(), username: name,
                      avatarUrl: "https://api.dicebear.com/8.x/thumbs/svg?seed=\(name)")
}

private let sampleRecs: [FriendRecommendation] = [
    FriendRecommendation(
        tmdbId: "tmdb_27205", title: "Inception", posterUrl: nil, year: "2010",
        genres: ["Action", "Sci-Fi", "Thriller"], avgTier: "S", avgTierNumeric: 4.7,
        friendCount: 3, topTier: "S",
        friends: [chip(1, "mei"), chip(2, "theo"), chip(3, "ana")]
    ),
    FriendRecommendation(
        tmdbId: "tmdb_496243", title: "Parasite", posterUrl: nil, year: "2019",
        genres: ["Drama", "Thriller"], avgTier: "A", avgTierNumeric: 4.0,
        friendCount: 2, topTier: "S",
        friends: [chip(4, "jun"), chip(5, "kai")]
    ),
]

private let sampleTrending: [TrendingMovie] = [
    TrendingMovie(rank: 1, tmdbId: "tmdb_872585", title: "Oppenheimer", posterUrl: nil,
                  year: "2023", genres: ["Drama", "History"], rankerCount: 4, avgTier: "A",
                  avgTierNumeric: 4.2, recentRankers: [chip(1, "mei"), chip(2, "theo"), chip(6, "ren")]),
    TrendingMovie(rank: 2, tmdbId: "tmdb_346698", title: "Barbie", posterUrl: nil,
                  year: "2023", genres: ["Comedy"], rankerCount: 2, avgTier: "B",
                  avgTierNumeric: 3.0, recentRankers: [chip(3, "ana"), chip(5, "kai")]),
]

#Preview("discover · populated") {
    DiscoverScreen(model: previewModel(recs: sampleRecs, trending: sampleTrending),
                   onClose: {})
        .spoolMode(.paper)
}

#Preview("discover · no friends") {
    DiscoverScreen(model: previewModel(hasFriends: false), onFindFriends: {}, onClose: {})
        .spoolMode(.paper)
}

#Preview("discover · quiet") {
    DiscoverScreen(model: previewModel(hasFriends: true), onClose: {})
        .spoolMode(.dark)
}

#Preview("discover · failed") {
    DiscoverScreen(model: previewModel(fail: true), onClose: {})
        .spoolMode(.dark)
}
#endif
