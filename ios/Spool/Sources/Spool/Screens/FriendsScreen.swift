import SwiftUI

public struct FriendsScreen: View {
    public var onOpenTwin: (Friend) -> Void
    public var onOpenProfile: (Friend) -> Void

    @State private var state: LoadState = .loading
    @State private var friends: [Friend] = []
    // Session presence is already captured by `state` (.fallback means no
    // session, everything else means signed-in), so a separate hasSession
    // flag would just duplicate that signal.

    public init(onOpenTwin: @escaping (Friend) -> Void = { _ in },
                onOpenProfile: @escaping (Friend) -> Void = { _ in }) {
        self.onOpenTwin = onOpenTwin
        self.onOpenProfile = onOpenProfile
    }

    /// - loading: first fetch in flight
    /// - loaded:  signed-in, has followed profiles
    /// - fallback: preview mode, showing SpoolData.friends
    /// - empty:   signed-in but follows zero profiles
    /// - error:   fetch failed; distinct from "empty" so users can retry
    enum LoadState { case loading, loaded, fallback, empty, error }

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
        case .error:
            errorState
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

    private var errorState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text("COULDN'T LOAD FRIENDS")
                    .font(SpoolFonts.mono(11))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                Text("pull to retry.")
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
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
        NSLog("[FriendsScreen] reload: hasSession=\(userID != nil)")

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
            // Network/RLS failure — distinct from "signed-in but follows
            // zero profiles". `.error` surfaces a retry prompt; keep
            // `friends` empty so we don't show stale rows next to an
            // error header.
            NSLog("[FriendsScreen] getFollowing FAIL: \(error)")
            friends = []
            state = .error
        }
    }
}

struct FriendRow: View {
    let friend: Friend
    let action: () -> Void
    let onOpenProfile: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            // Two tappable regions sharing one visual card. Using a plain
            // container + `.contentShape` + `.onTapGesture` for the card
            // body and an actual Button only for the handle avoids nesting
            // a Button inside a Button (which hides the inner one from
            // VoiceOver and causes odd focus rings).
            HStack(spacing: 12) {
                StripedAvatar(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    // Handle → read-only friend profile. Separate tappable
                    // so VoiceOver exposes it independently of the card body.
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
                    .accessibilityAddTraits(.isButton)

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
            // Card body → taste twin (primary). `contentShape` ensures the
            // full card (including Spacer regions) is tappable, not just
            // the text glyphs.
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open taste twin with \(friend.handle), \(friend.twin)% match")
            .accessibilityAddTraits(.isButton)
        }
    }
}

#Preview {
    FriendsScreen(onOpenTwin: { _ in }).spoolMode(.paper)
}
