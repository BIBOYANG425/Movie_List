import SwiftUI

// MARK: - 01 Cold Open

struct OnbColdOpen: View {
    var onNext: () -> Void

    var body: some View {
        ZStack {
            // curtain stripes
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: stride(from: 0, to: 30, by: 1).map { i in
                            i.isMultiple(of: 2) ? OnbTheater.curtainA : OnbTheater.curtainB
                        },
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .blendMode(.multiply)
                .ignoresSafeArea()
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 20)
                MarqueeBulbs()

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(OnbTheater.gold, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(OnbTheater.bg.opacity(0.85))
                        )

                    VStack(spacing: 0) {
                        MarqueeBulbs(count: 10)
                            .padding(.top, 6)
                        Spacer(minLength: 10)

                        Text("TONIGHT · ONLY")
                            .font(SpoolFonts.mono(11))
                            .tracking(5.5)
                            .foregroundStyle(OnbTheater.gold.opacity(0.85))

                        Text("Spool")
                            .font(SpoolFonts.serif(74))
                            .tracking(-2)
                            .foregroundStyle(OnbTheater.cream)
                            .padding(.top, 10)

                        Text("a private picture palace\nof everything you watch.")
                            .font(SpoolFonts.script(22))
                            .foregroundStyle(OnbTheater.gold)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .padding(.top, 8)

                        Text("DOORS OPEN · 9:41")
                            .font(SpoolFonts.mono(10))
                            .tracking(4)
                            .foregroundStyle(OnbTheater.gold.opacity(0.6))
                            .padding(.top, 16)

                        Spacer(minLength: 10)
                        MarqueeBulbs(count: 10)
                            .padding(.bottom, 6)
                    }
                    .padding(.horizontal, 18)
                }
                .frame(height: 290)
                .padding(.horizontal, 20)
                .padding(.top, 26)

                Text("no sign-up yet.\nrank first. we'll talk later.")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(OnbTheater.cream.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 42)

                Spacer()

                Button(action: onNext) {
                    Text("take your seat ↘")
                        .font(SpoolFonts.serif(20))
                        .tracking(0.8)
                        .foregroundStyle(OnbTheater.bg)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(OnbTheater.gold))
                        .overlay(Capsule().stroke(OnbTheater.cream, lineWidth: 2))
                        .shadow(color: OnbTheater.gold.opacity(0.35), radius: 0, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 48)
            }
            .padding(.top, 50)
        }
        .background(OnbTheater.bg)
    }
}

// MARK: - Sign In (inserted after "take your seat")

public enum SignInResult { case signedIn, skipped }

/// Step 1 of onboarding. Framing copy + progress dots + skip link live here;
/// the email/password form itself is the shared `SignInFormBody` used by
/// `SignInSheet` so the two surfaces stay in lockstep.
struct OnbSignInScreen: View {
    var onDone: (SignInResult) -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OnbDots(step: 8)

                        Text("— RESERVE YOUR SEAT —")
                            .font(SpoolFonts.mono(10))
                            .tracking(4)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 28)

                        Text("your ticket,\nyour shelf.")
                            .font(SpoolFonts.serif(46))
                            .tracking(-1.4)
                            .foregroundStyle(t.ink)
                            .lineSpacing(-4)
                            .padding(.top, 18)

                        Text("save your stubs across devices.\nfind friends' shelves. pick up where you left off.")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)
                            .lineSpacing(3)
                            .padding(.top, 10)

                        SignInFormBody(onSuccess: { onDone(.signedIn) })
                            .padding(.top, 28)

                        Button(action: { onDone(.skipped) }) {
                            Text("continue without account — preview only")
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(t.inkSoft)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                        .padding(.bottom, 60)
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
    }
}

// MARK: - 02 Manifesto

