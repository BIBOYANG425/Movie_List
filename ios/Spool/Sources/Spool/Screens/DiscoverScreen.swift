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
/// sections.
///
/// Part B (C3) added the suggestion-engine sections below the two social ones,
/// closing the Part-A "cards inert" deferral:
///  3. "new releases" — a horizontal row of ≤10 `mode: .newReleases` movie
///     suggestions, each chipped "new".
///  4. "for you" engine grid — a 2-column grid of 12 `mode: .suggestions` items
///     with a provenance chip per card (pool → copy, twin of web
///     `discoverChips`), a Refresh (page+1, whole-set swap) affordance, and an
///     error-vs-empty split (`notAuthenticated` → empty since the screen is
///     auth-gated; http/transport → error + retry). These two sections load
///     independently of the social ones (they're auth-gated, not friends-gated),
///     so they still surface for a no-friends viewer.
///
/// Every card (social + engine) now carries two actions: SAVE FOR LATER
/// (`WatchlistRepository.add`, optimistic + toast, de-duped per id) and RANK IT
/// (map the RAW card → `Movie`, fire `onRankIt` → the root's ceremony preseed,
/// NO watchlist origin — a Discover rank must never delete a bookmark, mirroring
/// `rerankFromShelf`). The rank hand-off is threaded FeedScreen (which presents
/// Discover as a `.sheet`) → `SpoolAppRoot.rankItFromDiscover`; the sheet
/// dismisses first so the rank screens aren't stacked under the cover.
///
/// Header last reviewed: 2026-07-10
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
    /// Rank-it hand-off — the caller closes the Discover sheet, then seeds the
    /// root's rank ceremony with the RAW mapped `Movie` (no watchlist origin,
    /// mirroring `rerankFromShelf`). Bound onto the model on appear so the
    /// production model (built by `@StateObject` in `init`) can receive it after
    /// construction (the `RankManageModel.bindRerank` precedent). Inert when nil.
    private let onRankIt: ((Movie) -> Void)?

    /// Production entry — the model binds its loads to `DiscoverRepository` /
    /// `SuggestionsClient` / `WatchlistRepository`.
    public init(onOpenActor: ((UUID, String?) -> Void)? = nil,
                onFindFriends: (() -> Void)? = nil,
                onClose: (() -> Void)? = nil,
                onRankIt: ((Movie) -> Void)? = nil) {
        _model = StateObject(wrappedValue: DiscoverModel())
        self.onOpenActor = onOpenActor
        self.onFindFriends = onFindFriends
        self.onClose = onClose
        self.onRankIt = onRankIt
    }

    /// Test/preview seam — inject a pre-built (fixture-loaded) model.
    init(model: DiscoverModel,
         onOpenActor: ((UUID, String?) -> Void)? = nil,
         onFindFriends: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onRankIt: ((Movie) -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.onOpenActor = onOpenActor
        self.onFindFriends = onFindFriends
        self.onClose = onClose
        self.onRankIt = onRankIt
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
        .task { await model.loadEngineIfNeeded() }
        .task { await model.loadNewReleasesIfNeeded() }
        .onAppear { if let onRankIt { model.bindRankIt(onRankIt) } }
    }

    // MARK: header trailing

    private var closeButton: some View {
        SpoolThemeReader { t, _ in
            Button { onClose?() } label: {
                Text(L10n.t("settings.close"))
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
            // The social sections are empty, but the engine grid + New Releases
            // are auth-gated independently and still surface — render the scroll
            // with the no-friends nudge in the social slot.
            scrollBody(recs: [], trending: [], socialSlot: .noFriends)
        case .loaded(let recs, let trending):
            scrollBody(recs: recs, trending: trending,
                       socialSlot: (recs.isEmpty && trending.isEmpty) ? .quiet : .cards)
        }
    }

    /// Which social state the scroll's social slot renders (the engine grid +
    /// New Releases always follow, regardless of this).
    private enum SocialSlot { case cards, noFriends, quiet }

    @ViewBuilder
    private func scrollBody(recs: [FriendRecommendation], trending: [TrendingMovie],
                            socialSlot: SocialSlot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                switch socialSlot {
                case .cards:
                    friendsSection(recs)
                    trendingSection(trending)
                case .noFriends:
                    noFriendsInline
                case .quiet:
                    quietState
                }

                // Part B: the suggestion-engine grid + New Releases mount here.
                newReleasesSection
                engineSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // Presented as a `.sheet` (from FeedScreen), so it never has the
            // bottom bar under it — 110 over-reserved for an absent nav. The
            // sheet's ScrollView already stops at its own safe area. Small pad
            // (was 110).
            .padding(.bottom, 12)
        }
        .refreshable {
            await model.reload()
            await model.refreshEngine()
            await model.retryNewReleases()
        }
    }

    // MARK: sections

    @ViewBuilder
    private func friendsSection(_ recs: [FriendRecommendation]) -> some View {
        if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(L10n.t("discover.fromFriends"),
                              sub: L10n.t("discover.fromFriendsSub"))
                ForEach(recs) { rec in
                    FriendRecCard(
                        rec: rec, onOpenActor: onOpenActor,
                        saved: model.isSaved(rec.tmdbId),
                        onSave: { Task { await model.saveForLater(rec) } },
                        onRankIt: { model.rankIt(rec) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func trendingSection(_ trending: [TrendingMovie]) -> some View {
        if !trending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(L10n.t("discover.trendingFriends"),
                              sub: L10n.t("discover.trendingFriendsSub"))
                ForEach(trending) { movie in
                    TrendingCard(
                        movie: movie, onOpenActor: onOpenActor,
                        saved: model.isSaved(movie.tmdbId),
                        onSave: { Task { await model.saveForLater(movie) } },
                        onRankIt: { model.rankIt(movie) }
                    )
                }
            }
        }
    }

    // MARK: - Part B sections (engine grid + New Releases)

    /// "for you" engine grid — 12 provenance-tagged movie suggestions in a
    /// 2-column grid. Web `forYouEngine` section: whole-set swap + a Refresh
    /// (page+1) affordance; error-vs-empty split.
    @ViewBuilder
    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                sectionHeader(L10n.t("discover.forYou"), sub: L10n.t("discover.forYouSub"))
                Spacer(minLength: 8)
                if case .ready = model.engineState {
                    SpoolPill(L10n.t("discover.refresh"), size: .sm) { Task { await model.refreshEngine() } }
                }
            }
            engineBody
        }
    }

    @ViewBuilder
    private var engineBody: some View {
        switch model.engineState {
        case .loading:
            engineSkeletonGrid
        case .ready:
            // Render the LIVE-filtered projection so an item ranked/saved this
            // session vanishes from the grid immediately (C7-iOS Task 4).
            // Count VISIBLE items for the empty-state decision: if every fetched
            // card has been ranked/saved this session the grid would render blank
            // under the header — show the empty state instead.
            let visible = model.visibleEngineItems
            if visible.isEmpty {
                sectionEmpty(L10n.t("discover.engineEmpty"))
            } else {
                LazyVGrid(columns: engineColumns, spacing: 12) {
                    ForEach(visible) { item in
                        SuggestionGridCard(
                            item: item,
                            saved: model.isSaved(item.id),
                            onSave: { Task { await model.saveForLater(item) } },
                            onRankIt: { model.rankIt(item) }
                        )
                    }
                }
            }
        case .empty:
            sectionEmpty(L10n.t("discover.engineEmpty"))
        case .error:
            sectionError(L10n.t("discover.engineError")) { await model.refreshEngine() }
        }
    }

    private var engineColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var engineSkeletonGrid: some View {
        LazyVGrid(columns: engineColumns, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in SuggestionSkeletonCard() }
        }
    }

    /// "new releases" — a horizontal row of ≤10 movie-only suggestions, each
    /// chipped "new". Web `newReleases` section: date-ascending, chip "new".
    @ViewBuilder
    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(L10n.t("discover.newReleases"), sub: L10n.t("discover.newReleasesSub"))
            newReleasesBody
        }
    }

    @ViewBuilder
    private var newReleasesBody: some View {
        switch model.newReleasesState {
        case .loading:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SuggestionSkeletonCard().frame(width: 110)
                    }
                }
            }
        case .ready:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    // Live-filtered projection — same session-scoped drop as the
                    // engine grid (C7-iOS Task 4).
                    ForEach(model.visibleNewReleasesItems) { item in
                        SuggestionGridCard(
                            item: item,
                            chipOverride: DiscoverCardCopy.chipCopy(for: .newRelease),
                            saved: model.isSaved(item.id),
                            onSave: { Task { await model.saveForLater(item) } },
                            onRankIt: { model.rankIt(item) }
                        )
                        .frame(width: 110)
                    }
                }
                .padding(.horizontal, 1)
            }
        case .empty:
            sectionEmpty(L10n.t("discover.newReleasesEmpty"))
        case .error:
            sectionError(L10n.t("discover.newReleasesError")) { await model.retryNewReleases() }
        }
    }

    // MARK: - Part B shared section states

    private func sectionEmpty(_ text: String) -> some View {
        SpoolThemeReader { t, _ in
            Text(text)
                .font(SpoolFonts.hand(13))
                .foregroundStyle(t.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }

    private func sectionError(_ text: String, retry: @escaping () async -> Void) -> some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                Text(text)
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                SpoolPill(L10n.t("watchlist.tryAgain"), size: .sm) { Task { await retry() } }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
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
                Text(L10n.t("discover.loadFailed"))
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill(L10n.t("watchlist.tryAgain"), size: .sm) { Task { await model.reload() } }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    /// No-friends nudge as an INLINE section: the social sections are empty, but
    /// the engine grid + New Releases (auth-gated, not friends-gated) still
    /// follow below, so this renders inside the scroll rather than replacing the
    /// whole screen (the Part-A full-screen version is gone — Part B always has
    /// engine content to show a connected-but-friendless viewer).
    private var noFriendsInline: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Image(systemName: "person.2")
                    .font(.system(size: 26))
                    .foregroundStyle(t.inkSoft)
                Text(L10n.t("discover.followSomePeople"))
                    .font(SpoolFonts.serif(19))
                    .foregroundStyle(t.ink)
                Text(L10n.t("discover.followSomePeopleSub"))
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                if onFindFriends != nil {
                    SpoolPill(L10n.t("discover.findFriends"), filled: true, size: .sm) { onFindFriends?() }
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
        }
    }

    /// Has friends, but they've ranked nothing new the viewer hasn't seen.
    private var quietState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Spacer(minLength: 20)
                Text(L10n.t("discover.quietTitle"))
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Text(L10n.t("discover.quietSub"))
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 20)
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
    let saved: Bool
    let onSave: () -> Void
    let onRankIt: () -> Void

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

                    CardActionRow(saved: saved, onSave: onSave, onRankIt: onRankIt)
                        .padding(.top, 4)
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
    let saved: Bool
    let onSave: () -> Void
    let onRankIt: () -> Void

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

                    CardActionRow(saved: saved, onSave: onSave, onRankIt: onRankIt)
                        .padding(.top, 4)
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

