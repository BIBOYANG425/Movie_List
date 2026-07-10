import SwiftUI

/// Root view: tab state + ranking flow state + modal screens.
/// Add this as the body of your App's `WindowGroup`.
public struct SpoolAppRoot: View {
    @AppStorage("spool.onboarding_completed") private var onboardingCompleted: Bool = false
    @AppStorage("spool.user_handle") private var userHandle: String = ""
    /// True when the user completed onboarding WITHOUT signing in. Drives the
    /// preview-mode banner over the tab bar + tells rank persistence sites to
    /// queue (via `OnboardingQueue.append`) instead of writing to Supabase.
    /// Cleared when the user successfully signs in via `SignInSheet`.
    @AppStorage("spool.preview_mode") private var previewMode: Bool = false
    /// Cross-view signal for presenting the sign-in recovery sheet. Any view
    /// (today: `RankH2HScreen`, the preview-mode banner) can flip this to
    /// `true` to ask the root to present the sheet. Stored in UserDefaults
    /// so `@AppStorage` writes from other views propagate here without a
    /// bindings ping-pong through every intermediate screen.
    @AppStorage("spool.show_signin_sheet") private var showSignInSheet: Bool = false
    /// Persisted theme choice. Defaults to `.system` so new installs pick up
    /// the device's light/dark mode automatically. Previous installs that set
    /// `.paper` or `.dark` keep their explicit pick.
    @AppStorage("spool.theme_preference") private var themePreferenceRaw: String = ThemePreference.system.rawValue
    /// Persisted app language (C6-iOS Task 2). Same raw-string `@AppStorage`
    /// contract as the theme preference, on `LocaleStore.storageKey`
    /// (`"spool_locale"`). This property exists to make the ROOT observe the
    /// locale so a Settings toggle re-renders every `L10n.t`-reading view:
    /// `.id(rawLocale)` on the content forces a rebuild when the raw value
    /// flips (the canonical Task 3 re-render pattern documented in LocaleStore).
    ///
    /// IMPORTANT (fresh-install ordering, LocaleStore contract): `LocaleStore.current`
    /// is read at first launch (via `L10n.t`) BEFORE this wrapper's default would
    /// write — and the default here is deliberately the DEVICE default, not a bare
    /// `"en"`, so this wrapper never masks a device-zh install's `.zh` seed.
    @AppStorage(LocaleStore.storageKey) private var rawLocale: String = LocaleStore.current.rawValue
    /// System color scheme; only used when preference is `.system`.
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var tab: SpoolTab = .feed