struct OnbManifesto: View {
    var onNext: () -> Void
    var body: some View {
        SpoolThemeReader { t, mode in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    OnbDots(step: 1)

                    Text("— THE RULES —")
                        .font(SpoolFonts.mono(10))
                        .tracking(4)
                        .foregroundStyle(t.inkSoft)
                        .padding(.top, 30)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    (Text("no stars.\n")
                        + Text("no algorithm.").foregroundColor(t.accent) + Text("\n")
                        + Text("just tiers."))
                        .font(SpoolFonts.serif(52))
                        .tracking(-1.6)
                        .lineSpacing(-8)
                        .foregroundStyle(t.ink)
                        .padding(.top, 22)

                    HStack(spacing: 6) {
                        ForEach(Tier.allCases, id: \.self) { k in
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(t.cream2)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.ink, lineWidth: 1.5))
                                TierStamp(tier: k, size: 44)
                            }
                            .frame(width: 58, height: 58)
                        }
                    }
                    .padding(.top, 26)

                    (Text("every ranking prints a ticket.\n")
                        + Text("keep them. argue them. stack them.").foregroundColor(t.accent))
                        .font(SpoolFonts.script(24))
                        .lineSpacing(2)
                        .foregroundStyle(t.ink)
                        .padding(.top, 28)

                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 50)
            }
            .overlay(alignment: .bottom) {
                OnbFoot(label: "start ranking →", onNext: onNext)
            }
        }
    }
}

// MARK: - 03 Grid tap

public struct OnbPick: Hashable, Sendable {
    public let movie: TMDBMovie
    public let tier: Tier
}

struct OnbGrid: View {
    var onNext: ([OnbPick]) -> Void

    @State private var suggestions: [TMDBMovie] = []
    @State private var picks: [Int: Tier] = [:]
    @State private var selected: Tier = .S
    @State private var loading: Bool = true

    private let tierOptions: [Tier] = [.S, .A, .B, .C, .D]

    /// Fallback pool used when `TMDB_API_KEY` isn't set or the network fails.
    /// Same titles the HTML prototype showed so the demo path stays consistent.
    private static let fallbackPool: [TMDBMovie] = [
        .fixture(id: "fx_past_lives",    title: "Past Lives",                year: 2023, seed: 0),
        .fixture(id: "fx_itmfl",         title: "In the Mood for Love",      year: 2000, seed: 2),
        .fixture(id: "fx_portrait",      title: "Portrait of a Lady on Fire",year: 2019, seed: 7),
        .fixture(id: "fx_moonlight",     title: "Moonlight",                 year: 2016, seed: 4),
        .fixture(id: "fx_challengers",   title: "Challengers",               year: 2024, seed: 5),
        .fixture(id: "fx_paris_texas",   title: "Paris, Texas",              year: 1984, seed: 8),
        .fixture(id: "fx_poor_things",   title: "Poor Things",               year: 2023, seed: 3),
        .fixture(id: "fx_drive",         title: "Drive",                     year: 2011, seed: 6),
        .fixture(id: "fx_aftersun",      title: "Aftersun",                  year: 2022, seed: 1),
        .fixture(id: "fx_dune_2",        title: "Dune Pt 2",                 year: 2024, seed: 5),
        .fixture(id: "fx_parasite",      title: "Parasite",                  year: 2019, seed: 2),
        .fixture(id: "fx_lady_bird",     title: "Lady Bird",                 year: 2017, seed: 3),
    ]

    var body: some View {
        SpoolThemeReader { t, mode in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OnbDots(step: 2)

                        Text("seen it? tier it.")
                            .font(SpoolFonts.serif(26))
                            .tracking(-0.5)
                            .foregroundStyle(t.ink)
                            .padding(.top, 18)

                        (Text("pick tier ")
                            + Text(selected.rawValue).foregroundColor(tierColor(selected, mode: mode)).bold()
                            + Text(" films below. tap to toggle."))
                            .font(SpoolFonts.hand(12))
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 3)

                        HStack(spacing: 6) {
                            ForEach(tierOptions, id: \.self) { T in
                                Button(action: { selected = T }) {
                                    Text(T.rawValue)
                                        .font(SpoolFonts.serif(22))
                                        .foregroundStyle(tierColor(T, mode: mode))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8).fill(selected == T ? t.cream2 : .clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selected == T ? t.ink : t.rule, lineWidth: 1.5)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 10)

                        if loading && suggestions.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().tint(t.accent)
                                Text("loading this week's picks…")
                                    .font(SpoolFonts.hand(12))
                                    .foregroundStyle(t.inkSoft)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 14) {
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { i, m in
                                    gridItem(i: i, m: m, mode: mode, t: t)
                                }
                            }
                            .padding(.top, 12)
                        }

