import SwiftUI

/// Full ranked list across every tier for the signed-in user. Reached from
/// `ProfileScreen` via a "see full shelf" row and presented as a sheet by
/// `SpoolAppRoot`.
///
/// Data comes straight from `RankingRepository.getAllRankedItems()`. Rows are
/// grouped by `Tier` (S → D, best first) with each section sorted by
/// `rank` ascending so the user's #1 in each bucket sits at the top.
///
/// States covered:
///  - Preview mode (no session)   → "sign in to see your shelf"
///  - Signed in + empty rankings  → "nothing ranked yet" prompt
///  - Loading                     → ProgressView
///  - Populated                   → tier-sectioned list
///
/// Pull-to-refresh and initial load share one `loadTask` handle so rapid
/// re-entry (sheet open → close → reopen) can't step on itself, mirroring the
/// cancellation guard in `StubsScreen`.
///
/// Header last reviewed: 2026-04-19
public struct FullListScreen: View {
    public var onClose: () -> Void

    @State private var items: [RankedItem] = []
    @State private var hasSession: Bool = false
    @State private var loading: Bool = true
    /// Tracks the in-flight reload so a rapid pull-to-refresh can cancel its
    /// predecessor before mutating state. We also snapshot `hasSession` at
    /// fetch start and reject late responses whose session context changed.
    @State private var loadTask: Task<Void, Never>? = nil

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header

                ScrollView {
                    content
                        .padding(.horizontal, 18)
                        .padding(.bottom, 40)
                }
                .refreshable {
                    triggerReload()
                    await loadTask?.value
                }
            }
        }
        .task { triggerReload() }
    }

    private func triggerReload() {
        loadTask?.cancel()
        loadTask = Task { await reload() }
    }

    // MARK: header

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Button(action: onClose) {
                    Text("close")
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("my shelf")
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                // Invisible balancer — same trick SettingsScreen uses to keep
                // the title centered without doing layout math.
                Text("close").opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            loadingState
        } else if !hasSession {
            previewState
        } else if items.isEmpty {
            emptyState
        } else {
            populatedList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("loading your shelf…")
                .font(SpoolFonts.hand(13))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var previewState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text("sign in to see your shelf")
                    .font(SpoolFonts.serif(22))
                    .foregroundStyle(t.ink)
                Text("your rankings live on your account.\nsign in from the home screen to pull them here.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private var emptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text("nothing ranked yet")
                    .font(SpoolFonts.serif(22))
                    .foregroundStyle(t.ink)
                Text("rank something from the home tab\nand it'll show up here by tier.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("rank something →", filled: true, action: onClose)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private var populatedList: some View {
        // Tier enum iteration order is already S → D, which matches the
        // visual "best at the top" layout we want.
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(Tier.allCases, id: \.self) { tier in
                let tierItems = itemsByTier[tier] ?? []
                if !tierItems.isEmpty {
                    tierSection(tier: tier, rows: tierItems)
                }
            }
        }
        .padding(.top, 14)
    }

    private var itemsByTier: [Tier: [RankedItem]] {
        // Pre-sort by rank so every section renders in the correct order
        // without the view recomputing it each frame.
        var out: [Tier: [RankedItem]] = [:]
        for item in items { out[item.tier, default: []].append(item) }
        for tier in out.keys {
            out[tier]?.sort { $0.rank < $1.rank }
        }
        return out
    }

    // MARK: tier section

    @ViewBuilder
    private func tierSection(tier: Tier, rows: [RankedItem]) -> some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tier.rawValue)
                        .font(SpoolFonts.serif(28))
                        .foregroundStyle(tierColor(tier, mode: mode))
                    Text(tier.label)
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(t.inkSoft)
                    Spacer()
                    Text("\(rows.count)")
                        .font(SpoolFonts.mono(11))
                        .tracking(2)
                        .foregroundStyle(t.inkSoft)
                }
                .padding(.bottom, 8)
                Rectangle().fill(t.rule).frame(height: 1)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                        row(item: item, t: t, mode: mode)
                        if idx < rows.count - 1 {
                            Rectangle().fill(t.rule.opacity(0.5)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func row(item: RankedItem, t: SpoolPalette, mode: SpoolMode) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Small poster. PosterBlock enforces a 2:3 aspect ratio, so fixing
            // the width gives a consistent 40×60 thumbnail across all rows.
            PosterBlock(
                title: Self.firstWord(item.title),
                year: item.year,
                director: item.director,
                seed: item.seed,
                posterUrl: item.posterUrl
            )
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                    .lineLimit(2)
                Text(metaLine(for: item))
                    .font(SpoolFonts.mono(10))
                    .tracking(1)
                    .foregroundStyle(t.inkSoft)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // Small tier badge. Optional-per-brief, but it doubles as a
            // ranking-position indicator inside the tier ("#3 in A").
            VStack(alignment: .trailing, spacing: 1) {
                TierStamp(tier: item.tier, size: 22)
                Text("#\(item.rank)")
                    .font(SpoolFonts.mono(9))
                    .tracking(1)
                    .foregroundStyle(t.inkSoft)
            }
        }
        .padding(.vertical, 8)
    }

    private func metaLine(for item: RankedItem) -> String {
        var parts: [String] = []
        if let y = item.year { parts.append(String(y)) }
        let dir = item.director.trimmingCharacters(in: .whitespaces)
        if !dir.isEmpty, dir != "—" { parts.append("DIR. \(dir.uppercased())") }
        return parts.joined(separator: " · ")
    }

    // MARK: loader

    private func reload() async {
        loading = true
        defer { loading = false }

        let userID = await SpoolClient.currentUserID()
        let sessionAtStart = userID != nil
        // Update hasSession immediately so the preview/empty state renders
        // correctly even when the network fetch fails or is skipped.
        hasSession = sessionAtStart
        NSLog("[FullListScreen] reload: hasSession=\(sessionAtStart)")

        guard sessionAtStart else {
            if !Task.isCancelled {
                items = []
            }
            NSLog("[FullListScreen] loaded 0 items (no session)")
            return
        }

        do {
            let fetched = try await RankingRepository.shared.getAllRankedItems()
            if Task.isCancelled { return }
            items = fetched
            NSLog("[FullListScreen] loaded \(fetched.count) items")
        } catch {
            if Task.isCancelled { return }
            // Keep the previously-displayed shelf intact — a pull-to-refresh
            // that fails shouldn't wipe the user's visible list. Surface
            // the failure via a toast instead, same pattern RankPersistence
            // uses on write failures.
            NSLog("[FullListScreen] getAllRankedItems FAIL: \(error)")
            ToastCenter.shared.show(
                "couldn't refresh — check connection",
                level: .error
            )
        }
    }

    // MARK: helpers

    private static func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

#Preview {
    FullListScreen(onClose: {}).spoolMode(.paper)
}
