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
/// Edit mode (C4 management-UI Task 3): an "edit" affordance in the header
/// toggles drag-to-reorder WITHIN a tier. All reorder logic — no-op
/// suppression, full-membership persistence via `RankingRepository.reorderTier`,
/// optimistic-apply/revert-on-throw, in-flight guard, rank renumbering, and the
/// single `ranking_move` emission — lives in the injected-closure
/// `RankManageModel` (`RankManageModelTests`). The screen only binds the model's
/// IO and renders an editable per-tier `List` with `.onMove` while editing.
///
/// Long-press menu (C4 management-UI Task 4): each read-only ranked card carries
/// a `.contextMenu` — move to another tier (submenu), edit notes, re-rank,
/// delete. The move/notes/delete actions route through `RankManageModel`
/// (`moveTo`/`fetchNotes`+`saveNotes`/`delete` — optimistic + revert + toast,
/// tested); the read-only list renders from `manage.items(in:)` so those
/// optimistic mutations reflect instantly. Edit-notes opens `RankNotesSheet`
/// seeded from a live-row `getNotes` probe (the shelf item has no notes column);
/// on a probe failure the sheet shows a warning and blocks blank saves so a
/// whitespace commit can never wipe a real note whose contents are unknown;
/// delete first opens a destructive confirmation dialog NAMING the movie;
/// re-rank closes this sheet and enters the ceremony preseeded with the RAW item
/// (NO watchlist origin) via the `onRerank` hand-off wired in `SpoolAppRoot`.
/// When edit mode exits the screen syncs its read-only `items` from
/// `manage.flatItems` (local copy, no network) so `#rank` badges reflect the
/// dragged order immediately.
///
/// Per-vertical (C5 Task 2): a `movie | tv | books` segmented switch (the
/// WatchlistScreen media-pill idiom) sits under the header, movie the default
/// leftmost segment. Switching re-seeds `RankManageModel` with the picked media
/// (`setMedia` + a fresh `getAllRankedItems(media:)` read) so drag / cross-tier
/// move / notes / delete all route to that vertical's table. RE-RANK is offered
/// for ALL media as of C5-iOS Task 6 (`RankManageModel.showsRerank(forMedia:)`
/// accepts any known vertical): the hand-off routes per media in `SpoolAppRoot.
/// rerankFromShelf` — a tv season id goes straight to the ceremony, a legacy
/// whole-show id detours through the season grid, a book/movie goes direct.
///
/// Header last reviewed: 2026-07-10
public struct FullListScreen: View {
    public var onClose: () -> Void
    /// Re-rank hand-off (Task 4): the long-press "re-rank" action needs to close
    /// this sheet and enter the ceremony preseeded with the RAW item, NO
    /// watchlist origin. `SpoolAppRoot` owns that choreography and injects it
    /// here; the default no-op keeps previews / tests self-contained.
    public var onRerank: (RankedItem) -> Void

    @State private var items: [RankedItem] = []
    @State private var hasSession: Bool = false
    @State private var loading: Bool = true
    /// The vertical currently shown (movie default, leftmost segment). Each
    /// switch re-seeds the manage model and refetches that media's shelf.
    @State private var selectedMedia: WatchlistMediaType = .movie
    /// Tracks the in-flight reload so a rapid pull-to-refresh can cancel its
    /// predecessor before mutating state. We also snapshot `hasSession` at
    /// fetch start and reject late responses whose session context changed.
    @State private var loadTask: Task<Void, Never>? = nil
    /// Edit-mode drag-to-reorder + long-press menu model. Owns the per-tier
    /// membership + all management IO (injected closures, tested). Both the
    /// editable list AND the read-only render read from `manage.items(in:)` so
    /// an optimistic move/delete reflects on screen immediately; `items` gates
    /// the loading/empty/preview states.
    @StateObject private var manage = RankManageModel()

    /// The row whose notes the "edit notes" sheet is editing (nil = closed). The
    /// sheet seeds its draft from a `fetchNotes` probe of the LIVE row so an edit
    /// never blanks an existing note that a concurrent edit may have updated since
    /// the shelf loaded.
    @State private var notesTarget: RankedItem? = nil
    @State private var notesDraft: String = ""
    @State private var notesLoading: Bool = false
    /// True when the most recent `fetchNotes` probe returned `.probeFailed`. The
    /// sheet shows a warning banner and blocks blank saves so a whitespace commit
    /// can never wipe a real note whose contents are unknown.
    @State private var notesProbeFailed: Bool = false
    /// The row a destructive delete is confirming (nil = no dialog). The
    /// confirmation dialog names the movie before anything is removed.
    @State private var deleteTarget: RankedItem? = nil

