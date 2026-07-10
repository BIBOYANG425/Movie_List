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
/// delete first opens a destructive confirmation dialog NAMING the movie;
/// re-rank closes this sheet and enters the ceremony preseeded with the RAW item
/// (NO watchlist origin) via the `onRerank` hand-off wired in `SpoolAppRoot`.
/// When edit mode exits the screen syncs its read-only `items` from
/// `manage.flatItems` (local copy, no network) so `#rank` badges reflect the
/// dragged order immediately. Movies only — the shelf reads `user_rankings`
/// exclusively, so every card is a movie and the menu needs no media-kind guard.
///
/// Header last reviewed: 2026-07-09
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
    /// never blanks an existing note (the shelf item carries no notes column).
    @State private var notesTarget: RankedItem? = nil
    @State private var notesDraft: String = ""
    @State private var notesLoading: Bool = false
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
                onSave: { text in
                    let item = target
                    notesTarget = nil
                    Task { await manage.saveNotes(item: item, notes: text) }
                },
                onCancel: { notesTarget = nil }
            )
        }
        .confirmationDialog(
            deleteTarget.map { "delete \($0.title)?" } ?? "delete?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
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
            Button("cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("this removes it from your shelf. it won't return to your watchlist.")
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
    private func openNotes(for item: RankedItem) {
        notesTarget = item
        notesDraft = ""
        notesLoading = true
        Task {
            let existing = await manage.fetchNotes(item: item)
            // Only apply if the user hasn't closed / switched targets meanwhile.
            if notesTarget?.id == item.id {
                notesDraft = existing ?? ""
                notesLoading = false
            }
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
                Text(manage.isEditing ? "done" : "edit")
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
            Text("edit").opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
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
    /// edit notes, re-rank, delete. Every shelf row is a movie (the surface reads
    /// `user_rankings` exclusively), so the movies-only rule is satisfied by
    /// construction — no media-kind branch is needed here. All actions route
    /// through the injected-closure `RankManageModel` (optimistic + revert +
    /// toast, tested); this builder only shapes the menu.
    @ViewBuilder
    private func rankMenu(for item: RankedItem) -> some View {
        // Move to tier — a submenu of every tier EXCEPT the one it's in. Each
        // move appends to the target tier's tail (menu moves never pick a slot).
        Menu("move to tier") {
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
            Label("edit notes", systemImage: "square.and.pencil")
        }

        Button {
            manage.requestRerank(item: item)
        } label: {
            Label("re-rank", systemImage: "arrow.up.arrow.down")
        }

        // Destructive delete — the actual removal waits on the confirmation
        // dialog (which names the movie); this only opens it.
        Button(role: .destructive) {
            deleteTarget = item
        } label: {
            Label("delete", systemImage: "trash")
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
                // A signed-out shelf can't be edited — drop any stale edit
                // state so the toggle never survives a session change.
                manage.endEditing()
                manage.setItems([])
            }
            NSLog("[FullListScreen] loaded 0 items (no session)")
            return
        }

        do {
            let fetched = try await RankingRepository.shared.getAllRankedItems()
            if Task.isCancelled { return }
            items = fetched
            // Re-seed the edit model's per-tier membership from the fresh shelf.
            // Editing ends on a reload so a refetched order never fights an
            // in-flight optimistic drag (pull-to-refresh is disabled while
            // editing anyway; this covers the initial load + session flips).
            manage.endEditing()
            manage.setItems(fetched)
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

/// Editor for a ranking's freeform notes (C4 Task 4, "edit notes" menu action).
/// Seeds from `initialNotes` (fetched from the LIVE row by the presenter so an
/// edit never blanks an existing note); shows a loading placeholder while that
/// probe is in flight. `onSave` hands the raw draft up — trimming and nil-
/// normalization happen in `RankManageModel.saveNotes` (tested), keeping the
/// view dumb.
struct RankNotesSheet: View {
    let title: String
    let initialNotes: String
    let loading: Bool
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var draft: String = ""
    @State private var seeded: Bool = false

    var body: some View {
        SpoolScreen {
            SpoolThemeReader { t, _ in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button("cancel", action: onCancel)
                            .font(SpoolFonts.mono(12))
                            .tracking(1.5)
                            .foregroundStyle(t.ink)
                            .buttonStyle(.plain)
                        Spacer()
                        Button("save") { onSave(draft) }
                            .font(SpoolFonts.mono(12))
                            .tracking(1.5)
                            .foregroundStyle(loading ? t.inkSoft : t.ink)
                            .buttonStyle(.plain)
                            .disabled(loading)
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

                    Text("YOUR NOTES")
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
                    Text("loading your notes…")
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
