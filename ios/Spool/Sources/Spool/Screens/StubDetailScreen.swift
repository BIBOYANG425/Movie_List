import SwiftUI

public struct StubDetailScreen: View {
    public var stub: WatchedDay
    public var onClose: () -> Void
    public var onShare: () -> Void

    /// The signed-in user's own `@handle`, stamped onto the stub card. Loaded
    /// from the real profile on `.task`; empty until it resolves (and in preview
    /// / signed-out mode) so the card omits the handle rather than showing the
    /// old "@yurui" default. Mirrors StubShareScreen.loadHandle.
    @State private var handle: String = ""

    public init(stub: WatchedDay, onClose: @escaping () -> Void, onShare: @escaping () -> Void) {
        self.stub = stub
        self.onClose = onClose
        self.onShare = onShare
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                HStack {
                    Button(L10n.t("stubDetail.back"), action: onClose)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.ink)
                    Spacer()
                    Button(L10n.t("stubDetail.share"), action: onShare)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.ink)
                }
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        AdmitStub(
                            movie: Movie(id: stub.title, title: stub.title, year: stub.year ?? 2026,
                                         director: "—", seed: 0),
                            tier: stub.tier,
                            line: "",
                            moods: [],
                            // Use the real watched_date passed through via
                            // WatchedDay.year/month/day when available; fall
                            // back to the day-only label for legacy fixtures
                            // that don't carry full date info.
                            date: Self.formatDate(day: stub.day, month: stub.month, year: stub.year),
                            // Signed-in user's own handle (loaded on `.task`);
                            // empty until it resolves → the card omits it rather
                            // than showing the "@yurui" default.
                            handle: handle,
                            // Day-of-month alone collapses to the same ID
                            // for different stubs, so encode the full date
                            // as YYYYMMDD when it's available. Fixture
                            // rows without year/month still get a stable
                            // day-only number so the label isn't blank.
                            stubNo: Self.stubNumber(day: stub.day, month: stub.month, year: stub.year)
                        )
                        .rotationEffect(.degrees(-1.2))

                        Text(L10n.t("stubDetail.friendsWatched"))
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 20)

                        HStack(spacing: 10) {
                            FriendTierChip(handle: "@mei", tier: .S)
                            FriendTierChip(handle: "@jay", tier: .A)
                            FriendTierChip(handle: "@ana", tier: .S)
                        }
                        .padding(.top, 8)

                        Text(L10n.t("stubDetail.notes"))
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 18)

                        Text("metrograph w/ @jay · almost missed the last train home.")
                            .font(SpoolFonts.script(22))
                            .foregroundStyle(SpoolTokens.paper.accent)
                            .lineSpacing(4)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    // This screen renders with the bottom bar HIDDEN
                    // (`navHidden` in SpoolAppRoot), so the old 110 over-reserved
                    // for a nav that isn't here. The ScrollView already stops at
                    // the home-indicator safe area; a small breathing pad is all
                    // that's needed (was 110).
                    .padding(.bottom, 12)
                }
            }
        }
        .task { await loadHandle() }
    }

    /// Resolve the signed-in user's own handle from the real profile so the stub
    /// card is stamped with their `@handle`, never the literal "@yurui". No-op
    /// (leaves `handle` empty) when signed out or in preview mode.
    private func loadHandle() async {
        if let profile = try? await ProfileRepository.shared.getMyProfile() {
            await MainActor.run { handle = profile.handle }
        }
    }
}

extension StubDetailScreen {
    /// `#YYYYMMDD` when we have the full date, `#DD` when we only have a
    /// day (fixtures). Guarantees different-day stubs get different IDs.
    static func stubNumber(day: Int, month: Int?, year: Int?) -> String {
        guard let month, let year else {
            return "#\(String(format: "%02d", max(day, 0)))"
        }
        return "#\(String(format: "%04d%02d%02d", year, month, max(day, 0)))"
    }

    /// "APR · 18 · 2026" style format. If year or month are missing (fixture
    /// rows), returns a day-only fallback so we don't render a misleading
    /// full date with placeholder values.
    static func formatDate(day: Int, month: Int?, year: Int?) -> String {
        guard let month, let year else {
            return "DAY · \(String(format: "%02d", max(day, 0)))"
        }
        let months = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let m = (1...12).contains(month) ? months[month] : "—"
        return "\(m) · \(String(format: "%02d", day)) · \(year)"
    }
}

struct FriendTierChip: View {
    let handle: String
    let tier: Tier
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 6) {
                StripedAvatar(size: 22, name: handle)
                Text(handle).font(SpoolFonts.hand(12))
                TierStamp(tier: tier, size: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(t.rule, lineWidth: 1.5))
        }
    }
}

#Preview {
    StubDetailScreen(
        stub: SpoolData.aprilWatched.first { $0.day == 18 }!,
        onClose: {},
        onShare: {}
    )
    .spoolMode(.paper)
}
