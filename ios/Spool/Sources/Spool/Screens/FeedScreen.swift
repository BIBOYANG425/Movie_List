import SwiftUI

/// The C1 ticket-wall feed (spec §1–4): a header with a friends/explore
/// segmented switcher, wordmark, and notification bell; a `LazyVStack` wall of
/// `FeedTicketFlip` rows (front = `FeedTicket`, back = `FeedTicketBack` with a
/// per-event `TicketEngagementModel` created lazily on first flip); pull-to-
/// refresh; infinite scroll; and the two empty states (friends → find your
/// people; explore → visibility opt-in).
///
/// The data pipeline lives in `FeedFeedModel` (below): a `@MainActor`
/// `ObservableObject` — the codebase floor is iOS 16 so it follows the
/// `ToastCenter`/`TicketEngagementModel` precedent, not `@Observable`. It owns
/// a `FeedPageAssembler` wired to the REAL repositories and drives the
/// caller-contract loop (assemble → append; mode switch re-assembles from a
/// nil cursor with a fresh per-call throttle; refresh re-assembles from nil;
/// infinite scroll continues after the last card while `hasMore`). Reads
/// catch to empty per the ledger's Part-B contract.
///
/// Fixture/preview mode (no session) is preserved: `SpoolData.feedEventRows`
/// are mapped through the SAME `FeedCards.card` path the live feed uses, so
/// previews exercise the real card layer.
///
/// Pure decisions (the infinite-scroll trigger, the allow-type set) live in
/// `FeedScreenLogic` (XCTest-covered); this file is composition + wiring.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 5), spec
/// docs/plans/2026-07-08-c1-ios-feed-ui-design.md.
public struct FeedScreen: View {
    /// Signed-in empty state "rank something" CTA (preserved from the prior
    /// screen; SpoolAppRoot wires it to the rank tab).
    private let onRankTap: (() -> Void)?
    /// Friends empty state → FriendsScreen ("find your people").
    private let onOpenFriends: (() -> Void)?
    /// Explore empty state → Settings visibility row (the opt-in loop).
    private let onOpenSettings: (() -> Void)?
    /// Open an actor's profile (ticket context menu + notification follower
    /// rows). Carries the actor id and best-known handle so the parent can
    /// build a `Friend`/`FriendProfileScreen` route.
    private let onOpenActor: ((UUID, String?) -> Void)?

    @StateObject private var model = FeedFeedModel()