    public init(
        onClose: @escaping () -> Void = {},
        onRerank: @escaping (RankedItem) -> Void = { _ in }
    ) {
        self.onClose = onClose
        self.onRerank = onRerank
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header

                mediaSwitcher

                if manage.isEditing {
                    // Editable list: a `List` with per-tier `Section`s so
                    // `.onMove` reorders WITHIN one tier only. No pull-to-refresh
                    // here — a refetch mid-edit would fight the optimistic order.
                    editableList
                } else {
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
        }
        .task { triggerReload() }
        .onAppear {
            // Wire the re-rank hand-off once: the model can't build this closure
            // itself (it needs this screen's sheet-dismiss + flow-entry
            // choreography), so it defers to `bindRerank`.
            manage.bindRerank { item in
                onClose()          // dismiss the shelf sheet…
                onRerank(item)     // …then enter the ceremony preseeded (no origin)
            }
        }
        .sheet(item: notesSheetBinding) { target in
            RankNotesSheet(
                title: target.title,
                initialNotes: notesDraft,
                loading: notesLoading,
                probeFailed: notesProbeFailed,
                onSave: { text in
                    let item = target
                    notesTarget = nil
                    Task { await manage.saveNotes(item: item, notes: text) }
                },
                onCancel: { notesTarget = nil }
            )
        }
        .confirmationDialog(
            deleteTarget.map { L10n.t("shelf.deleteTitle", ["title": $0.title]) } ?? L10n.t("shelf.deleteTitleGeneric"),
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button(L10n.t("shelf.delete"), role: .destructive) {
                if let item = deleteTarget {
                    deleteTarget = nil
                    Task {
                        await manage.delete(item: item)
                        // Sync the empty-state gate so deleting the last row
                        // flips the shelf to its "nothing ranked" prompt.
                        items = manage.flatItems
                    }
                }
            }
            Button(L10n.t("shelf.cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.t("shelf.deleteMessage"))
        }
    }

    /// `sheet(item:)` binding for the notes editor — presents when `notesTarget`
    /// is set, clears it on dismiss.
    private var notesSheetBinding: Binding<RankedItem?> {
        Binding(get: { notesTarget }, set: { if $0 == nil { notesTarget = nil } })
    }

    /// `confirmationDialog` presentation binding driven by `deleteTarget`.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    /// Open the "edit notes" sheet for `item`: set the target, then probe the
    /// LIVE row's notes so the editor seeds from the real value (never blanks an
    /// existing note). A slow probe shows the sheet in a loading state.
    ///
    /// On a `.probeFailed` result the sheet enters a warning state: it shows a
    /// banner ("couldn't load your existing note — saving may overwrite it") and
    /// blocks the save button until the user types something non-empty, so a
    /// blank commit can never fire on the failed-probe path and wipe a real note.
    private func openNotes(for item: RankedItem) {
        notesTarget = item
        notesDraft = ""
        notesLoading = true
        notesProbeFailed = false
        Task {
            let result = await manage.fetchNotes(item: item)
            // Only apply if the user hasn't closed / switched targets meanwhile.
            guard notesTarget?.id == item.id else { return }
            switch result {
            case .success(let text):
                notesDraft = text ?? ""
                notesProbeFailed = false
            case .probeFailed:
                notesDraft = ""
                notesProbeFailed = true
            }
            notesLoading = false
        }
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
                    Text(L10n.t("settings.close"))
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(L10n.t("shelf.title"))
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                editToggle(t)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }

    // MARK: media switcher

    /// movie ⇄ tv ⇄ books segmented control — the WatchlistScreen `SpoolPill`
    /// idiom. Movie is the primary/leftmost segment. A switch re-seeds the manage
    /// model with the picked media and refetches that vertical's shelf.
    private var mediaSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(WatchlistMediaType.allCases, id: \.self) { media in
                SpoolPill(label(for: media),
                          active: selectedMedia == media,
                          size: .sm) {
                    select(media: media)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func label(for media: WatchlistMediaType) -> String {
        switch media {
        case .movie: return L10n.t("rankEntry.modeMovies")
        case .tv:    return L10n.t("rankEntry.modeTV")
        case .book:  return L10n.t("rankEntry.modeBooks")
        }
    }

    /// Switch the shown vertical: drop any edit state, point the manage model at
    /// the new media (so its next reorder/move/notes/delete routes to that
    /// table), clear the visible list, and refetch. A no-op when the media is
    /// already selected.
    private func select(media: WatchlistMediaType) {
        guard media != selectedMedia else { return }
        selectedMedia = media
        manage.endEditing()
        manage.setMedia(media.rawValue)
        // Clear the stale vertical's rows immediately so the empty/loading state
        // renders while the new media's shelf loads (no cross-media flash).
        items = []
        manage.setItems([])
        triggerReload()
    }

    /// The edit affordance. Only shown once the signed-in shelf has rows —
    /// there is nothing to reorder in the preview/empty/loading states. Balances
    /// the `close` button's width when hidden so the title stays centered (same
    /// invisible-balancer trick SettingsScreen uses).
    @ViewBuilder
    private func editToggle(_ t: SpoolPalette) -> some View {
        if hasSession && !items.isEmpty {
            Button {
                let wasEditing = manage.isEditing
                manage.toggleEditing()
                // When exiting edit mode sync the screen's read-only `items`
                // from the model's tiers (which carry renumbered ranks after
                // each confirmed drag). This is a local copy — no network hit —
                // so the shelf and `#rank` badges reflect the reordered state
                // instantly without waiting for a pull-to-refresh.
                if wasEditing {
                    items = manage.flatItems
                }
            } label: {
                Text(manage.isEditing ? L10n.t("shelf.done") : L10n.t("shelf.edit"))
                    .font(SpoolFonts.mono(12))
                    .tracking(1.5)
                    .foregroundStyle(manage.isEditing ? t.cream : t.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(manage.isEditing ? t.ink : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        } else {
            // Invisible balancer keeps the title centered when no toggle shows.
            Text(L10n.t("shelf.edit")).opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
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
            Text(L10n.t("shelf.loading"))
                .font(SpoolFonts.hand(13))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var previewState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                Text(L10n.t("shelf.signInTitle"))
                    .font(SpoolFonts.serif(22))
                    .foregroundStyle(t.ink)
                Text(L10n.t("shelf.signInHint"))
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
                Text(L10n.t("shelf.emptyTitle"))
                    .font(SpoolFonts.serif(22))
                    .foregroundStyle(t.ink)
                Text(L10n.t("shelf.emptyHint"))
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill(L10n.t("shelf.rankSomething"), filled: true, action: onClose)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private var populatedList: some View {
        // Tier enum iteration order is already S → D, which matches the
        // visual "best at the top" layout we want. Rows come from the model's
        // per-tier membership so an optimistic long-press move/delete reflects
        // instantly (the model is seeded from the same fetch that set `items`).
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(Tier.allCases, id: \.self) { tier in
                let tierItems = manage.items(in: tier)
                if !tierItems.isEmpty {
                    tierSection(tier: tier, rows: tierItems)
                }
            }
        }
        .padding(.top, 14)
    }

    // MARK: editable list (edit mode)

    /// The drag-to-reorder list. A `List` with one `Section` per non-empty tier
    /// so `.onMove` reorders WITHIN a tier only — SwiftUI scopes a section's
    /// `.onMove` to that section's own rows, which is exactly the single-tier
    /// confinement the plan requires. Each move forwards to `manage.moveRow`,
    /// which computes the tier's full new membership, suppresses no-ops,
    /// persists optimistically, and reverts + toasts on failure. `.active` edit
    /// mode surfaces the standard drag handles.
    private var editableList: some View {
        SpoolThemeReader { t, mode in
            List {
                ForEach(Tier.allCases, id: \.self) { tier in
                    let rows = manage.items(in: tier)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows, id: \.id) { item in
                                row(item: item, t: t, mode: mode)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18))
                                    .listRowBackground(Color.clear)
                            }
                            .onMove { source, destination in
                                Task { await manage.moveRow(tier: tier, from: source, to: destination) }
                            }
                        } header: {
                            editableTierHeader(tier: tier, count: rows.count, t: t, mode: mode)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .activeEditMode()
        }
    }

    private func editableTierHeader(tier: Tier, count: Int, t: SpoolPalette, mode: SpoolMode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tier.rawValue)
                .font(SpoolFonts.serif(22))
                .foregroundStyle(tierColor(tier, mode: mode))
            Text(tier.label)
                .font(SpoolFonts.hand(12))
                .foregroundStyle(t.inkSoft)
            Spacer()
            Text("\(count)")
                .font(SpoolFonts.mono(11))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
        }
    }

    // MARK: long-press context menu (Task 4)

    /// The long-press management menu for one ranked card: move to another tier,
    /// edit notes, re-rank, delete. EVERY action works for EVERY vertical (they
    /// route through the media-parameterized `RankManageModel`); RE-RANK is
    /// offered for all known media as of C5-iOS Task 6
    /// (`RankManageModel.showsRerank(forMedia:)` — only an unknown media hides
    /// it), with the completion routed per media by `SpoolAppRoot.
    /// rerankFromShelf`. All actions route through the injected-closure
    /// `RankManageModel` (optimistic + revert + toast, tested); this builder
    /// only shapes the menu.
    @ViewBuilder
    private func rankMenu(for item: RankedItem) -> some View {
        // Move to tier — a submenu of every tier EXCEPT the one it's in. Each
        // move appends to the target tier's tail (menu moves never pick a slot).
        Menu(L10n.t("shelf.moveToTier")) {
            ForEach(Tier.allCases.filter { $0 != item.tier }, id: \.self) { tier in
                Button {
                    Task {
                        await manage.moveTo(tier: tier, item: item)
                        // Keep the empty-state gate (`items`) in step with the
                        // model's post-move membership — no network.
                        items = manage.flatItems
                    }
                } label: {
                    Text("\(tier.rawValue) · \(tier.label)")
                }
            }
        }

        Button {
            openNotes(for: item)
        } label: {
            Label(L10n.t("shelf.editNotes"), systemImage: "square.and.pencil")
        }

        // RE-RANK — all known media (C5-T6; the media-generic ceremony routes
        // per vertical). The gate keys on the shelf's current media, not the
        // item, so a whole vertical's cards share one rule; only an unknown
        // media hides the action.
        if RankManageModel.showsRerank(forMedia: selectedMedia.rawValue) {
            Button {
                manage.requestRerank(item: item)
            } label: {
                Label(L10n.t("shelf.reRank"), systemImage: "arrow.up.arrow.down")
            }
        }

        // Destructive delete — the actual removal waits on the confirmation
        // dialog (which names the item); this only opens it.
        Button(role: .destructive) {
            deleteTarget = item
        } label: {
            Label(L10n.t("shelf.delete"), systemImage: "trash")
        }
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
                            .contentShape(Rectangle())
                            .contextMenu { rankMenu(for: item) }
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

    /// The card's subtitle line. `director` carries the media-generic attribution
    /// (director for movies, creator for tv, author for books — the `RankingRow`
    /// mapping). The `DIR.` prefix is movie-only; tv/book attribution renders
    /// bare. A tv row's `seasonTitle` leads the line so the season identity shows
    /// (its `title` is the SHOW name).
    private func metaLine(for item: RankedItem) -> String {
        var parts: [String] = []
        if let season = item.seasonTitle?.trimmingCharacters(in: .whitespaces), !season.isEmpty {
            parts.append(season)
        }
        if let y = item.year { parts.append(String(y)) }
        let attribution = item.director.trimmingCharacters(in: .whitespaces)
        if !attribution.isEmpty, attribution != "—" {
            let prefix = selectedMedia == .movie ? "DIR. " : ""
            parts.append("\(prefix)\(attribution.uppercased())")
        }
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

        // Point the model at the current vertical BEFORE the read so a fetch
        // failure still leaves subsequent management ops routed correctly.
        let media = selectedMedia.rawValue
        manage.setMedia(media)

        guard sessionAtStart else {
            if !Task.isCancelled {
                items = []
                // A signed-out shelf can't be edited — drop any stale edit
                // state so the toggle never survives a session change.
                manage.endEditing()
                manage.setItems([])
            }
            NSLog("[FullListScreen] loaded 0 items (no session)")
            return
        }

        do {
            let fetched = try await RankingRepository.shared.getAllRankedItems(media: media)
            // Reject a late response whose media context changed mid-flight
            // (the user switched segments after this fetch started).
            if Task.isCancelled || selectedMedia.rawValue != media { return }
            items = fetched
            // Re-seed the edit model's per-tier membership from the fresh shelf.
            // Editing ends on a reload so a refetched order never fights an
            // in-flight optimistic drag (pull-to-refresh is disabled while
            // editing anyway; this covers the initial load + session flips).
            manage.endEditing()
            manage.setItems(fetched)
            NSLog("[FullListScreen] loaded \(fetched.count) \(media) items")
        } catch {
            if Task.isCancelled { return }
            // Keep the previously-displayed shelf intact — a pull-to-refresh
            // that fails shouldn't wipe the user's visible list. Surface
            // the failure via a toast instead, same pattern RankPersistence
            // uses on write failures.
            NSLog("[FullListScreen] getAllRankedItems(\(media)) FAIL: \(error)")
            ToastCenter.shared.show(
                L10n.t("shelf.refreshFailed"),
                level: .error
            )
        }
    }

    // MARK: helpers

    private static func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

/// Editor for a ranking's freeform notes (C4 Task 4, "edit notes" menu action).
/// Seeds from `initialNotes` (fetched from the LIVE row by the presenter so an
/// edit never blanks an existing note); shows a loading placeholder while that
/// probe is in flight. `onSave` hands the raw draft up — trimming and nil-
/// normalization happen in `RankManageModel.saveNotes` (tested), keeping the
/// view dumb.
///
/// When `probeFailed` is true the probe threw and the existing note is unknown.
/// The sheet shows a warning banner and blocks the save button until the user
/// types something non-empty, so a blank commit can never fire on the failed-
/// probe path and wipe a real note.
struct RankNotesSheet: View {
    let title: String
    let initialNotes: String
    let loading: Bool
    /// True when the live-row probe failed. Triggers the warning banner and
    /// blocks blank saves so a whitespace commit can't wipe an unseen note.
    let probeFailed: Bool
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var draft: String = ""
    @State private var seeded: Bool = false

    /// Save is blocked when: (a) the probe is still loading, OR (b) the probe
    /// failed AND the draft is empty/whitespace (the user hasn't typed anything
    /// that could safely replace the unseen note).
    private var saveBlocked: Bool {
        loading || (probeFailed && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        SpoolScreen {
            SpoolThemeReader { t, _ in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button(L10n.t("shelf.cancel"), action: onCancel)
                            .font(SpoolFonts.mono(12))
                            .tracking(1.5)
                            .foregroundStyle(t.ink)
                            .buttonStyle(.plain)
                        Spacer()
                        Button(L10n.t("shelf.save")) { onSave(draft) }
                            .font(SpoolFonts.mono(12))
                            .tracking(1.5)
                            .foregroundStyle(saveBlocked ? t.inkSoft : t.ink)
                            .buttonStyle(.plain)
                            .disabled(saveBlocked)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                    Text(title)
                        .font(SpoolFonts.serif(22))
                        .tracking(-0.3)
                        .foregroundStyle(t.ink)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    // Probe-failure warning: the existing note is unknown so we
                    // warn the user before they save over it. Shown above the
                    // editor label so it's visible before the user starts typing.
                    if probeFailed && !loading {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(SpoolTokens.paper.inkSoft)
                            Text(L10n.t("toast.noteLoadFailed"))
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(SpoolTokens.paper.inkSoft)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    Text(L10n.t("shelf.yourNotes"))
                        .font(SpoolFonts.mono(10))
                        .tracking(2.5)
                        .foregroundStyle(t.inkSoft)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 6)

                    editor(t)
                        .padding(.horizontal, 16)

                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            // Seed once from the (probe-resolved) initial value. Guarding with
            // `seeded` keeps later parent re-renders from stomping the user's
            // in-progress edit.
            if !seeded {
                draft = initialNotes
                seeded = true
            }
        }
        .onChange(of: initialNotes) { newValue in
            // The probe resolves AFTER first render (initialNotes flips from ""
            // to the fetched value); adopt it as long as the user hasn't typed.
            if draft.isEmpty { draft = newValue }
        }
    }

    @ViewBuilder
    private func editor(_ t: SpoolPalette) -> some View {
        Group {
            if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.t("shelf.loadingNotes"))
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(t.inkSoft)
                }
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                TextEditor(text: $draft)
                    .scrollContentBackground(.hidden)
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                    .frame(minHeight: 140)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.rule, lineWidth: 1)
        )
    }
}

private extension View {
    /// Force the standard `.active` edit mode so the `List`'s `.onMove` drag
    /// handles are always visible while the edit-mode list is shown. `editMode`
    /// is iOS-only (unavailable on the package's macOS tooling target), so the
    /// modifier is a no-op elsewhere — the drag affordance is an iOS surface.
    @ViewBuilder
    func activeEditMode() -> some View {
        #if os(iOS)
        self.environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}

#Preview {
    FullListScreen(onClose: {}).spoolMode(.paper)
}