// MARK: - Part B card pieces (provenance chip, action row, engine card)

/// A small provenance chip ("your taste", "trending", "new", …) overlaid on
/// engine + New Releases cards. Uppercase mono in the ticket idiom.
private struct ProvenanceChip: View {
    let copy: String
    var body: some View {
        SpoolThemeReader { t, _ in
            Text(copy.uppercased())
                .font(SpoolFonts.mono(8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(t.cream)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(t.ink.opacity(0.82)))
                .lineLimit(1)
        }
    }
}

/// The two card actions closing Part A's "cards inert" deferral: save-for-later
/// (bookmark) + rank-it (enter the ceremony). Shared by the social cards and the
/// engine cards. `saved` swaps the bookmark glyph to a filled "saved" state.
private struct CardActionRow: View {
    let saved: Bool
    let onSave: () -> Void
    let onRankIt: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 8) {
                Button(action: onSave) {
                    HStack(spacing: 4) {
                        Image(systemName: saved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 10, weight: .semibold))
                        Text(saved ? L10n.t("discover.saved") : L10n.t("discover.save"))
                            .font(SpoolFonts.mono(9))
                            .tracking(0.5)
                    }
                    .foregroundStyle(t.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
                .disabled(saved)
                .accessibilityLabel(saved ? L10n.t("discover.savedA11y") : L10n.t("discover.saveA11y"))

                Button(action: onRankIt) {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.t("watchlist.rankIt"))
                            .font(SpoolFonts.mono(9))
                            .tracking(0.5)
                    }
                    .foregroundStyle(t.cream)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(t.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("watchlist.rankIt"))

                Spacer(minLength: 0)
            }
        }
    }
}

