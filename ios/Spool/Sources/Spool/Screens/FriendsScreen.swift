import SwiftUI

public struct FriendsScreen: View {
    public var onOpenTwin: (Friend) -> Void

    public init(onOpenTwin: @escaping (Friend) -> Void = { _ in }) {
        self.onOpenTwin = onOpenTwin
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "friends") {
                    SpoolPill("+ add", size: .sm)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR TASTE TWINS · 14")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)

                        ForEach(SpoolData.friends) { f in
                            FriendRow(friend: f) { onOpenTwin(f) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
    }
}

struct FriendRow: View {
    let friend: Friend
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                HStack(spacing: 12) {
                    StripedAvatar(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(friend.handle)
                            .font(SpoolFonts.serif(18))
                            .foregroundStyle(t.ink)
                        HStack(spacing: 2) {
                            Text("last watched")
                            Text("Past Lives").italic()
                            Text("· S")
                        }
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(friend.twin)%")
                            .font(SpoolFonts.serif(22))
                            .foregroundStyle(t.accent)
                        Text("TWIN")
                            .font(SpoolFonts.mono(9))
                            .tracking(1)
                            .foregroundStyle(t.inkSoft)
                    }
                }
                .padding(12)
                .background(t.cream)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    FriendsScreen(onOpenTwin: { _ in }).spoolMode(.paper)
}
