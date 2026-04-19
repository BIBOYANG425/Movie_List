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
    @State private var mode: SpoolMode = .paper
    @State private var tab: SpoolTab = .feed
    @State private var showSignInSheet: Bool = false

    // Rank flow
    @State private var flow: RankFlowStep? = nil
    @State private var rankMovie: Movie? = nil
    @State private var rankTier: Tier? = nil
    @State private var rankMoods: [String] = []
    @State private var rankLine: String = ""
    @State private var rankFinalRank: Int = 0
    @State private var rankFinalScore: Double = 0

    // Stub modals
    @State private var stubDetail: WatchedDay? = nil
    @State private var stubShare: WatchedDay? = nil

    // Twin modal
    @State private var twinOpen: Friend? = nil

    public init() {}

    enum RankFlowStep { case entry, tier, h2h, ceremony, printed }

    public var body: some View {
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
        .preferredColorScheme(mode == .paper ? .light : .dark)
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
                    Text("preview mode — sign in to save your rankings")
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
        flow != nil || stubDetail != nil || stubShare != nil || twinOpen != nil
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
        } else if let f = twinOpen {
            TwinScreen(friend: f) { twinOpen = nil }
        } else {
            switch tab {
            case .feed:
                FeedScreen()
            case .stubs:
                StubsScreen { stubDetail = $0 }
            case .friends:
                FriendsScreen { twinOpen = $0 }
            case .me:
                ProfileScreen()
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
                    rankMovie = m
                    flow = .tier
                },
                onClose: { flow = nil }
            )
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
                    onClose: { flow = nil },
                    onFinish: {
                        flow = nil
                        tab = .feed
                    }
                )
            }
        }
    }

    private func onTab(_ t: SpoolTab) {
        if t == .rank {
            rankMovie = nil
            rankTier = nil
            rankMoods = []
            rankLine = ""
            flow = .entry
        } else {
            tab = t
        }
    }

    private var paletteToggle: some View {
        Button {
            mode = (mode == .paper) ? .dark : .paper
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