    /// Read-only typed view over `themePreferenceRaw`. Writes go directly to
    /// the raw AppStorage string (one call site, `paletteToggle`) — we used
    /// to have a `nonmutating set` here too, but nobody used it.
    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRaw) ?? .system
    }

    /// Effective paper/dark mode used for palette lookups and the palette
    /// toggle icon. When preference is `.system`, this follows whatever
    /// light/dark the device is in.
    private var mode: SpoolMode {
        themePreference.resolved(environment: systemColorScheme)
    }

    /// `.preferredColorScheme` value — `nil` when the user chose system so
    /// SwiftUI doesn't force a scheme and the app rides along with the OS.
    private var forcedColorScheme: ColorScheme? {
        switch themePreference {
        case .system: return nil
        case .paper:  return .light
        case .dark:   return .dark
        }
    }

    // Rank flow
    @State private var flow: RankFlowStep? = nil
    @State private var rankMovie: Movie? = nil
    @State private var rankTier: Tier? = nil
    @State private var rankMoods: [String] = []
    @State private var rankLine: String = ""
    @State private var rankFinalRank: Int = 0
    @State private var rankFinalScore: Double = 0
    /// The watchlist item this rank flow ENTERED FROM, when the user tapped
    /// "Rank It" on a watchlist card (nil for a plain search→rank). Tracked
    /// through the whole flow so the B5-corrected bookmark removal fires ONLY
    /// for watchlist-origin ranks — a plain add must never delete a bookmark.
    /// Cleared on cancel and on flow entry so a stale origin can't leak into a
    /// later plain rank (C3 Task 4).
    @State private var rankWatchlistOrigin: WatchlistItem? = nil
    /// Monotonic reload signal for the Watchlist tab. Bumped after a confirmed
    /// rank+bookmark-remove so the ranked item drops out of the queue.
    @State private var watchlistReloadToken: Int = 0
    /// The whole-show season-grid target (C5-iOS Task 6): set when a WHOLE-SHOW
    /// TV bookmark's "Rank It" routes through the preselect router to the season
    /// grid. Carries the router-derived REAL show id + a fallback name. The
    /// `.seasonGrid` flow step presents `SeasonSelectScreen` for it; picking a
    /// season builds the composite Movie and continues into `.tier`.
    @State private var rankSeasonShowId: Int? = nil
    @State private var rankSeasonShowName: String = ""

    // Stub modals
    @State private var stubDetail: WatchedDay? = nil
    @State private var stubShare: WatchedDay? = nil

    // Twin modal
    @State private var twinOpen: Friend? = nil
    // Read-only friend profile (pushed full-screen, mirrors twinOpen)
    @State private var friendProfileOpen: Friend? = nil

    // Settings sheet
    @State private var showSettings: Bool = false
    // Full shelf sheet (all tiers, all ranks, in one list)
    @State private var showFullList: Bool = false
    // Journal composer sheet — a bound JournalDraftModel drives it. Set from the
    // ceremony "write more" affordance (seeded with moods+line) and from a
    // Stubs→journal card tap (seeded from a getOwnEntry probe). nil = closed.
    @State private var journalComposer: JournalDraftModel? = nil

    public init() {}

    enum RankFlowStep { case entry, seasonGrid, tier, h2h, ceremony, printed }

    public var body: some View {
        ZStack {
            Group {
                if !onboardingCompleted {
                    OnboardingFlow(onFinish: { outcome in
                        userHandle = outcome.handle
                        previewMode = !outcome.signedIn
                        onboardingCompleted = true
                    })
                } else {
                    mainApp
                }
            }
            // Re-render contract (C6-iOS Task 2, canonical LocaleStore pattern):
            // keying the content on the raw locale forces SwiftUI to rebuild the
            // whole tree when the Settings toggle flips the language, so every
            // `L10n.t`-reading view (today: BottomNav labels + rank a11y label)
            // shows the new copy live. Task 3's copy sweep rides this for free.
            .id(rawLocale)
            // Toast overlay sits above main content but below any `.sheet`
            // (SwiftUI sheets present above overlays natively), so error
            // messages float over the UI without blocking sign-in or future
            // modals. Mounted once at the root so every screen shares one toast.
            ToastHost()
        }
        // Inbound deep links (C7-iOS Task 5): both the `spool://u/{username}`
        // custom scheme AND real universal links on rankspool.com land here.
        // The pure `ProfileDeepLink` router classifies the URL; only profile
        // links are handled. The OAuth callback (`spool://auth-callback`) is
        // recognised and left ENTIRELY to the existing ASWebAuthenticationSession
        // machinery in AuthService — this handler early-returns without touching
        // it. Anything unroutable is ignored (the OS may deliver unrelated URLs).
        .onOpenURL { url in handleDeepLink(url) }
    }

    /// Route an inbound deep-link URL. Profile links resolve the username to a
    /// real profile row and present `FriendProfileScreen` via the same
    /// `friendProfileOpen` seam feed/friends taps use; an unknown username (or a
    /// lookup failure) surfaces the not-found toast. `.authCallback` and
    /// `.unhandled` are deliberately no-ops here.
    private func handleDeepLink(_ url: URL) {
        switch ProfileDeepLink.route(for: url) {
        case .profile(let username):
            Task { await presentProfile(forUsername: username) }
        case .authCallback, .unhandled:
            // authCallback belongs to AuthService's OAuth session; unhandled
            // URLs are not ours. Both are intentional no-ops.
            break
        }
    }

    /// Resolve `username` → profile row and present the read-only profile. Runs
    /// on the main actor (SpoolAppRoot is a `View`, so state writes are already
    /// main-actor-isolated) and hops through `ProfileRepository`. A nil row or a
    /// thrown error both show the not-found toast — a deep link that can't land
    /// on a person should tell the user, not fail silently.
    @MainActor
    private func presentProfile(forUsername username: String) async {
        do {
            guard let row = try await ProfileRepository.shared.getProfileByUsername(username) else {
                ToastCenter.shared.show(L10n.t("toast.profileNotFound"), level: .error)
                return
            }
            // Reuse the exact seam FeedScreen.onOpenActor uses: build a Friend
            // carrying the resolved userID (FriendProfileScreen loads everything
            // from userID) and set friendProfileOpen. Clear any competing modal
            // so the profile lands cleanly on top.
            flow = nil
            twinOpen = nil
            friendProfileOpen = Friend(
                handle: row.handle,
                name: row.displayedName,
                twin: 0,
                userID: row.id
            )
        } catch {
            NSLog("[SpoolAppRoot] deep-link profile resolve failed for '\(username)': \(error)")
            ToastCenter.shared.show(L10n.t("toast.profileNotFound"), level: .error)
        }
    }

    private var mainApp: some View {
        ZStack {
            (mode == .paper
                ? LinearGradient(colors: [Color(hex: 0xEFE9D8), Color(hex: 0xD8CFB4)],
                                 startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [Color(hex: 0x1E1E1E), Color(hex: 0x0A0A0A)],
                                 startPoint: .top, endPoint: .bottom)
            )
            .ignoresSafeArea()

            screen
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if previewMode && !navHidden {
                            previewBanner
                        }
                        if !navHidden {
                            BottomNav(active: tab, onTab: onTab)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) { paletteToggle }
        }
        .spoolMode(mode)
        .preferredColorScheme(forcedColorScheme)
        .sheet(isPresented: $showSignInSheet) {
            SignInSheet(onDone: { result in
                if result == .signedIn {
                    // AuthService already flushed the queue on success; drop
                    // the banner so the user's shelf starts persisting normally.
                    previewMode = false
                }
                showSignInSheet = false
            })
        }
        .sheet(isPresented: $showFullList) {
            FullListScreen(
                onClose: { showFullList = false },
                onRerank: { item in rerankFromShelf(item) }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsScreen(
                preference: Binding(
                    get: { themePreference },
                    set: { themePreferenceRaw = $0.rawValue }
                ),
                effectiveMode: mode,
                onClose: { showSettings = false },
                onSignedOut: {
                    // Flip preview mode on so the signed-out user sees the
                    // "sign in to save" banner above the tab bar again.
                    previewMode = true
                    showSettings = false
                }
            )
        }
        .sheet(item: composerBinding) { token in
            JournalComposer(model: token.model, onClose: { journalComposer = nil })
        }
    }

    /// Bridge the optional composer model to a `sheet(item:)` binding. The model
    /// isn't `Identifiable`, so wrap it in a lightweight token that is.
    private var composerBinding: Binding<ComposerToken?> {
        Binding(
            get: { journalComposer.map(ComposerToken.init) },
            set: { if $0 == nil { journalComposer = nil } }
        )
    }

    /// Identifiable wrapper so a `JournalDraftModel` can drive `sheet(item:)`.
    private struct ComposerToken: Identifiable {
        let model: JournalDraftModel
        var id: ObjectIdentifier { ObjectIdentifier(model) }
        init(_ model: JournalDraftModel) { self.model = model }
    }

    /// Slim gold banner above the tab bar. Tap → opens the sign-in sheet.
    /// Only shown when `previewMode == true` and no modal screen is covering
    /// the nav (`navHidden`). Not dismissible — the single recovery path is
    /// to sign in.
    private var previewBanner: some View {
        SpoolThemeReader { t, _ in
            Button {
                showSignInSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(t.ink)
                    Text(L10n.t("app.previewBanner"))
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(t.yellow)
                        .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }

    private var navHidden: Bool {
        flow != nil || stubDetail != nil || stubShare != nil
            || twinOpen != nil || friendProfileOpen != nil
    }

    @ViewBuilder
    private var screen: some View {
        if let flow = flow {
            rankScreen(for: flow)
                .transition(.opacity)
        } else if let d = stubShare {
            StubShareScreen(stub: d) { stubShare = nil }
        } else if let d = stubDetail {
            StubDetailScreen(
                stub: d,
                onClose: { stubDetail = nil },
                onShare: {
                    stubShare = d
                    stubDetail = nil
                }
            )
        } else if let f = friendProfileOpen {
            FriendProfileScreen(
                friend: f,
                onClose: { friendProfileOpen = nil },
                onOpenTwin: {
                    // Bounce from Profile → Twin. Clearing friendProfileOpen
                    // first so TwinScreen's own back-button lands the user
                    // back on FriendsScreen, not on the profile they just
                    // left. (Profile ↔ Twin mutual links, but no deep stack.)
                    twinOpen = f
                    friendProfileOpen = nil
                }
            )
        } else if let f = twinOpen {
            TwinScreen(friend: f) { twinOpen = nil }
        } else {
            switch tab {
            case .feed:
                FeedScreen(
                    onRankTap: { onTab(.rank) },
                    onOpenFriends: { tab = .friends },
                    onOpenSettings: { showSettings = true },
                    onOpenActor: { actorID, handle in
                        // Route to the read-only profile. FriendProfileScreen
                        // loads everything from `userID`; the handle is a
                        // best-effort label until that fetch resolves.
                        friendProfileOpen = Friend(
                            handle: handle.map { $0.hasPrefix("@") ? $0 : "@\($0)" } ?? "@…",
                            name: handle ?? "profile",
                            twin: 0,
                            userID: actorID
                        )
                    },
                    onRankFromDiscover: { movie in rankItFromDiscover(movie) }
                )
            case .stubs:
                StubsScreen(
                    onOpenDetail: { stubDetail = $0 },
                    onOpenJournalEntry: { tmdbId in presentComposerForEntry(tmdbId: tmdbId) }
                )
            case .watchlist:
                WatchlistScreen(
                    onRankIt: { item in rankItFromWatchlist(item) },
                    reloadToken: watchlistReloadToken
                )
            case .friends:
                FriendsScreen(
                    onOpenTwin: { twinOpen = $0 },
                    onOpenProfile: { friendProfileOpen = $0 }
                )
            case .me:
                ProfileScreen(
                    onOpenSettings: { showSettings = true },
                    onOpenFullList: { showFullList = true }
                )
            case .rank:
                FeedScreen() // impossible state; tab won't actually become .rank
            }
        }
    }

    @ViewBuilder
    private func rankScreen(for step: RankFlowStep) -> some View {
        switch step {
        case .entry:
            RankEntryScreen(
                onPick: { m in
                    // The user chose a movie/tv-season/book from search — this is
                    // now a PLAIN add, not a watchlist-origin rank. Clear any stale
                    // origin that survived a Watchlist → tier → back → search
                    // detour; without this, a different item's bookmark gets
                    // deleted. `m` already carries its `mediaType` + vertical
                    // fields (T5), so the ceremony/persist route by media.
                    rankWatchlistOrigin = nil
                    rankMovie = m
                    flow = .tier
                },
                onClose: {
                    // Closing the search entry screen cancels the flow entirely;
                    // clear any stale origin the same way.
                    rankWatchlistOrigin = nil
                    flow = nil
                },
                onSignIn: {
                    // tv/book modes nudge a signed-out user here → present the
                    // sign-in sheet (the whole flow stays up behind it).
                    showSignInSheet = true
                },
                // LIVE closure — reads previewMode + SpoolClient at call time so
                // the model's gate re-evaluates immediately after the user signs in
                // via the nudge without requiring a flow re-entry. A preview-mode
                // user (onboarded without signing in) is treated as signed-out for
                // the tv/book gate even if a SpoolClient session exists.
                isSignedIn: { !previewMode && SpoolClient.shared != nil }
            )
        case .seasonGrid:
            if let showId = rankSeasonShowId {
                SeasonSelectScreen(
                    showId: showId,
                    showName: rankSeasonShowName,
                    onPick: { m in
                        // A season was chosen for a whole-show watchlist rank.
                        // The rankWatchlistOrigin (the whole-show bookmark) is
                        // KEPT so a confirmed save clears it — the coordinator's
                        // widened identity match (origin.id + "_s") handles the
                        // whole-show → season id divergence.
                        rankMovie = m
                        flow = .tier
                    },
                    onClose: {
                        // Abandon the whole-show rank — no save, bookmark stays.
                        rankWatchlistOrigin = nil
                        rankSeasonShowId = nil
                        flow = nil
                    }
                )
            }
        case .tier:
            if let m = rankMovie {
                RankTierScreen(
                    movie: m,
                    onPick: { tier in
                        rankTier = tier
                        flow = .h2h
                    },
                    onBack: { flow = .entry }
                )
            }
        case .h2h:
            if let m = rankMovie, let t = rankTier {
                RankH2HScreen(
                    movie: m, tier: t,
                    onDone: { rank, score in
                        rankFinalRank = rank
                        rankFinalScore = score
                        flow = .ceremony
                    },
                    onBack: { flow = .tier }
                )
            }
        case .ceremony:
            if let m = rankMovie, let t = rankTier {
                RankCeremonyScreen(
                    movie: m, tier: t,
                    onDone: { moods, line in
                        rankMoods = moods
                        rankLine = line
                        flow = .printed
                    },
                    onBack: { flow = .h2h }
                )
            }
        case .printed:
            if let m = rankMovie, let t = rankTier {
                RankPrintedScreen(
                    movie: m, tier: t, moods: rankMoods, line: rankLine,
                    finalRank: rankFinalRank, finalScore: rankFinalScore,
                    // Close = abandon the whole rank flow without saving.
                    // RankH2HScreen no longer persists mid-flow, so this
                    // is a true abort — user_rankings gets nothing. A watchlist
                    // origin is dropped WITHOUT deleting the bookmark (B5: no
                    // save → the item stays queued).
                    onClose: {
                        rankWatchlistOrigin = nil
                        flow = nil
                    },
                    // Finish = commit. Routes through the coordinator so a
                    // CONFIRMED save on a watchlist-origin rank ALSO deletes the
                    // bookmark (B5-corrected); a plain rank deletes nothing.
                    onFinish: {
                        let movieToSave = m
                        let tierToSave = t
                        let rankToSave = rankFinalRank
                        let moodsToSave = rankMoods
                        let lineToSave = rankLine
                        let origin = rankWatchlistOrigin
                        Task {
                            await finishRank(
                                movie: movieToSave, tier: tierToSave,
                                rank: rankToSave, moods: moodsToSave, line: lineToSave,
                                origin: origin
                            )
                        }
                        rankWatchlistOrigin = nil
                        flow = nil
                        tab = .feed
                    },
                    onWriteMore: {
                        // "write more" → open the full composer seeded with the
                        // ceremony's moods + one-liner. Persist the rank here so
                        // backing out of the composer still keeps the shelf entry
                        // a plain "post to feed" would have made — but pass
                        // `writeJournalQuickEntry: false` so the stage-a journal
                        // upsert does NOT fire. The composer's explicit
                        // full-replace save is the authoritative journal write on
                        // this path; running both would double-write / race on the
                        // same (user_id, tmdb_id) key. The two are exclusive, so
                        // the composer probe deterministically finds nil and seeds
                        // from moods+line (already tested).
                        let movieToSave = m
                        let tierToSave = t
                        let rankToSave = rankFinalRank
                        let moodsToSave = rankMoods
                        let lineToSave = rankLine
                        let origin = rankWatchlistOrigin
                        Task {
                            await finishRank(
                                movie: movieToSave, tier: tierToSave,
                                rank: rankToSave, moods: moodsToSave, line: lineToSave,
                                writeJournalQuickEntry: false,
                                origin: origin
                            )
                        }
                        presentComposerForCeremony(movie: m, moods: rankMoods, line: rankLine)
                        rankWatchlistOrigin = nil
                        flow = nil
                        tab = .stubs
                    }
                )
            }
        }
    }

    /// Build a fully-bound composer model, seed it from the ceremony's moods +
    /// one-liner (folded into `reviewText`), and present it. The seed backstops a
    /// nil probe (a brand-new entry) while a freshly-probed owner row still wins
    /// (probe-before-edit), so this is safe even if the stage-a quick write
    /// already landed a row.
    private func presentComposerForCeremony(movie: Movie, moods: [String], line: String) {
        let seed = JournalDraftModel.ceremonySeed(
            tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl,
            line: line, moods: moods
        )
        let model = JournalEmitters.makeDraftModel(seed: seed)
        journalComposer = model
        Task {
            await model.openForEntry(
                tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl, seed: seed
            )
        }
    }

    /// Open the composer to EDIT an existing entry by `tmdbId` (Stubs→journal
    /// card tap). No seed — `openForEntry` probes the full owner row so the edit
    /// starts from the authoritative record (personal_takeaway intact).
    private func presentComposerForEntry(tmdbId: String) {
        // Look up the entry's title/poster from the probe itself; pass minimal
        // identity up front and let the probe hydrate the rest.
        let model = JournalEmitters.makeDraftModel(seed: nil)
        journalComposer = model
        Task {
            // The probe returns the full row; the composer renders its title
            // from the hydrated draft. A placeholder title is only shown for the
            // one frame before the probe resolves (composer is .loading anyway).
            await model.openForEntry(tmdbId: tmdbId, title: "journal entry", posterUrl: nil, seed: nil)
        }
    }

    /// Rank It from the Watchlist tab (C3 Task 3/4 seam; C5-iOS Task 6 widens it
    /// to tv/book). Routes PER MEDIA:
    ///
    ///  * MOVIE — map + seed the ceremony straight into `.tier` (unchanged).
    ///  * TV WHOLE-SHOW — the preselect router (`TVPreselectRouter.resolve`)
    ///    returns `.seasonGrid`; enter the `.seasonGrid` step with the router's
    ///    DERIVED real show id (so a legacy `show_tmdb_id=0` row still reaches the
    ///    grid). Picking a season there builds the composite Movie and continues.
    ///  * TV SEASON — the router returns `.tier`; build the season Movie directly
    ///    (healed show id) and seed the ceremony. iOS bookmarks carry no notes,
    ///    so there is NO notes prefill (web carried notes here — deliberate gap).
    ///  * BOOK — build the book Movie directly and seed the ceremony.
    ///
    /// The whole-show bookmark is KEPT as `rankWatchlistOrigin` even though the
    /// ranked id becomes a season id: the coordinator's widened identity match
    /// (`origin.id + "_s"`) removes it after a confirmed save (audit §3.9).
    private func rankItFromWatchlist(_ item: WatchlistItem) {
        rankTier = nil
        rankMoods = []
        rankLine = ""
        rankSeasonShowId = nil
        rankSeasonShowName = ""
        // Remember where this rank came from so a CONFIRMED save can delete the
        // bookmark (and only then). A plain search→rank leaves this nil.
        rankWatchlistOrigin = item

        switch item.mediaType {
        case .movie:
            guard let mapped = RankFromWatchlistCoordinator.movie(from: item) else {
                NSLog("[SpoolAppRoot] rankItFromWatchlist: movie map failed for \(item.id)")
                rankWatchlistOrigin = nil
                return
            }
            rankMovie = mapped
            flow = .tier
            // Enrich the prediction signal (a WatchlistItem carries no
            // vote_average). Async while the tier screen is already up.
            if let tmdbId = RankFromWatchlistCoordinator.numericTmdbId(item.id) {
                Task {
                    let vote = await TMDBService.movieVoteAverage(tmdbId: tmdbId)
                    guard let vote else { return }
                    if rankMovie?.id == item.id { rankMovie?.voteAverage = vote }
                }
            }

        case .tv:
            let preselect = TVPreselectRouter.Preselect(
                id: item.id, showTmdbId: item.showTmdbId, seasonNumber: item.seasonNumber)
            guard let route = TVPreselectRouter.resolve(preselect),
                  let showId = route.showTmdbId else {
                // No resolvable show id → cannot rank safely (would mint a 0 row).
                NSLog("[SpoolAppRoot] rankItFromWatchlist: unresolvable tv preselect \(item.id)")
                rankWatchlistOrigin = nil
                return
            }
            switch route.route {
            case .seasonGrid:
                // Whole-show → present the season grid, then continue to .tier.
                rankSeasonShowId = showId
                rankSeasonShowName = item.title
                flow = .seasonGrid
            case .tier:
                // Season already known → build the season Movie directly, heal
                // the show id, and seed the ceremony.
                rankMovie = tvSeasonMovie(from: item, showId: showId)
                flow = .tier
                // Enrich voteAverage from the show's global score (async).
                Task {
                    let score = await TMDBService.tvShowGlobalScore(showId: showId)
                    guard let score else { return }
                    if rankMovie?.id == item.id { rankMovie?.voteAverage = score }
                }
            }

        case .book:
            rankMovie = bookMovie(from: item)
            flow = .tier
        }
    }

    /// Build a season `Movie` from a SEASON watchlist bookmark (its seasonNumber
    /// is real). `showId` is the router-HEALED id so a legacy corrupt row persists
    /// the real show id. `voteAverage` is nil here; enriched async by the caller.
    private func tvSeasonMovie(from item: WatchlistItem, showId: Int) -> Movie {
        let season = item.seasonNumber ?? 0
        return Movie(
            id: item.id,
            title: item.title,
            year: Int(item.year) ?? 0,
            director: item.creator ?? "—",
            seed: Movie.stableSeed(item.id),
            genres: item.genres,
            posterUrl: item.posterUrl.isEmpty ? nil : item.posterUrl,
            voteAverage: nil,
            mediaType: .tv,
            showTmdbId: showId,
            seasonNumber: season,
            seasonTitle: item.seasonTitle,
            creator: item.creator
        )
    }

    /// Build a book `Movie` from a book watchlist bookmark.
    private func bookMovie(from item: WatchlistItem) -> Movie {
        Movie(
            id: item.id,
            title: item.title,
            year: Int(item.year) ?? 0,
            director: item.author ?? "—",
            seed: Movie.stableSeed(item.id),
            genres: item.genres,
            posterUrl: item.posterUrl.isEmpty ? nil : item.posterUrl,
            voteAverage: nil,
            mediaType: .book,
            author: item.author,
            pageCount: item.pageCount,
            isbn: item.isbn,
            olWorkKey: item.olWorkKey,
            olRatingsAverage: item.olRatingsAverage
        )
    }

    /// Re-rank an ALREADY-RANKED item from the shelf's long-press menu (C4 Task 4;
    /// C5-iOS Task 6 routes per media). The shelf sheet has already dismissed
    /// itself (`onClose` before `onRerank`), so this seeds the ceremony with the
    /// RAW item and enters the tier pick — NO watchlist origin (a re-rank must
    /// never delete a bookmark), and NO up-front delete (the ceremony's
    /// `(user_id,tmdb_id)` upsert replaces the row non-destructively).
    ///
    /// Media is inferred from the id prefix (`tv_…` / `ol_…` / else movie), since
    /// a `RankedItem` carries no `mediaType`. A tv re-rank goes STRAIGHT to the
    /// ceremony with the SEASON item (its `seasonNumber` is real → NO season
    /// grid); book/movie re-ranks go straight in too. The season/book `Movie`
    /// carries its vertical fields so the ceremony persists back to the right
    /// table.
    private func rerankFromShelf(_ item: RankedItem) {
        let media = TVPreselectRouter.mediaForRankingId(item.id)
        rankTier = nil
        rankMoods = []
        rankLine = ""
        // A re-rank is NOT a watchlist-origin rank — clear any stale origin so a
        // confirmed save can never delete an unrelated bookmark (B5).
        rankWatchlistOrigin = nil

        switch media {
        case .movie:
            rankMovie = Movie(
                id: item.id, title: item.title, year: item.year ?? 0,
                director: item.director, seed: item.seed, genres: item.genres,
                posterUrl: item.posterUrl)
            flow = .tier
            // Enrich vote_average (the shelf RankedItem carries none).
            if let tmdbId = Int(item.id.filter(\.isNumber)), !item.id.isEmpty {
                Task {
                    let vote = await TMDBService.movieVoteAverage(tmdbId: tmdbId)
                    guard let vote else { return }
                    if rankMovie?.id == item.id { rankMovie?.voteAverage = vote }
                }
            }

        case .tv:
            // Derive the show/season split from the composite id.
            // A WELL-FORMED season id `tv_{n}_s{k}` → direct ceremony (season real).
            // A LEGACY whole-show id `tv_{n}` (no `_s{k}`) — split is nil:
            //   derive the real show id from the id via showTmdbIdFromTVId;
            //   if derivable → route to the SEASON GRID (whole-show semantics);
            //   if not derivable → refuse the re-rank (would mint showTmdbId=0).
            if let split = TVPreselectRouter.showAndSeason(fromSeasonId: item.id) {
                // Well-formed season id — skip the grid, seed ceremony directly.
                rankMovie = Movie(
                    id: item.id, title: item.title, year: item.year ?? 0,
                    director: item.director,          // = attribution (creator)
                    seed: item.seed, genres: item.genres, posterUrl: item.posterUrl,
                    voteAverage: nil, mediaType: .tv,
                    showTmdbId: split.show, seasonNumber: split.season,
                    seasonTitle: item.seasonTitle, creator: item.director)
                flow = .tier
                Task {
                    let score = await TMDBService.tvShowGlobalScore(showId: split.show)
                    guard let score else { return }
                    if rankMovie?.id == item.id { rankMovie?.voteAverage = score }
                }
            } else if let derivedShowId = TVPreselectRouter.showTmdbIdFromTVId(item.id) {
                // Legacy whole-show shelf row `tv_{n}` — route to the season grid
                // so the user picks a season before the ceremony. The grid's
                // completion builds a proper composite id with a real season number.
                rankSeasonShowId = derivedShowId
                rankSeasonShowName = item.title
                flow = .seasonGrid
            } else {
                // Garbage id: can't derive a show id → refuse the re-rank.
                // Never seed a tv Movie with nil showTmdbId (would persist 0/0).
                NSLog("[SpoolAppRoot] rerankFromShelf: corrupt tv id '\(item.id)' — re-rank refused")
                ToastCenter.shared.show(L10n.t("toast.reRankFailed"), level: .error)
            }

        case .book:
            let workKey = item.id.hasPrefix("ol_") ? String(item.id.dropFirst(3)) : nil
            rankMovie = Movie(
                id: item.id, title: item.title, year: item.year ?? 0,
                director: item.director,          // = attribution (author)
                seed: item.seed, genres: item.genres, posterUrl: item.posterUrl,
                voteAverage: nil, mediaType: .book,
                author: item.director, olWorkKey: workKey,
                // The shelf RankedItem carries `globalScore` (0-10); re-derive the
                // 0-5 OL rating so the book engine seed (×2) reproduces it.
                olRatingsAverage: item.globalScore.map { $0 / 2 })
            flow = .tier
        }
    }

    /// Rank It from a Discover card (C3 Part B). The `DiscoverModel` already
    /// mapped the tapped card (engine suggestion or social rec) into a RAW
    /// `Movie`; this just seeds the ceremony and enters the tier pick — NO
    /// watchlist origin (a Discover rank must never delete a bookmark, exactly
    /// like `rerankFromShelf`), and NO up-front delete. The FeedScreen sheet has
    /// already dismissed itself before this fires, so the rank screens present at
    /// the root, not under the cover.
    private func rankItFromDiscover(_ movie: Movie) {
        rankMovie = movie
        rankTier = nil
        rankMoods = []
        rankLine = ""
        // A Discover rank is NOT a watchlist-origin rank — clear any stale origin
        // so a confirmed save can never delete an unrelated bookmark (B5).
        rankWatchlistOrigin = nil
        flow = .tier

        // Enrich the prediction signal with vote_average when the card didn't
        // carry it (social recs have no vote_average; engine items already do).
        // Fetch async while the tier screen is already up, matching the watchlist
        // and shelf paths. A nil result leaves voteAverage as-is.
        if movie.voteAverage == nil, let tmdbId = Int(movie.id.filter(\.isNumber)), !movie.id.isEmpty {
            Task {
                let vote = await TMDBService.movieVoteAverage(tmdbId: tmdbId)
                guard let vote else { return }
                if rankMovie?.id == movie.id {
                    rankMovie?.voteAverage = vote
                }
            }
        }
    }

    /// Commit a rank and apply the B5-corrected bookmark-removal gate. Builds a
    /// `RankFromWatchlistCoordinator` bound to the real persistence + repository,
    /// then delegates — the decision logic lives in the tested coordinator, not
    /// in this view. `origin` is nil for a plain search→rank (nothing deleted).
    private func finishRank(
        movie: Movie, tier: Tier, rank: Int, moods: [String], line: String,
        writeJournalQuickEntry: Bool = true, origin: WatchlistItem?
    ) async {
        let coordinator = RankFromWatchlistCoordinator(
            save: { movie, tier, rank, moods, line, writeJournalQuickEntry in
                await RankPersistence.save(
                    movie: movie, tier: tier, rank: rank,
                    moods: moods, line: line,
                    writeJournalQuickEntry: writeJournalQuickEntry
                )
            },
            removeBookmark: { tmdbId, media in
                try await WatchlistRepository.shared.remove(tmdbId: tmdbId, media: media)
            },
            reloadWatchlist: {
                // Bump the token → the Watchlist tab refetches on next appearance
                // so the just-ranked item is gone from the queue.
                watchlistReloadToken &+= 1
            }
        )
        await coordinator.finish(
            movie: movie, tier: tier, rank: rank, moods: moods, line: line,
            writeJournalQuickEntry: writeJournalQuickEntry,
            watchlistOrigin: origin
        )
    }

    private func onTab(_ t: SpoolTab) {
        if t == .rank {
            rankMovie = nil
            rankTier = nil
            rankMoods = []
            rankLine = ""
            // A plain search→rank has NO watchlist origin — clear any stale one
            // so it can never delete an unrelated bookmark (B5). Also drop any
            // stale whole-show season-grid target (C5-iOS Task 6).
            rankWatchlistOrigin = nil
            rankSeasonShowId = nil
            flow = .entry
        } else {
            tab = t
        }
    }

    private var paletteToggle: some View {
        Button {
            // Quick toggle: flip between explicit paper and dark. If the
            // user was on `.system`, a tap commits to the opposite of the
            // *current* rendered mode so the tap feels responsive. They
            // can always pick `match system` back from Settings.
            themePreferenceRaw = (mode == .paper ? ThemePreference.dark : ThemePreference.paper).rawValue
        } label: {
            Image(systemName: mode == .paper ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 14))
                .padding(8)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.trailing, 14)
        .opacity(0.6)
    }
}

#Preview("paper") {
    SpoolAppRoot()
}

#Preview("dark") {
    SpoolAppRoot().spoolMode(.dark)
}
