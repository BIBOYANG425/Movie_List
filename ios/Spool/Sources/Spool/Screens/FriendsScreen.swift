import SwiftUI

public struct FriendsScreen: View {
    public var onOpenTwin: (Friend) -> Void
    public var onOpenProfile: (Friend) -> Void

    @State private var state: LoadState = .loading
    @State private var friends: [Friend] = []
    @State private var hasSession: Bool = false

    public init(onOpenTwin: @escaping (Friend) -> Void = { _ in },
                onOpenProfile: @escaping (Friend) -> Void = { _ in }) {
        self.onOpenTwin = onOpenTwin
        self.onOpenProfile = onOpenProfile
    }

    enum LoadState { case loading, loaded, fallback, empty }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "friends") {
                    SpoolPill("+ add", size: .sm)
                }
                ScrollView {
                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 110)
                }
                .refreshable { await reload() }
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            // Minimal placeholder — avoids flashing fixtures for signed-in users
            // before the first fetch resolves.
            Color.clear.frame(height: 1)
        case .empty:
            signedInEmptyState
        case .loaded, .fallback:
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader
                ForEach(friends) { f in
                    FriendRow(
                        friend: f,
                        action: { onOpenTwin(f) },
                        onOpenProfile: { onOpenProfile(f) }
                    )
                }
            }
        }
    }

    private var sectionHeader: some View {
        SpoolThemeReader { t, _ in
            Text(state == .fallback
                 ? "DEMO TWINS · SIGN IN FOR REAL FRIENDS"
                 : "YOUR TASTE TWINS · \(friends.count)")
                .font(SpoolFonts.mono(10))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
        }
    }

    private var signedInEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text("NO TWINS YET")
                    .font(SpoolFonts.mono(11))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                Text("follow someone to see how your tastes compare.")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private func reload() async {
        let userID = await SpoolClient.currentUserID()
        hasSession = userID != nil
        NSLog("[FriendsScreen] reload: userID=\(userID?.uuidString ?? "nil")")

        guard let userID else {
            friends = SpoolData.friends
            state = .fallback
            return
        }

        do {
            let followed = try await FollowRepository.shared.getFollowing(userID: userID)
            NSLog("[FriendsScreen] followed=\(followed.count)")
            if followed.isEmpty {
                friends = []
                state = .empty
                return
            }

            let targetIDs = followed.map(\.id)
            var scores: [UUID: Int] = [:]
            do {
                scores = try await TasteRepository.shared.getCompatibilityScores(
                    viewerID: userID, targetIDs: targetIDs
                )
                NSLog("[FriendsScreen] scores=\(scores.count)")
            } catch {
                NSLog("[FriendsScreen] scores FAIL: \(error)")
            }

            friends = followed.map { followed in
                Friend(
                    handle: followed.profile.handle,
                    name: followed.profile.displayedName,
                    twin: scores[followed.id] ?? 0,
                    userID: followed.id
                )
            }
            state = .loaded
        } catch {
            NSLog("[FriendsScreen] getFollowing FAIL: \(error)")
            friends = []
            state = .empty
        }
    }
}

struct FriendRow: View {
    let friend: Friend
    let action: () -> Void
    let onOpenProfile: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            // Outer button → taste twin (primary, keeps existing behavior).
            // Inner button on the handle text → read-only profile. Nesting
            // a button inside a button stays legible because SwiftUI hit-tests
            // the innermost tappable view first — tapping the handle opens
            // the profile, tapping anywhere else (avatar, twin %, card body)
            // still opens TwinScreen.
            Button(action: action) {
                HStack(spacing: 12) {
                    StripedAvatar(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Button(action: onOpenProfile) {
                            HStack(spacing: 4) {
                                Text(friend.handle)
                                    .font(SpoolFonts.serif(18))
                                    .foregroundStyle(t.ink)
                                Text("→")
                                    .font(SpoolFonts.mono(10))
                                    .foregroundStyle(t.inkSoft)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View \(friend.handle) profile")

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
