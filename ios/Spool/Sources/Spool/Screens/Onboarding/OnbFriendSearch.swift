import SwiftUI

// MARK: - 09 Friend Search (terminal onboarding step)

/// Final onboarding screen. Only meaningful after sign-in — a preview-mode
/// user sees skip-only copy, because they have no session to attach follows
/// to. Debounced search hits `profiles` and tap-to-follow writes to
/// `friend_follows`. Errors are swallowed to stay out of the user's way; the
/// button state reflects whatever was actually recorded.
///
/// Header last reviewed: 2026-04-19
struct OnbFriendSearch: View {
    var onNext: () -> Void

    @State private var query: String = ""
    @State private var results: [ProfileService.ProfileSearchResult] = []
    @State private var followed: Set<UUID> = []
    @State private var pendingFollow: Set<UUID> = []
    @State private var isSearching: Bool = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var sessionUserID: UUID? = nil
    @State private var sessionChecked: Bool = false

    var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        OnbDots(step: 8)

                        Text("— FIND YOUR PEOPLE —")
                            .font(SpoolFonts.mono(10))
                            .tracking(4)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 28)

                        Text("find your\npeople.")
                            .font(SpoolFonts.serif(46))
                            .tracking(-1.4)
                            .foregroundStyle(t.ink)
                            .lineSpacing(-4)
                            .padding(.top, 18)

                        if sessionChecked && sessionUserID == nil {
                            previewModeBody(t: t)
                        } else {
                            signedInBody(t: t)
                        }

                        Spacer(minLength: 120)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 50)
                }
            }
            .overlay(alignment: .bottom) {
                OnbFoot(label: "done →", onNext: onNext)
            }
            .task {
                sessionUserID = await SpoolClient.currentUserID()
                sessionChecked = true
            }
        }
    }

    // MARK: subviews

    @ViewBuilder
    private func signedInBody(t: SpoolPalette) -> some View {
        Text("search a handle to follow someone.")
            .font(SpoolFonts.hand(13))
            .foregroundStyle(t.inkSoft)
            .lineSpacing(3)
            .padding(.top, 10)

        searchField(t: t)
            .padding(.top, 24)

        resultsSection(t: t)
            .padding(.top, 20)
    }

    @ViewBuilder
    private func previewModeBody(t: SpoolPalette) -> some View {
        Text("you need to be signed in to find friends.\nyou can always come back — they'll still be here.")
            .font(SpoolFonts.hand(13))
            .foregroundStyle(t.inkSoft)
            .lineSpacing(3)
            .padding(.top, 10)
    }

    @ViewBuilder
    private func searchField(t: SpoolPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("@")
                .font(SpoolFonts.serif(28))
                .foregroundStyle(t.inkSoft)
            handleField(t: t)
                .font(SpoolFonts.serif(28))
                .tracking(-0.3)
                .foregroundStyle(t.ink)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(t.ink).frame(height: 1.5)
        }
        .onChange(of: query) { newValue in
            scheduleSearch(for: newValue)
        }
    }

    @ViewBuilder
    private func handleField(t: SpoolPalette) -> some View {
        #if os(iOS)
        TextField("handle", text: $query)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
        #else
        TextField("handle", text: $query)
            .textFieldStyle(.plain)
        #endif
    }

    @ViewBuilder
    private func resultsSection(t: SpoolPalette) -> some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if isSearching && results.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(t.accent)
                Text("searching…")
                    .font(SpoolFonts.mono(11))
                    .foregroundStyle(t.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if results.isEmpty {
            Text("no one by that handle — yet.")
                .font(SpoolFonts.hand(13))
                .foregroundStyle(t.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } else {
            VStack(spacing: 8) {
                ForEach(results) { row in
                    resultRow(row, t: t)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ row: ProfileService.ProfileSearchResult, t: SpoolPalette) -> some View {
        let isFollowing = followed.contains(row.id)
        let isPending = pendingFollow.contains(row.id)
        HStack(spacing: 12) {
            avatar(for: row, t: t)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(row.username)")
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                if let display = row.display_name, !display.isEmpty {
                    Text(display)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)
                }
            }
            Spacer()
            Button(action: { follow(row) }) {
                Text(isFollowing ? "following" : (isPending ? "…" : "follow"))
                    .font(SpoolFonts.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(isFollowing ? t.inkSoft : t.cream)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(isFollowing ? Color.clear : t.ink)
                    )
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .disabled(isFollowing || isPending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(t.cream)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.rule, lineWidth: 1))
    }

    @ViewBuilder
    private func avatar(for row: ProfileService.ProfileSearchResult, t: SpoolPalette) -> some View {
        let size: CGFloat = 36
        let fallback = Circle()
            .fill(t.cream2)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(t.ink, lineWidth: 1))
            .overlay(
                Text(String(row.username.prefix(1)).uppercased())
                    .font(SpoolFonts.serif(14))
                    .foregroundStyle(t.ink)
            )
        if let urlString = row.avatar_url, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(t.ink, lineWidth: 1))
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    // MARK: search + follow

    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let rows: [ProfileService.ProfileSearchResult]
            do {
                rows = try await ProfileService.shared.searchUsers(query: trimmed)
            } catch {
                rows = []
            }
            if Task.isCancelled { return }
            // Exclude yourself — the web app does this via a `neq(id, me)`
            // filter; we do it client-side so we don't have to pass the ID
            // into the service.
            let me = sessionUserID
            let filtered = rows.filter { me == nil || $0.id != me! }
            await MainActor.run {
                self.results = filtered
                self.isSearching = false
            }
        }
    }

    private func follow(_ row: ProfileService.ProfileSearchResult) {
        guard !followed.contains(row.id), !pendingFollow.contains(row.id) else { return }
        pendingFollow.insert(row.id)
        Task {
            do {
                try await FollowService.shared.followUser(row.id)
                await MainActor.run {
                    pendingFollow.remove(row.id)
                    followed.insert(row.id)
                }
            } catch {
                await MainActor.run {
                    pendingFollow.remove(row.id)
                }
            }
        }
    }
}