                        Text("\(picks.count) tiered · pick at least 4")
                            .font(SpoolFonts.mono(10))
                            .tracking(1.5)
                            .foregroundStyle(t.inkSoft)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                            .padding(.bottom, 140)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 50)
                }
            }
            .overlay(alignment: .bottom) {
                OnbFoot(
                    label: picks.count >= 4 ? "good taste →" : "need 4",
                    disabled: picks.count < 4,
                    onNext: finish
                )
            }
            .task {
                await load()
            }
        }
    }

    @ViewBuilder
    private func gridItem(i: Int, m: TMDBMovie, mode: SpoolMode, t: SpoolPalette) -> some View {
        let tier = picks[i]
        Button {
            if tier == selected { picks.removeValue(forKey: i) }
            else { picks[i] = selected }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    PosterBlock(
                        title: m.title.split(separator: " ").first.map(String.init) ?? m.title,
                        year: Int(m.year),
                        director: "",
                        seed: abs(m.tmdbId) % 12,
                        posterUrl: m.posterUrl
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tier != nil ? tierColor(tier!, mode: mode) : t.rule,
                                    lineWidth: tier != nil ? 3 : 1)
                    )
                    if let tier {
                        Text(tier.rawValue)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.cream)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(tierColor(tier, mode: mode)))
                            .overlay(Circle().stroke(t.ink, lineWidth: 1.5))
                            .offset(x: 6, y: -6)
                    }
                }
                Text(m.title)
                    .font(SpoolFonts.serif(11))
                    .foregroundStyle(t.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if !suggestions.isEmpty { return }
        loading = true
        let results = await TMDBService.getGenericSuggestions()
        await MainActor.run {
            suggestions = results.isEmpty ? Self.fallbackPool : results
            loading = false
        }
    }

    private func finish() {
        let list: [OnbPick] = picks
            .compactMap { (idx, tier) -> OnbPick? in
                guard idx < suggestions.count else { return nil }
                return OnbPick(movie: suggestions[idx], tier: tier)
            }
            .sorted { tierOrder($0.tier) < tierOrder($1.tier) }
        onNext(list)
    }

    private func tierOrder(_ t: Tier) -> Int {
        switch t { case .S: 0; case .A: 1; case .B: 2; case .C: 3; case .D: 4 }
    }
}

extension TMDBMovie {
    /// Local fallback when TMDB is unreachable — posterUrl nil so PosterBlock's
    /// synthetic palette kicks in.
    static func fixture(id: String, title: String, year: Int, seed: Int) -> TMDBMovie {
        TMDBMovie(
            id: id, tmdbId: -abs(id.hashValue), title: title,
            year: String(year), posterUrl: nil, genres: [],
            overview: "", voteAverage: nil
        )
        // seed is derived from tmdbId in gridItem; for fixtures we use the provided
        // seed via a second hashing but the simple negative-id stands in fine.
        // (seed arg kept for readability / future switch.)
    }
}

// MARK: - 04 Head-to-head (multi-round, king-of-the-hill)

struct OnbH2H: View {
    var contenders: [TMDBMovie]
    /// Called when the H2H round ends. `winner` is the final champion (nil when
    /// we skip the round because there were fewer than 2 contenders). `losers`
    /// is the other contenders in elimination order — the earliest eliminated
    /// first, so the caller can assign rank_position 2..N in that order.
    var onNext: (_ winner: TMDBMovie?, _ losers: [TMDBMovie]) -> Void