    public init(onRankTap: (() -> Void)? = nil,
                onOpenFriends: (() -> Void)? = nil,
                onOpenSettings: (() -> Void)? = nil,
                onOpenActor: ((UUID, String?) -> Void)? = nil) {
        self.onRankTap = onRankTap
        self.onOpenFriends = onOpenFriends
        self.onOpenSettings = onOpenSettings
        self.onOpenActor = onOpenActor
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header
                ScrollView {
                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 110)
                        .padding(.top, 2)
                }
                .refreshable { await model.refresh() }
            }
        }
        .task { await model.loadInitialIfNeeded() }
    }

    // MARK: header

    private var header: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    Text("spool")
                        .font(SpoolFonts.serif(30))
                        .tracking(-0.5)
                        .foregroundStyle(t.ink)
                    Spacer()
                    NotificationBellView(onOpenActor: { actor in
                        onOpenActor?(actor, nil)
                    })
                }
                modeSwitcher(t: t)
            }
            .padding(.horizontal, 18)
            .padding(.top, 60)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func modeSwitcher(t: SpoolPalette) -> some View {
        HStack(spacing: 6) {
            SpoolPill("friends", active: model.mode == .friends, size: .sm) {
                Task { await model.switchMode(.friends) }
            }
            SpoolPill("explore", active: model.mode == .explore, size: .sm) {
                Task { await model.switchMode(.explore) }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if model.loading {
            // Nothing until the first assemble resolves — avoids a one-frame
            // flash of a placeholder for signed-in users.
            Color.clear.frame(height: 1)
        } else if model.cards.isEmpty {
            emptyState
        } else {
            ticketWall
        }
    }

    private var ticketWall: some View {
        LazyVStack(spacing: 16) {
            ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                ticketRow(card: card, index: index)
            }
            if model.loadingMore {
                ProgressView()
                    .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func ticketRow(card: FeedCard, index: Int) -> some View {
        let isFlipped = model.flippedID == card.id
        FeedTicketFlip(
            isFlipped: Binding(
                get: { model.flippedID == card.id },
                set: { flip in model.setFlipped(card: card, flipped: flip) }
            ),
            front: {
                FeedTicket(
                    card: card,
                    onFlip: { model.setFlipped(card: card, flipped: true) },
                    onMuteUser: { Task { await model.muteUser(card) } },
                    onMuteMedia: { Task { await model.muteMedia(card) } },
                    onOpenActor: { onOpenActor?(card.actorID, card.actorUsername) }
                )
            },
            back: {
                if let engagement = model.engagementModel(for: card) {
                    FeedTicketBack(
                        card: card,
                        model: engagement,
                        currentUserID: model.currentUserID,
                        onFlipBack: { model.setFlipped(card: card, flipped: false) }
                    )
                } else {
                    // Fixture/preview mode: no live engagement model (no
                    // session). A minimal back keeps the flip working.
                    fixtureBack(card: card)
                }
            }
        )
        // Infinite scroll: the last card appearing triggers the next page.
        .onAppear {
            if FeedScreenLogic.shouldLoadNextPage(
                appearedIndex: index,
                lastIndex: model.cards.count - 1,
                hasMore: model.hasMore,
                isLoading: model.loadingMore
            ) {
                Task { await model.loadNextPage() }
            }
        }
        .zIndex(isFlipped ? 1 : 0)
    }

    @ViewBuilder
    private func fixtureBack(card: FeedCard) -> some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text("REACTIONS + REPLIES")
                    .font(SpoolFonts.mono(11)).tracking(2)
                    .foregroundStyle(t.inkSoft)
                Text("sign in to react and reply")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.ink)
                Button {
                    model.setFlipped(card: card, flipped: false)
                } label: {
                    Text("TAP TO FLIP BACK")
                        .font(SpoolFonts.mono(8)).tracking(2)
                        .foregroundStyle(t.inkSoft)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(16)
            .background(t.cream)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.ink, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: empty states

    @ViewBuilder
    private var emptyState: some View {
        switch model.mode {
        case .friends: friendsEmptyState
        case .explore: exploreEmptyState
        }
    }

    private var friendsEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                Spacer(minLength: 60)
                Text("your feed is quiet")
                    .font(SpoolFonts.serif(26))
                    .foregroundStyle(t.ink)
                Text("follow people to see their rankings, reviews, and lists here")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("find your people", filled: true, size: .md) {
                    onOpenFriends?()
                }
                .padding(.top, 4)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }

    private var exploreEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                Spacer(minLength: 60)
                Text("explore is empty")
                    .font(SpoolFonts.serif(26))
                    .foregroundStyle(t.ink)
                Text("public profiles appear here — make yours public in settings")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("open settings", filled: true, size: .md) {
                    onOpenSettings?()
                }
                .padding(.top, 4)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Feed view-model

/// Drives `FeedScreen`: owns a `FeedPageAssembler` wired to the real
/// repositories, the current cards/cursor/mode, and the flip + engagement
/// state. `@MainActor` `ObservableObject` (iOS-16 floor — see file header).
///
/// The assembler is rebuilt lazily; every `assemblePage` call gets a fresh
/// per-call throttle dict (that reset is the assembler's own contract), so a
/// mode switch or refresh is just a new call from a nil cursor. Reads inside
/// the assembler already catch to empty; this model never surfaces a throw.
@MainActor
final class FeedFeedModel: ObservableObject {

    @Published private(set) var cards: [FeedCard] = []
    @Published private(set) var mode: FeedMode = .friends
    @Published private(set) var loading: Bool = true
    @Published private(set) var loadingMore: Bool = false
    @Published private(set) var hasMore: Bool = false
    /// The single flipped ticket (only one ticket is open at a time).
    @Published var flippedID: UUID?

    private(set) var currentUserID: UUID?
    /// Keyset cursor into the current stream. `private(set)` so tests can read
    /// it (`@testable`) to assert the mode-switch race leaves it on the right
    /// stream; only this model writes it.
    private(set) var cursor: FeedCursor?
    private var hasSession = false
    private var didLoadOnce = false

    /// Monotonic stream generation. Bumped at the START of every operation that
    /// resets the stream (`assembleFromStart` via switch/refresh/initial). Each
    /// awaiting body captures the generation before suspending and re-checks it
    /// after resuming; a mismatch means the stream was reset (e.g. a mode
    /// switch) while this load was in flight, so the stale result is DROPPED
    /// instead of contaminating the new stream. Without this, a friends
    /// `loadNextPage` suspended across its RPC could resume after the user
    /// switched to explore and append friends cards / overwrite the cursor.
    private var generation = 0

    /// The in-flight `loadNextPage` task, held so a mode switch / refresh can
    /// cancel it (belt-and-suspenders with the generation token — the token
    /// makes the result HARMLESS, the cancel stops WASTING the RPC).
    private var pageLoadTask: Task<Void, Never>?

    /// One engagement model per event id, created on first flip and loaded
    /// then. Kept off `@Published` — the ticket back `@ObservedObject`s its
    /// own model, so publishing the dictionary too would double-notify.
    private var engagementModels: [UUID: TicketEngagementModel] = [:]

    private let assembler: FeedPageAssembler
    /// Session resolver — injected so tests can drive a signed-in model
    /// without a live Supabase session.
    private let resolveSession: () async -> UUID?

    /// Production init: wire the assembler's injected IO to the real
    /// repositories. Each closure is the exact PR #34 signature; the assembler
    /// owns the contract loop (refill, cursor, throttle, fail-soft).
    convenience init() {
        self.init(
            assembler: FeedPageAssembler(
                fetchPage: { mode, cursor, pageSize in
                    try await FeedRepository.shared.fetchPage(mode: mode, cursor: cursor, pageSize: pageSize)
                },
                fetchMutes: {
                    try await FeedRepository.shared.mutes()
                },
                fetchProfiles: { ids in
                    try await ProfileRepository.shared.getProfilesByIds(ids)
                },
                fetchScores: { pairs in
                    try await FeedRepository.shared.rankingScores(pairs: pairs)
                }
            ),
            resolveSession: { await SpoolClient.currentUserID() }
        )
    }

    /// Designated init — takes an already-wired assembler + session resolver so
    /// the mode-switch race is testable with fakes (FeedFeedModelTests).
    init(assembler: FeedPageAssembler, resolveSession: @escaping () async -> UUID?) {
        self.assembler = assembler
        self.resolveSession = resolveSession
    }

    // MARK: loading

    /// First appearance: resolve the session once, then assemble the initial
    /// page (or load fixtures when signed out). Idempotent across re-appears.
    func loadInitialIfNeeded() async {
        guard !didLoadOnce else { return }
        didLoadOnce = true
        currentUserID = await resolveSession()
        hasSession = currentUserID != nil
        await assembleFromStart()
    }

    /// Pull-to-refresh: re-assemble from a nil cursor (a brand-new
    /// `assemblePage` call, so the assembler resets its per-call throttle).
    func refresh() async {
        // Re-check the session — the user may have signed in since first load.
        currentUserID = await resolveSession()
        hasSession = currentUserID != nil
        await assembleFromStart()
    }

    /// Switch friends ⇄ explore: reset cursor + flip state and re-assemble
    /// from the start (fresh throttle via the new call). Ignores a redundant
    /// same-mode tap even while an assemble is in flight (`loading`) so a
    /// double-tap can't stack redundant reassembles.
    func switchMode(_ newMode: FeedMode) async {
        guard newMode != mode else { return }
        mode = newMode
        await assembleFromStart()
    }

    /// Fresh first page for the current mode. Signed-out → fixtures. Bumps the
    /// generation and cancels any in-flight page load so a suspended
    /// `loadNextPage` from the previous stream can't write into this one.
    private func assembleFromStart() async {
        generation += 1
        let gen = generation
        pageLoadTask?.cancel()
        pageLoadTask = nil

        flippedID = nil
        cursor = nil
        loading = true

        guard hasSession else {
            cards = Self.fixtureCards()
            hasMore = false
            loading = false
            return
        }

        let result = await assembler.assemblePage(
            mode: mode, after: nil, allowedTypes: FeedScreenLogic.allEventTypes
        )
        // Stream reset (mode switch / refresh) landed while we were suspended —
        // discard this now-stale page.
        guard gen == generation else { return }
        cards = result.cards
        cursor = result.cursor
        hasMore = result.hasMore
        loading = false
    }

    /// Infinite scroll: append the next page after the current cursor. Guarded
    /// against concurrent loads (`loadingMore`) on top of the pure
    /// `shouldLoadNextPage` gate at the call site. Runs inside a held task so a
    /// mode switch / refresh can cancel it; the generation token discards any
    /// result that resumes after the stream was reset.
    func loadNextPage() async {
        guard hasSession, hasMore, !loadingMore, !loading else { return }
        loadingMore = true
        let gen = generation
        let modeAtStart = mode
        let cursorAtStart = cursor

        let task = Task { @MainActor in
            defer { loadingMore = false }

            let result = await assembler.assemblePage(
                mode: modeAtStart, after: cursorAtStart, allowedTypes: FeedScreenLogic.allEventTypes
            )
            // A reset (mode switch / refresh / cancel) happened while the RPC
            // was in flight — DROP the result rather than append friends cards
            // onto the explore list or overwrite the explore cursor.
            guard gen == generation, !Task.isCancelled else { return }

            // Append de-duplicating on id (defensive — the cursor contract
            // already prevents overlap, but a repeated row must never
            // double-render).
            var seen = Set(cards.map(\.id))
            for card in result.cards where seen.insert(card.id).inserted {
                cards.append(card)
            }
            cursor = result.cursor
            hasMore = result.hasMore
        }
        pageLoadTask = task
        await task.value
    }

    // MARK: flip + engagement

    func setFlipped(card: FeedCard, flipped: Bool) {
        if flipped {
            flippedID = card.id
            // Lazily create + load the engagement model on first flip.
            if hasSession, engagementModels[card.id] == nil {
                let model = Self.makeEngagementModel(eventID: card.id)
                engagementModels[card.id] = model
                Task { await model.load() }
            }
        } else if flippedID == card.id {
            flippedID = nil
        }
    }

    /// The engagement model for a flipped ticket, or nil in fixture mode.
    func engagementModel(for card: FeedCard) -> TicketEngagementModel? {
        engagementModels[card.id]
    }

    private static func makeEngagementModel(eventID: UUID) -> TicketEngagementModel {
        TicketEngagementModel(
            eventID: eventID,
            loadCounts: {
                let map = try await FeedRepository.shared.engagement(for: [eventID])
                return map[eventID] ?? EngagementCounts(reactions: [:], comments: 0, myReactions: [])
            },
            loadThread: {
                try await FeedRepository.shared.comments(for: eventID)
            },
            toggleReaction: { reaction, currentlyMine in
                try await FeedRepository.shared.toggleReaction(
                    eventID: eventID, reaction: reaction, currentlyMine: currentlyMine)
            },
            addComment: { body in
                try await FeedRepository.shared.addComment(eventID: eventID, body: body, parentID: nil)
            },
            deleteComment: { id in
                try await FeedRepository.shared.deleteComment(id: id)
            }
        )
    }

    // MARK: mutes

    /// Mute the actor, then locally drop all of their tickets from the wall
    /// (server side takes effect on the next fetch). A failed write leaves the
    /// wall unchanged.
    func muteUser(_ card: FeedCard) async {
        do {
            try await FeedRepository.shared.muteUser(card.actorID)
            cards.removeAll { $0.actorID == card.actorID }
        } catch {
            // no-op — the mute didn't take; keep the tickets visible.
        }
    }

    /// Mute the title, then locally drop all tickets carrying that tmdb id.
    func muteMedia(_ card: FeedCard) async {
        guard let tmdbID = card.mediaTmdbID else { return }
        do {
            try await FeedRepository.shared.muteMedia(tmdbID)
            cards.removeAll { $0.mediaTmdbID == tmdbID }
        } catch {
            // no-op.
        }
    }

    // MARK: fixtures

    /// Signed-out demo wall — the SAME card pipeline the live feed uses
    /// (`FeedCards.card`), with fixture handles hydrated locally.
    static func fixtureCards() -> [FeedCard] {
        SpoolData.feedEventRows.map { row in
            var card = FeedCards.card(from: row)
            card.actorUsername = SpoolData.feedFixtureUsernames[row.actor_id]
            return card
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("feed · fixtures (paper)") {
    FeedScreen().spoolMode(.paper)
}

#Preview("feed · fixtures (dark)") {
    FeedScreen().spoolMode(.dark)
}

/// Empty-state previews — force the model into an empty, signed-in-looking
/// state for each mode by rendering the empty views directly.
private struct FeedEmptyPreview: View {
    let explore: Bool
    var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolThemeReader { t, _ in
                    HStack {
                        Text("spool").font(SpoolFonts.serif(30)).foregroundStyle(t.ink)
                        Spacer()
                        NotificationBellView()
                    }
                    .padding(.horizontal, 18).padding(.top, 60).padding(.bottom, 12)
                }
                SpoolThemeReader { t, _ in
                    VStack(spacing: 16) {
                        Spacer(minLength: 60)
                        Text(explore ? "explore is empty" : "your feed is quiet")
                            .font(SpoolFonts.serif(26)).foregroundStyle(t.ink)
                        Text(explore
                             ? "public profiles appear here — make yours public in settings"
                             : "follow people to see their rankings, reviews, and lists here")
                            .font(SpoolFonts.hand(15))
                            .foregroundStyle(t.inkSoft)
                            .multilineTextAlignment(.center)
                        SpoolPill(explore ? "open settings" : "find your people", filled: true, size: .md) {}
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

#Preview("feed · friends empty") {
    FeedEmptyPreview(explore: false).spoolMode(.paper)
}

#Preview("feed · explore empty") {
    FeedEmptyPreview(explore: true).spoolMode(.paper)
}
#endif
