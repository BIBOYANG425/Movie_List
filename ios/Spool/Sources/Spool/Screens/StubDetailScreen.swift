import SwiftUI

public struct StubDetailScreen: View {
    public var stub: WatchedDay
    public var onClose: () -> Void
    public var onShare: () -> Void

    public init(stub: WatchedDay, onClose: @escaping () -> Void, onShare: @escaping () -> Void) {
        self.stub = stub
        self.onClose = onClose
        self.onShare = onShare
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                HStack {
                    Button("← APRIL", action: onClose)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.ink)
                    Spacer()
                    Button("SHARE ↗", action: onShare)
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
                            movie: Movie(id: stub.title, title: stub.title, year: 2023,
                                         director: "celine song", seed: 0),
                            tier: stub.tier,
                            line: "cried on the 6 train.",
                            moods: ["tender","devastating"],
                            date: "APR · 18 · 2026",
                            stubNo: "#0127"
                        )
                        .rotationEffect(.degrees(-1.2))

                        Text("— FRIENDS WHO ALSO WATCHED —")
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

                        Text("— NOTES —")
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
                    .padding(.bottom, 110)
                }
            }
        }
    }
}

struct FriendTierChip: View {
    let handle: String
    let tier: Tier
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 6) {
                StripedAvatar(size: 22)
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