    // Sort state: champion keeps winning; each challenger steps up until all
    // contenders have faced the champion. Number of matches = N - 1.
    @State private var championIdx: Int = 0
    @State private var challengerIdx: Int = 1
    @State private var picked: Side? = nil
    /// Losers in elimination order — appended when a match resolves.
    @State private var losers: [TMDBMovie] = []

    private enum Side { case champion, challenger }

    private var totalMatches: Int { max(0, contenders.count - 1) }
    private var currentMatch: Int {
        // challengerIdx-1 = zero-based index of the current round.
        max(0, challengerIdx - 1)
    }
    private var isLastMatch: Bool { challengerIdx == contenders.count - 1 }
    private var shouldSkip: Bool { contenders.count < 2 }

    var body: some View {
        SpoolThemeReader { t, mode in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                VStack(spacing: 0) {
                    OnbDots(step: 3)

                    Text("— HEAD TO HEAD · MATCH \(currentMatch + 1) OF \(totalMatches) —")
                        .font(SpoolFonts.mono(10))
                        .tracking(3)
                        .foregroundStyle(t.inkSoft)
                        .padding(.top, 22)

                    Text("which do you love more?")
                        .font(SpoolFonts.serif(26))
                        .tracking(-0.5)
                        .foregroundStyle(t.ink)
                        .padding(.top, 6)

                    if contenders.count >= 2,
                       championIdx < contenders.count,
                       challengerIdx < contenders.count {
                        HStack(spacing: 10) {
                            card(side: .champion,  label: championLabel,
                                 m: contenders[championIdx], mode: mode, t: t)
                            card(side: .challenger, label: "CHALLENGER",
                                 m: contenders[challengerIdx], mode: mode, t: t)
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                        ZStack {
                            Circle()
                                .fill(t.cream2)
                                .overlay(Circle().stroke(t.ink, lineWidth: 1.5))
                                .frame(width: 54, height: 54)
                            Text("vs")
                                .font(SpoolFonts.serif(24))
                                .foregroundStyle(t.ink)
                        }
                        .padding(.top, 12)

                        Text("winner stays. we climb the ladder.\n\(contenders.count - challengerIdx - 1) more to go.")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.top, 16)
                    } else {
                        Text("need more picks to compare — skip ahead.")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 60)
                    }

                    Spacer()
                }
                .padding(.top, 50)
            }
            .overlay(alignment: .bottom) {
                OnbFoot(
                    label: ctaLabel,
                    disabled: !shouldSkip && picked == nil,
                    onNext: advance
                )
            }
        }
    }

    private var championLabel: String {
        currentMatch == 0 ? "OPENER" : "REIGNING CHAMPION"
    }

    private var ctaLabel: String {
        if shouldSkip { return "skip →" }
        if picked == nil { return "pick one" }
        return isLastMatch ? "crown winner →" : "next matchup →"
    }

    private func advance() {
        guard let picked else {
            if shouldSkip { onNext(contenders.first, []) }
            return
        }
        // Record the loser of this match in elimination order.
        let loser = (picked == .champion) ? contenders[challengerIdx] : contenders[championIdx]
        losers.append(loser)
        // Apply the choice: if challenger won, they become champion.
        if picked == .challenger {
            championIdx = challengerIdx
        }
        let next = challengerIdx + 1
        if next >= contenders.count {
            // All matchups done — hand back the final champion + eliminated
            // contenders in the order they fell.
            let winner = contenders[championIdx]
            onNext(winner, losers)
        } else {
            challengerIdx = next
            self.picked = nil
        }
    }

    @ViewBuilder
    private func card(side: Side, label: String, m: TMDBMovie,
                      mode: SpoolMode, t: SpoolPalette) -> some View {
        let chosen = picked == side
        let tilt: Double = side == .champion ? -2 : 2
        Button { picked = side } label: {
            VStack(spacing: 6) {
                PosterBlock(
                    title: m.title.split(separator: " ").first.map(String.init) ?? m.title,
                    year: Int(m.year),
                    director: "",
                    seed: abs(m.tmdbId) % 12,
                    posterUrl: m.posterUrl
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(chosen ? t.accent : t.ink, lineWidth: 2)
                )
                .shadow(color: chosen ? t.accent.opacity(0.3) : .black.opacity(0.1),
                        radius: 0, x: 0, y: chosen ? 6 : 2)

                Text(label)
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                Text(m.title)
                    .font(SpoolFonts.serif(15))
                    .foregroundStyle(t.ink)
                    .multilineTextAlignment(.center)
                if chosen {
                    Text("picked ✓")
                        .font(SpoolFonts.script(24))
                        .foregroundStyle(t.accent)
                }
            }
            .rotationEffect(.degrees(tilt))
            .scaleEffect(chosen ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: chosen)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 05 Print animation

struct OnbPrint: View {
    var onNext: () -> Void
    @State private var stage: Int = 0

    var body: some View {
        SpoolThemeReader { t, mode in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                VStack(spacing: 0) {
                    OnbDots(step: 4)

                    Text(stage < 2 ? "printing…" : "your first stub.")
                        .font(SpoolFonts.script(28))
                        .foregroundStyle(t.accent)
                        .padding(.top, 22)

                    Text(stage < 2 ? "DO NOT DISTURB" : "TEAR HERE ✂ · · · · · ·")
                        .font(SpoolFonts.mono(10))
                        .tracking(3)
                        .foregroundStyle(t.inkSoft)
                        .padding(.top, 6)

                    ZStack(alignment: .top) {
                        RoundedCorners(tl: 8, tr: 8, bl: 0, br: 0)
                            .fill(t.ink)
                            .frame(height: 14)
                            .overlay(
                                Capsule().fill(t.cream)
                                    .frame(width: 180, height: 3)
                                    .offset(y: -1)
                            )
                            .padding(.horizontal, 22)
                            .zIndex(3)

                        AdmitStub(
                            movie: Movie(id: "new", title: "Past Lives", year: 2023, director: "celine song"),
                            tier: .S, line: "lost myself on the 6 train.",
                            moods: ["tender", "devastating"],
                            date: "TODAY", handle: "@you", stubNo: "#0001"
                        )
                        .offset(y: stage >= 1 ? 14 : -80)
                        .opacity(stage >= 1 ? 1 : 0.3)
                        .blur(radius: stage == 0 ? 1 : 0)
                        .animation(.easeInOut(duration: 1.1), value: stage)
                        .padding(.horizontal, 22)

                        if stage >= 2 {
                            stampView(mode: mode)
                                .offset(x: 80, y: 110)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.top, 24)

                    (Text("one down. \n")
                        + Text("119 to go this year.").foregroundColor(t.accent))
                        .font(SpoolFonts.serif(22))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(t.ink)
                        .padding(.top, 24)
                        .padding(.horizontal, 32)

                    Spacer()
                }
                .padding(.top, 50)
            }
            .overlay(alignment: .bottom) {
                OnbFoot(label: "keep going →", onNext: onNext)
            }
            .task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                withAnimation { stage = 1 }
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation { stage = 2 }
            }
        }
    }

    @ViewBuilder
    private func stampView(mode: SpoolMode) -> some View {
        let c = tierColor(.S, mode: mode)
        Text("STAMPED")
            .font(SpoolFonts.mono(10))
            .tracking(2)
            .foregroundStyle(c)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(c, lineWidth: 2.5))
            .rotationEffect(.degrees(-18))
            .opacity(0.8)
    }
}

