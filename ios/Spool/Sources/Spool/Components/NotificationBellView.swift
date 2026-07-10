import SwiftUI

/// The feed-header notification bell (spec §4): a bell glyph with an unread
/// badge that polls every 15 s while the feed is foregrounded, and a sheet
/// listing the newest 30 notifications. Opening the sheet marks the fetched
/// unread rows read (web-exact semantics), and follower rows deep-link to the
/// actor's profile.
///
/// Wiring:
///  - badge   → `NotificationRepository.shared.unreadCount()` (15 s `.task`
///    poll loop, cancelled on disappear)
///  - list    → `NotificationRepository.shared.fetchLatest()`
///  - mark    → `markRead(ids: NotificationAssembler.unreadIDs(from:))` on open
///  - route   → `NotificationDestination.destination(for:)` (pure, tested);
///    follower rows call `onOpenActor(actorID)`
///
/// All row logic is pure/tested (`NotificationAssembler`,
/// `NotificationDestination`); this view only renders + sequences the calls.
/// No UIKit.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 5), spec
/// docs/plans/2026-07-08-c1-ios-feed-ui-design.md §4.
public struct NotificationBellView: View {
    /// Open the actor's profile for a follower notification (the parent turns
    /// the id into a `Friend`/`FriendProfileScreen` route).
    public var onOpenActor: (UUID) -> Void

    @State private var unread: Int = 0
    @State private var showSheet: Bool = false

    public init(onOpenActor: @escaping (UUID) -> Void = { _ in }) {
        self.onOpenActor = onOpenActor
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            Button { showSheet = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(t.ink)
                        .padding(4)
                    if unread > 0 {
                        Text(Self.badgeText(unread))
                            .font(SpoolFonts.mono(9, weight: .bold))
                            .foregroundStyle(t.cream)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Circle().fill(t.accent))
                            .offset(x: 6, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.accessibilityLabel(unread))
            // 15 s badge poll while the bell is on screen; cancelled on
            // disappear via structured-concurrency task cancellation.
            .task {
                await refreshBadge()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if Task.isCancelled { break }
                    await refreshBadge()
                }
            }
            .sheet(isPresented: $showSheet) {
                NotificationSheet(onOpenActor: { actor in
                    showSheet = false
                    onOpenActor(actor)
                }, onClose: { showSheet = false })
                // Re-check the badge as soon as the sheet closes: opening it
                // marks the fetched-unread read, so the count usually drops.
                .onDisappear { Task { await refreshBadge() } }
            }
        }
    }

    @MainActor
    private func refreshBadge() async {
        // Read catches to zero — the caller contract's fail-soft for badge
        // reads (a network blip shouldn't strand a stale count). Already on the
        // main actor (the `.task` runs there), so assign `unread` directly.
        unread = (try? await NotificationRepository.shared.unreadCount()) ?? 0
    }

    // MARK: pure copy

    /// Badge text — the exact count up to 9, then `9+` (avoids a wide badge).
    static func badgeText(_ count: Int) -> String {
        count > 9 ? "9+" : "\(count)"
    }

    static func accessibilityLabel(_ count: Int) -> String {
        count == 0
            ? L10n.t("notifications.a11yNone")
            : L10n.t("notifications.a11yUnread", ["count": "\(count)"])
    }
}

// MARK: - Sheet

/// The notification list sheet: fetches the newest 30 on appear, marks the
/// fetched-unread rows read, renders each with its kind icon, and routes taps
/// through `NotificationDestination`.
private struct NotificationSheet: View {
    var onOpenActor: (UUID) -> Void
    var onClose: () -> Void

    @State private var items: [NotificationItem] = []
    @State private var loading: Bool = true

    var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header
                if loading {
                    Color.clear.frame(height: 1)
                    Spacer()
                } else if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                NotificationRowView(item: item) { handleTap(item) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
        .task { await loadAndMarkRead() }
    }

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Text(L10n.t("notifications.title"))
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                Button(action: onClose) {
                    Text(L10n.t("settings.close"))
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 14)
            }
        }
    }

    private var emptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                Spacer(minLength: 60)
                Image(systemName: "bell.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(t.inkSoft)
                Text(L10n.t("notifications.emptyTitle"))
                    .font(SpoolFonts.serif(20))
                    .foregroundStyle(t.ink)
                Text(L10n.t("notifications.emptyHint"))
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private func loadAndMarkRead() async {
        // Reads catch to empty per the caller contract.
        let fetched = (try? await NotificationRepository.shared.fetchLatest()) ?? []
        await MainActor.run {
            items = fetched
            loading = false
        }
        // Mark EXACTLY the fetched-unread ids read (web-exact) — pure id pick,
        // then the write. A failed write leaves them unread (badge recovers).
        let unreadIDs = NotificationAssembler.unreadIDs(from: fetched)
        if !unreadIDs.isEmpty {
            try? await NotificationRepository.shared.markRead(ids: unreadIDs)
        }
    }

    private func handleTap(_ item: NotificationItem) {
        switch NotificationDestination.destination(for: item) {
        case .actorProfile(let actor):
            onOpenActor(actor)
        case .none:
            break   // informational row — no navigation in v1
        }
    }
}