/// One engine / New Releases suggestion card: a 2:3 poster with a provenance
/// chip overlaid top-left, title + year/genre meta, and the save/rank action
/// row. Used both in the 2-column "for you" grid and the horizontal New
/// Releases row (with a "new" chip override).
private struct SuggestionGridCard: View {
    let item: SuggestionItem
    var chipOverride: String? = nil
    let saved: Bool
    let onSave: () -> Void
    let onRankIt: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                PosterBlock(
                    title: item.title,
                    year: Int(item.year),
                    director: "—",
                    seed: DiscoverCardCopy.stableSeed(item.id),
                    cornerRadius: 6,
                    posterUrl: (item.posterUrl?.isEmpty == false) ? item.posterUrl : nil
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    ProvenanceChip(copy: chipOverride ?? DiscoverCardCopy.chipCopy(for: item.pool))
                        .padding(6)
                }

                Text(item.title)
                    .font(SpoolFonts.serif(14))
                    .tracking(-0.2)
                    .foregroundStyle(t.ink)
                    .lineLimit(1)

                Text(DiscoverCardCopy.metaLine(year: item.year, genres: Array(item.genres.prefix(2))))
                    .font(SpoolFonts.mono(9))
                    .tracking(0.8)
                    .foregroundStyle(t.inkSoft)
                    .lineLimit(1)