private struct RoundedCorners: Shape {
    var tl: CGFloat = 0; var tr: CGFloat = 0
    var bl: CGFloat = 0; var br: CGFloat = 0
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr),
                 radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br),
                 radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl),
                 radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl),
                 radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - 06 Identity

struct OnbIdentity: View {
    var onNext: (String) -> Void
    @State private var handle: String = "yurui"
    @State private var walkOut: String = ""
    @State private var defend: String = ""

    @ViewBuilder
    private var handleField: some View {
        #if os(iOS)
        TextField("yourname", text: $handle)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
        #else
        TextField("yourname", text: $handle)
        #endif
    }

    var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OnbDots(step: 5)

                        Text("— WHO SHALL WE SEAT? —")
                            .font(SpoolFonts.mono(10))
                            .tracking(4)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 30)

                        Text("and you are…?")
                            .font(SpoolFonts.serif(46))
                            .tracking(-1.4)
                            .foregroundStyle(t.ink)
                            .padding(.top, 22)

                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("@")
                                .font(SpoolFonts.serif(42))
                                .foregroundStyle(t.inkSoft)
                            handleField
                                .font(SpoolFonts.serif(42))
                                .tracking(-0.8)
                                .foregroundStyle(t.ink)
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(t.ink).frame(height: 2)
                        }
                        .padding(.top, 36)

                        HStack {
                            Text("AVAILABLE ✓")
                                .font(SpoolFonts.mono(10))
                                .tracking(2)
                                .foregroundStyle(t.inkSoft)
                            Spacer()
                            Text("\(handle.count)/24")
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(t.inkSoft)
                        }
                        .padding(.top, 10)

                        questionField(q: "the one movie\nyou'd walk out of?", text: $walkOut, t: t)
                            .padding(.top, 36)

                        questionField(q: "the one you'll\ndefend to the grave?", text: $defend, t: t)
                            .padding(.top, 26)

                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 50)
                }
            }
            .overlay(alignment: .bottom) {
                OnbFoot(label: "that's me →", disabled: handle.isEmpty) {
                    onNext(handle)
                }
            }
        }
    }

    @ViewBuilder
    private func questionField(q: String, text: Binding<String>, t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(q)
                .font(SpoolFonts.serif(22))
                .tracking(-0.3)
                .lineSpacing(-2)
                .foregroundStyle(t.ink)

            TextField("type anything…", text: text)
                .font(SpoolFonts.script(22))
                .foregroundStyle(t.accent)
                .textFieldStyle(.plain)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(t.ink)
                        .frame(height: 1.5)
                }
        }
    }
}