// MARK: - Row

/// One notification row: kind icon (fallback to the follower glyph), title +
/// optional body, and a chevron when the row navigates.
private struct NotificationRowView: View {
    let item: NotificationItem
    let onTap: () -> Void

    private var navigates: Bool {
        NotificationDestination.destination(for: item) != .none
    }

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: Self.icon(for: item.kind))
                        .font(.system(size: 16))
                        .foregroundStyle(t.ink)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(t.cream2))
                        .overlay(Circle().stroke(t.rule, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(SpoolFonts.serif(15))
                            .foregroundStyle(t.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let body = item.body, !body.isEmpty {
                            Text(body)
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(t.inkSoft)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    // Unread dot until marked read on open.
                    if !item.isRead {
                        Circle().fill(t.accent).frame(width: 7, height: 7)
                    }
                    if navigates {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(t.inkSoft)
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!navigates)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.title)
            .accessibilityHint(navigates ? L10n.t("notifications.opensProfile") : "")
        }
    }

    /// SF Symbol per notification kind — unknown kinds already fell back to
    /// `.newFollower` upstream (`NotificationKind.orFallback`), so this map is
    /// total.
    static func icon(for kind: NotificationKind) -> String {
        switch kind {
        case .newFollower:    return "person.badge.plus"
        case .reviewLike:     return "heart.fill"
        case .listLike:       return "list.star"
        case .badgeUnlock:    return "rosette"
        case .rankingComment: return "bubble.left.fill"
        case .journalTag:     return "tag.fill"
        }
    }
}

// MARK: - Previews

#if DEBUG
private func previewNotif(_ id: String, type: String, title: String,
                          body: String? = nil, read: Bool = false,
                          actor: UUID? = UUID()) -> NotificationItem {
    NotificationItem(
        id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-0000000000\(id)")!,
        userID: UUID(), type: type, title: title, body: body,
        actorID: actor, referenceID: nil, isRead: read,
        createdAt: "2026-07-07T12:00:00+00:00",
        actorUsername: "mei", actorAvatarPath: nil
    )
}

/// A sheet host wired to fixed fixtures — bypasses the repository so the
/// preview renders deterministically without a session.
private struct BellSheetPreview: View {
    let items: [NotificationItem]
    var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolThemeReader { t, _ in
                    HStack {
                        Text("notifications").font(SpoolFonts.serif(22)).foregroundStyle(t.ink)
                        Spacer()
                        Text("close").font(SpoolFonts.mono(12)).foregroundStyle(t.ink)
                    }
                    .padding(14)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 14)
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            NotificationRowView(item: item, onTap: {})
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

#Preview("bell badge") {
    HStack(spacing: 24) {
        NotificationBellView()
        NotificationBellView()
    }
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("bell sheet · list") {
    BellSheetPreview(items: [
        previewNotif("01", type: "new_follower", title: "mei started following you"),
        previewNotif("02", type: "review_like", title: "theo liked your review", body: "past lives · S", actor: nil),
        previewNotif("03", type: "ranking_comment", title: "ana replied to your ranking", body: "\"same, the ending\"", read: true, actor: nil),
        previewNotif("04", type: "badge_unlock", title: "you unlocked 100 films", actor: nil),
        previewNotif("05", type: "brand_new", title: "some new kind (fallback icon)"),
    ])
    .spoolMode(.paper)
}

#Preview("bell sheet · empty") {
    SpoolScreen {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bell.slash").font(.system(size: 30))
            Text("nothing yet").font(SpoolFonts.serif(20))
            Text("follows, likes, and comments land here").font(SpoolFonts.hand(14))
            Spacer()
        }
        .foregroundStyle(SpoolTokens.paper.inkSoft)
    }
    .spoolMode(.paper)
}
#endif