                CardActionRow(saved: saved, onSave: onSave, onRankIt: onRankIt)
            }
        }
    }
}

/// A striped placeholder card while an engine section loads (poster idiom).
private struct SuggestionSkeletonCard: View {
    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                StripePattern(a: t.cream3, b: t.cream2, spacing: 4)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.ink.opacity(0.4), lineWidth: 1))
                RoundedRectangle(cornerRadius: 3).fill(t.cream3).frame(height: 10)
                RoundedRectangle(cornerRadius: 3).fill(t.cream3).frame(width: 60, height: 8)
            }
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

    /// Provenance-chip copy for an engine item's `pool` (Part B). The iOS twin
    /// of web `discoverChips.chipLabelKeyForPool` — now wired through `L10n.t`
    /// REUSING the web `discover.chip.*` keys VERBATIM (C6-iOS Task 3), so the two
    /// clients render identical chip copy. Every pool with a distinct story gets
    /// its own chip; `backfill`, any `.unknown`, and a nil pool fall back to the
    /// safe "popular" chip (`discover.chip.generic`) so a new server pool never
    /// renders a raw enum or a blank chip (web fallback parity).
    static func chipCopy(for pool: SuggestionPool?) -> String {
        switch pool {
        case .friend:     return L10n.t("discover.chip.friend")
        case .taste:      return L10n.t("discover.chip.taste")
        case .similar:    return L10n.t("discover.chip.similar")
        case .trending:   return L10n.t("discover.chip.trending")
        case .variety:    return L10n.t("discover.chip.variety")
        case .generic:    return L10n.t("discover.chip.generic")
        case .newRelease: return L10n.t("discover.chip.new_release")
        case .backfill, .unknown, .none:
            return L10n.t("discover.chip.generic")
        }
    }

    /// Map an engine `SuggestionItem` (a MOVIE — the grid is movie-only) into a
    /// `WatchlistItem` for the save-for-later write. The id arrives already
    /// `tmdb_`-prefixed from the function; `year`/`posterUrl` coalesce to the
    /// watchlist's `''`-when-null convention.
    static func watchlistItem(from item: SuggestionItem) -> WatchlistItem {
        WatchlistItem(
            id: item.id,
            title: item.title,
            year: item.year,
            posterUrl: item.posterUrl ?? "",
            mediaType: .movie,
            genres: item.genres,
            addedAt: Date(),
            director: nil
        )
    }

    /// Map an engine `SuggestionItem` into the `Movie` the rank ceremony
    /// consumes. RAW — no watchlist origin (a discover rank must never delete a
    /// bookmark; mirrors `rerankFromShelf`). `voteAverage` rides along (the
    /// engine carries it; the ceremony's prediction signal uses it directly).
    static func movie(from item: SuggestionItem) -> Movie {
        Movie(
            id: item.id,
            title: item.title,
            year: Int(item.year) ?? 0,
            director: "—",
            seed: stableSeed(item.id),
            genres: item.genres,
            posterUrl: (item.posterUrl?.isEmpty == false) ? item.posterUrl : nil,
            voteAverage: item.voteAverage
        )
    }

    /// Map a social "from your friends" card into a `WatchlistItem` for the
    /// save-for-later write (movie media; social Discover is movie-only).
    ///
    /// `normalizeTmdbId` is applied here — the B1 seam — so bare-numeric ids
    /// from legacy `user_rankings` rows are prefix-normalized before they enter
    /// the watchlist (web `normalizeTmdbId` parity).
    static func watchlistItem(from rec: FriendRecommendation) -> WatchlistItem {
        WatchlistItem(
            id: normalizeTmdbId(rec.tmdbId), title: rec.title, year: rec.year ?? "",
            posterUrl: rec.posterUrl ?? "", mediaType: .movie, genres: rec.genres,
            addedAt: Date(), director: nil
        )
    }

    /// Map a social "trending with friends" card into a `WatchlistItem`.
    ///
    /// `normalizeTmdbId` applied at the B1 seam (same as the `FriendRecommendation`
    /// variant above).
    static func watchlistItem(from movie: TrendingMovie) -> WatchlistItem {
        WatchlistItem(
            id: normalizeTmdbId(movie.tmdbId), title: movie.title, year: movie.year ?? "",
            posterUrl: movie.posterUrl ?? "", mediaType: .movie, genres: movie.genres,
            addedAt: Date(), director: nil
        )
    }

    /// Map a social card's `WatchlistItem` into the ceremony `Movie` (RAW, no
    /// origin). Mirrors `RankFromWatchlistCoordinator.movie(from:)` field-for-
    /// field (movies only, `stableSeed`, `''`-poster → nil); inlined rather than
    /// called because that helper is `@MainActor` and this mapper is a pure,
    /// nonisolated enum used from the view layer.
    static func movie(from item: WatchlistItem) -> Movie? {
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

    /// Normalizes a social-card TMDB id at the save/rank seam (B1 quirk — legacy
    /// `user_rankings.tmdb_id` rows can be bare-numeric e.g. "27205").
    ///
    /// Web normalizes at this exact seam (`normalizeTmdbId`); iOS mirrors it here
    /// so bare ids never persist into the watchlist or ranking ceremony:
    ///   - bare digits ("27205")       → "tmdb_27205"
    ///   - already prefixed ("tmdb_1") → unchanged
    ///   - other formats               → unchanged (tv_…, etc.)
    ///
    /// Engine items (`SuggestionItem.id`) are already guaranteed prefixed by the
    /// server; only the social-card path (FriendRecommendation / TrendingMovie)
    /// needs this normalizer.
    static func normalizeTmdbId(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        // Already prefixed — pass through.
        if raw.hasPrefix("tmdb_") || raw.hasPrefix("tv_") { return raw }
        // Bare numeric — prefix.
        if raw.allSatisfy(\.isNumber) { return "tmdb_\(raw)" }
        // Other format (future-proofed) — pass through unchanged.
        return raw
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
///
/// LIVE OWNED-DISPLAY FILTER (C7-iOS Task 4): the engine grid + New Releases
/// render `visibleEngineItems` / `visibleNewReleasesItems`, which drop any id
/// in `ownedThisSession` (`savedIds ∪ rankedIds`). The engine already excludes
/// server-owned items, but an item saved or ranked mid-session was in the
/// already-fetched page — this render-time re-filter makes it vanish the moment
/// the user acts on it, mirroring web `AddMediaModal`'s `isAlreadyOwned` filter.
@MainActor
public final class DiscoverModel: ObservableObject {

    public enum State: Equatable {
        case loading
        case loaded([FriendRecommendation], [TrendingMovie])
        case noFriends
        case failed
    }

    /// The load state of ONE suggestion-engine section (engine grid /
    /// New Releases). Distinct from the social sections' `State`: an engine
    /// section splits empty from error per the web outage-vs-401 contract —
    /// `notAuthenticated` → `.empty` (the screen is auth-gated anyway), an
    /// `.http`/`.transport`/`.decoding` failure → `.error` (a retry affordance).
    public enum SectionState: Equatable {
        case loading
        case ready([SuggestionItem])
        case empty
        case error
    }

    /// Injected loads. Both throw so a broken read → `.failed`.
    public typealias LoadRecs = () async throws -> [FriendRecommendation]
    public typealias LoadTrending = () async throws -> [TrendingMovie]
    /// Whether the viewer follows anyone — decides the empty branch. Defaults
    /// true when unknowable so an all-empty result reads as "nothing new"
    /// rather than falsely telling a well-connected user to find friends.
    public typealias HasFriends = () async -> Bool
    /// A suggestion-engine load (engine grid / New Releases). Throws the
    /// `SuggestionsClient` errors so the model can split empty (notAuthenticated)
    /// from error (http/transport/decoding). `(mode, page)` mirror web's
    /// `fetchMovieSuggestionsWithProvenance(mode, page, [])`.
    public typealias LoadSuggestions = (SuggestionMode, Int) async throws -> [SuggestionItem]
    /// Save-for-later — `WatchlistRepository.add`; returns success so the model
    /// can toast the outcome (web reverts its optimistic prepend on failure).
    public typealias SaveForLater = (WatchlistItem) async -> Bool
    /// A user-visible message (bound to `ToastCenter.shared.show` in prod).
    public typealias Toast = (String, ToastLevel) -> Void
    /// The rank-it entry point — the view wires this to the root's ceremony
    /// preseed (RAW `Movie`, no watchlist origin). Rebindable via `bindRankIt`
    /// so the production model (built by the view's `@StateObject`) can hand the
    /// closure in after init, mirroring `RankManageModel.bindRerank`.
    public typealias OnRankIt = (Movie) -> Void

    /// The engine-grid cap (web `ENGINE_GRID_LIMIT`).
    static let engineGridLimit = 12
    /// The New Releases cap (web `NEW_RELEASES_LIMIT`).
    static let newReleasesLimit = 10

    @Published public private(set) var state: State = .loading
    /// The engine grid ("for you") section state.
    @Published public private(set) var engineState: SectionState = .loading
    /// The New Releases row state.
    @Published public private(set) var newReleasesState: SectionState = .loading
    /// Optimistic "already saved" ids — suppresses a duplicate `add` on a second
    /// tap and lets the card show a saved affordance. Owned/bookmarked items are
    /// excluded server-side for the grid; this de-dups the user's own taps.
    @Published public private(set) var savedIds: Set<String> = []
    /// Ids the user RANKED this session via a grid card's rank-it (C7-iOS Task 4).
    /// The engine excludes owned items server-side, but an item ranked mid-session
    /// was already in the fetched page — this session-scoped set lets the live
    /// display filter drop it so it vanishes the moment it's ranked, mirroring
    /// web's `isAlreadyOwned` re-filter (`AddMediaModal.tsx:288-303`, where
    /// `rankedIds`/`watchlistIds` are folded into `allExcludedIds` at render time).
    @Published public private(set) var rankedIds: Set<String> = []

    private let loadRecs: LoadRecs
    private let loadTrending: LoadTrending
    private let hasFriends: HasFriends
    private let loadEngine: LoadSuggestions
    private let loadNewReleases: LoadSuggestions
    private let save: SaveForLater
    private let toast: Toast
    private var onRankIt: OnRankIt = { _ in }
    private var didLoad = false
    private var didLoadEngine = false
    private var didLoadNewReleases = false
    /// Engine page — Refresh advances it (web `Refresh = page+1`).
    private var enginePage = 1

    public init(loadRecs: @escaping LoadRecs,
                loadTrending: @escaping LoadTrending,
                hasFriends: @escaping HasFriends,
                loadEngine: @escaping LoadSuggestions = { _, _ in [] },
                loadNewReleases: @escaping LoadSuggestions = { _, _ in [] },
                save: @escaping SaveForLater = { _ in false },
                toast: @escaping Toast = { _, _ in }) {
        self.loadRecs = loadRecs
        self.loadTrending = loadTrending
        self.hasFriends = hasFriends
        self.loadEngine = loadEngine
        self.loadNewReleases = loadNewReleases
        self.save = save
        self.toast = toast
    }

    /// Production init — bind to `DiscoverRepository` + `SuggestionsClient` +
    /// `WatchlistRepository` + the shared toast center. `hasFriends` probes the
    /// same follow edge the repository reads; a failure there is treated as
    /// "unknown → assume connected" so a transient blip never mislabels the
    /// empty state. The engine loads request MOVIE suggestions (the grid is
    /// movie-only), passing an empty `sessionExcludeIds` (the function reads the
    /// caller's owned/bookmarked exclusions server-side under their JWT).
    public convenience init() {
        self.init(
            loadRecs: { try await DiscoverRepository.shared.friendRecommendations(limit: 20) },
            loadTrending: { try await DiscoverRepository.shared.trendingAmongFriends(limit: 15, days: 30) },
            hasFriends: { await DiscoverRepository.shared.hasFollows() },
            loadEngine: { mode, page in
                try await SuggestionsClient.fetch(
                    mode: mode, mediaType: .movie, page: page, sessionExcludeIds: []
                ).items
            },
            loadNewReleases: { mode, page in
                try await SuggestionsClient.fetch(
                    mode: mode, mediaType: .movie, page: page, sessionExcludeIds: [],
                    limit: DiscoverModel.newReleasesLimit
                ).items
            },
            save: { item in await WatchlistRepository.shared.add(item: item) },
            toast: { text, level in ToastCenter.shared.show(text, level: level) }
        )
    }

    /// Wire the rank-it entry point after init (the view builds the production
    /// model, then hands in the root's ceremony-preseed closure). Idempotent —
    /// the last bind wins.
    public func bindRankIt(_ handler: @escaping OnRankIt) {
        onRankIt = handler
    }

    // MARK: - Social sections (Part A — unchanged)

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

    // MARK: - Engine grid section (Part B)

    /// First appearance — load the engine grid once (page 1). Refresh is the
    /// re-fetch (web loads once per mount; Refresh advances the page).
    public func loadEngineIfNeeded() async {
        guard !didLoadEngine else { return }
        didLoadEngine = true
        await fetchEngine(page: enginePage)
    }

    /// Refresh the engine grid — advance the page and whole-set swap (web
    /// parity: `Refresh = page+1`, replace not append).
    public func refreshEngine() async {
        enginePage += 1
        await fetchEngine(page: enginePage)
    }

    private func fetchEngine(page: Int) async {
        engineState = .loading
        do {
            let items = try await loadEngine(.suggestions, page)
            engineState = items.isEmpty ? .empty : .ready(Array(items.prefix(Self.engineGridLimit)))
        } catch {
            engineState = Self.sectionState(for: error)
        }
    }

    /// The engine grid's items (empty for any non-`.ready` state). RAW — the
    /// render surface reads `visibleEngineItems` instead so a mid-session
    /// rank/save drops the card live.
    public var engineItems: [SuggestionItem] {
        if case .ready(let items) = engineState { return items }
        return []
    }

    /// The engine grid AFTER the live owned-display filter (C7-iOS Task 4). Drops
    /// any item saved or ranked THIS session (`ownedThisSession`), mirroring web's
    /// render-time `isAlreadyOwned` re-filter: the engine already excludes
    /// server-owned items, but an item the user acts on mid-session was already in
    /// the fetched page and must vanish immediately. The view renders this.
    public var visibleEngineItems: [SuggestionItem] {
        engineItems.filter { !ownedThisSession.contains($0.id) }
    }

    // MARK: - New Releases section (Part B)

    /// First appearance — load New Releases once. Retry re-fetches on error.
    public func loadNewReleasesIfNeeded() async {
        guard !didLoadNewReleases else { return }
        didLoadNewReleases = true
        await fetchNewReleases()
    }

    /// Retry the New Releases load (the error state's affordance).
    public func retryNewReleases() async {
        await fetchNewReleases()
    }

    private func fetchNewReleases() async {
        newReleasesState = .loading
        do {
            let items = try await loadNewReleases(.newReleases, 1)
            newReleasesState = items.isEmpty ? .empty : .ready(Array(items.prefix(Self.newReleasesLimit)))
        } catch {
            newReleasesState = Self.sectionState(for: error)
        }
    }

    /// The New Releases items (empty for any non-`.ready` state). RAW — the
    /// render surface reads `visibleNewReleasesItems`.
    public var newReleasesItems: [SuggestionItem] {
        if case .ready(let items) = newReleasesState { return items }
        return []
    }

    /// New Releases AFTER the live owned-display filter (C7-iOS Task 4) — same
    /// session-scoped drop as `visibleEngineItems`.
    public var visibleNewReleasesItems: [SuggestionItem] {
        newReleasesItems.filter { !ownedThisSession.contains($0.id) }
    }

    /// The ids that must vanish from the grids live: saved OR ranked this session.
    /// The union backs both `visible*` projections so the two surfaces filter
    /// identically (web `allExcludedIds` = ranked ∪ watchlisted).
    private var ownedThisSession: Set<String> {
        savedIds.union(rankedIds)
    }

    /// Error-vs-empty split for an engine section (web outage-vs-401 contract):
    /// `notAuthenticated` → `.empty` (the screen is auth-gated); a wire HTTP 401
    /// also maps to `.empty` — the server returned 401 which is the same auth-
    /// failure signal, and retry would simply 401 again (web maps wire 401 →
    /// empty at the same seam); every other `SuggestionsClient` failure
    /// (http/transport/decoding) and any unexpected throw → `.error` (retry).
    private static func sectionState(for error: Error) -> SectionState {
        if case SuggestionsClient.SuggestionsError.notAuthenticated = error {
            return .empty
        }
        if case SuggestionsClient.SuggestionsError.http(401) = error {
            return .empty
        }
        return .error
    }

    // MARK: - Card actions (Part B — on BOTH social + engine cards)

    /// Save an engine item for later (optimistic + toast). De-dups a second tap
    /// on the same id via `savedIds`. Owned/bookmarked items are excluded
    /// server-side for the grid; this suppresses the user's own repeats.
    public func saveForLater(_ item: SuggestionItem) async {
        await performSave(DiscoverCardCopy.watchlistItem(from: item))
    }

    /// Save a social "from your friends" card for later.
    public func saveForLater(_ rec: FriendRecommendation) async {
        await performSave(DiscoverCardCopy.watchlistItem(from: rec))
    }

    /// Save a social "trending with friends" card for later.
    public func saveForLater(_ movie: TrendingMovie) async {
        await performSave(DiscoverCardCopy.watchlistItem(from: movie))
    }

    private func performSave(_ item: WatchlistItem) async {
        guard !savedIds.contains(item.id) else { return }
        // Optimistic mark so a rapid second tap is a no-op and the card can show
        // saved state immediately.
        savedIds.insert(item.id)
        let ok = await save(item)
        if ok {
            toast(L10n.t("discover.savedToast", ["title": item.title]), .success)
        } else {
            // Revert so the user can retry (web reverts its optimistic prepend).
            savedIds.remove(item.id)
            toast(L10n.t("discover.saveFailedToast", ["title": item.title]), .error)
        }
    }

    /// True when `id` has been saved this session (drives the card's saved
    /// affordance).
    public func isSaved(_ id: String) -> Bool { savedIds.contains(id) }

    /// Rank an engine item — map to the RAW ceremony `Movie` (no watchlist
    /// origin) and fire the injected entry point. Notes the id in `rankedIds` so
    /// the live owned-display filter drops the card from the grid immediately
    /// (C7-iOS Task 4 — web re-filters `isAlreadyOwned` at render).
    public func rankIt(_ item: SuggestionItem) {
        rankedIds.insert(item.id)
        onRankIt(DiscoverCardCopy.movie(from: item))
    }

    /// Rank a social "from your friends" card.
    public func rankIt(_ rec: FriendRecommendation) {
        let item = DiscoverCardCopy.watchlistItem(from: rec)
        guard let movie = DiscoverCardCopy.movie(from: item) else { return }
        rankedIds.insert(item.id)
        onRankIt(movie)
    }

    /// Rank a social "trending with friends" card.
    public func rankIt(_ movie: TrendingMovie) {
        let item = DiscoverCardCopy.watchlistItem(from: movie)
        guard let m = DiscoverCardCopy.movie(from: item) else { return }
        rankedIds.insert(item.id)
        onRankIt(m)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewModel(
    recs: [FriendRecommendation] = [],
    trending: [TrendingMovie] = [],
    hasFriends: Bool = true,
    fail: Bool = false,
    engine: [SuggestionItem] = sampleEngine,
    newReleases: [SuggestionItem] = sampleNewReleases
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
        hasFriends: { hasFriends },
        loadEngine: { _, _ in engine },
        loadNewReleases: { _, _ in newReleases },
        save: { _ in true },
        toast: { _, _ in }
    )
}

private func suggestion(_ n: Int, _ title: String, pool: SuggestionPool) -> SuggestionItem {
    SuggestionItem(
        id: "tmdb_\(n)", tmdbId: n, title: title, year: "2024", posterUrl: nil,
        backdropUrl: nil, mediaType: .movie, genres: ["Action", "Drama"],
        overview: "", voteAverage: 7.5, seasonCount: 0, pool: pool
    )
}

private let sampleEngine: [SuggestionItem] = [
    suggestion(1, "Dune: Part Two", pool: .taste),
    suggestion(2, "Poor Things", pool: .similar),
    suggestion(3, "The Zone of Interest", pool: .variety),
    suggestion(4, "Anatomy of a Fall", pool: .trending),
    suggestion(5, "Past Lives", pool: .friend),
    suggestion(6, "The Holdovers", pool: .generic),
]

private let sampleNewReleases: [SuggestionItem] = [
    suggestion(11, "Furiosa", pool: .newRelease),
    suggestion(12, "Challengers", pool: .newRelease),
    suggestion(13, "Civil War", pool: .newRelease),
]

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