// MARK: - 07 Twins

struct OnbTwins: View {
    var onNext: () -> Void

    private let twins: [(name: String, handle: String, twin: Int)] = [
        ("jay patel", "jpatel", 64),
        ("ana ruiz", "anaruiz", 58),
        ("theo lin", "theolin", 41),
    ]

    var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OnbDots(step: 6)

                        Text("— SCORED FROM YOUR TIERS —")
                            .font(SpoolFonts.mono(10))
                            .tracking(3)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 30)

                        Text("your taste twins.")
                            .font(SpoolFonts.serif(36))
                            .tracking(-1)
                            .foregroundStyle(t.ink)
                            .padding(.top, 8)

                        Text("people who'd fight you on the same films.")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 6)

                        ZStack(alignment: .topTrailing) {
                            featuredCard(t: t)
                            Text("#1 TWIN")
                                .font(SpoolFonts.mono(10))
                                .tracking(2)
                                .foregroundStyle(t.cream)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(t.accent)
                                .clipShape(RoundedCorners(tl: 0, tr: 0, bl: 8, br: 0))
                        }
                        .padding(.top, 20)

                        VStack(spacing: 6) {
                            ForEach(twins, id: \.handle) { c in
                                twinRow(name: c.name, handle: c.handle, score: c.twin, t: t)
                            }
                        }
                        .padding(.top, 12)

                        Spacer(minLength: 140)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 50)
                }
            }
            .overlay(alignment: .bottom) {
                OnbFoot(label: "follow all →", onNext: onNext, onSkip: onNext)
            }
        }
    }

    @ViewBuilder
    private func featuredCard(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Circle()
                    .fill(LinearGradient(colors: [t.cream, Color(hex: 0xE5D3A8)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                    .overlay(Circle().stroke(t.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("mei chen").font(SpoolFonts.serif(22)).foregroundStyle(t.ink)
                    Text("@meichen")
                        .font(SpoolFonts.mono(11))
                        .tracking(0.8)
                        .foregroundStyle(t.inkSoft)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("72").font(SpoolFonts.serif(56)).foregroundStyle(t.accent)
                Text("% twin score").font(SpoolFonts.hand(18)).foregroundStyle(t.ink)
            }
            .padding(.top, 12)

            Text("you both S-tier'd Past Lives and ITMFL.\nyou disagree on Aftersun (she thinks it's C).")
                .font(SpoolFonts.hand(13))
                .lineSpacing(3)
                .foregroundStyle(t.inkSoft)
                .padding(.top, 6)
        }
        .padding(16)
        .background(t.cream2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.ink, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func twinRow(name: String, handle: String, score: Int, t: SpoolPalette) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(t.cream2)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(t.ink, lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(SpoolFonts.hand(13)).bold().foregroundStyle(t.ink)
                Text("@\(handle)").font(SpoolFonts.mono(9)).foregroundStyle(t.inkSoft)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(score)").font(SpoolFonts.serif(22)).foregroundStyle(t.accent)
                Text("%").font(SpoolFonts.mono(12)).foregroundStyle(t.inkSoft)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(t.cream)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
    }
}

// MARK: - 08 Season

struct OnbSeason: View {
    var handle: String
    var onNext: () -> Void

    var body: some View {
        ZStack {
            OnbTheater.bg.ignoresSafeArea()
            // spotlights
            RadialGradient(colors: [OnbTheater.gold.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.3, y: 0.2),
                           startRadius: 0, endRadius: 300)
                .ignoresSafeArea()
            RadialGradient(colors: [Color(hex: 0xCE3B1F).opacity(0.22), .clear],
                           center: UnitPoint(x: 0.7, y: 0.75),
                           startRadius: 0, endRadius: 300)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                Text("— COMING THIS YEAR —")
                    .font(SpoolFonts.mono(10))
                    .tracking(5)
                    .foregroundStyle(OnbTheater.gold)

                (Text("your\n")
                    + Text("2026").foregroundColor(OnbTheater.gold) + Text("\n")
                    + Text("season."))
                    .font(SpoolFonts.serif(76))
                    .tracking(-2.4)
                    .lineSpacing(-8)
                    .foregroundStyle(OnbTheater.cream)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)

                VStack(spacing: 0) {
                    Text("ADMIT · ONE")
                        .font(SpoolFonts.mono(10))
                        .tracking(3)
                        .foregroundStyle(OnbTheater.gold.opacity(0.8))

                    Text("@\(handle)")
                        .font(SpoolFonts.serif(28))
                        .tracking(-0.5)
                        .foregroundStyle(OnbTheater.cream)
                        .padding(.top, 10)

                    Text("row A · seat 0001")
                        .font(SpoolFonts.script(22))
                        .foregroundStyle(OnbTheater.gold)
                        .padding(.top, 4)

                    HStack(spacing: 18) {
                        goal(n: "120", label: "FILMS GOAL")
                        goal(n: "3",   label: "TWINS ADDED")
                        goal(n: "52",  label: "WEEKS AHEAD")
                    }
                    .padding(.top, 14)
                }
                .padding(16)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(OnbTheater.gold, lineWidth: 2))
                .padding(.horizontal, 24)
                .padding(.top, 30)

                Text("the reel is loaded.\nlights dimming…")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(OnbTheater.cream.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 26)

                Spacer()

                Button(action: onNext) {
                    Text("start spooling ▸")
                        .font(SpoolFonts.serif(22))
                        .tracking(0.8)
                        .foregroundStyle(OnbTheater.bg)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(OnbTheater.gold))
                        .overlay(Capsule().stroke(OnbTheater.cream, lineWidth: 2))
                        .shadow(color: OnbTheater.gold.opacity(0.35), radius: 0, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func goal(n: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(n)
                .font(SpoolFonts.serif(32))
                .foregroundStyle(OnbTheater.cream)
            Text(label)
                .font(SpoolFonts.mono(9))
                .tracking(2)
                .foregroundStyle(OnbTheater.gold.opacity(0.7))
        }
    }
}
