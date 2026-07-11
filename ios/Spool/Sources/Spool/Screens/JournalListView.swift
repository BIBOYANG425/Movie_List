import SwiftUI

/// The journal LIST surface (plan Task 5) — lives inside the owner's Stubs tab
/// under the `journal` segment. A search field over a reverse-chron wall of
/// `JournalEntryCard`s, with an empty state when the owner hasn't written
/// anything yet.
///
/// State is owned by a `JournalListModel` (`@MainActor ObservableObject`, iOS-16
/// floor — the `FeedFeedModel` precedent). List mode renders `model.entries`
/// (owner rows, newest first); a non-empty query flips to search mode and
/// renders `model.searchResults`. Both project through the SAME `JournalCardRow`
/// card path, so a search card looks identical to a list card.
///
/// Tapping a card calls `onOpenEntry(tmdbId)` — Task 6 wires this to opening the
/// composer via a `getOwnEntry` probe. For now the Stubs screen passes a closure.
public struct JournalListView: View {
    /// Open the composer for the tapped entry (Task 6 probes `getOwnEntry`).
    private let onOpenEntry: (String) -> Void

    @StateObject private var model = JournalListModel()
    @State private var query: String = ""

    public init(onOpenEntry: @escaping (String) -> Void = { _ in }) {
        self.onOpenEntry = onOpenEntry
    }

    /// Test/preview seam — inject a pre-built model (e.g. a fixture-loaded one)
    /// so previews render populated/empty states without a live client.
    init(model: JournalListModel, onOpenEntry: @escaping (String) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: model)
        self.onOpenEntry = onOpenEntry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 8)

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    // Bottom bar reserved by the root's `.safeAreaInset` (this
                    // list is the Stubs tab's journal segment, which lives under
                    // the bar); small breathing pad only (was 110).
                    .padding(.bottom, 12)
            }
        }
        .task { if !model.didLoad { await model.load() } }
        .onChange(of: query) { newValue in
            Task { await model.search(query: newValue) }
        }
    }

    // MARK: search field

    private var searchField: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(t.inkSoft)
                TextField(L10n.t("journal.searchPlaceholder"), text: $query)
                    .font(SpoolFonts.serif(15))
                    .foregroundStyle(t.ink)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(t.inkSoft)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .list:
            if !model.didLoad {
                // Avoid a one-frame empty-state flash before the first load.
                Color.clear.frame(height: 1)
            } else if model.entries.isEmpty {
                emptyState
            } else {
                cardWall(rows: model.entries.map(\.cardRow))
            }
        case .search:
            if model.searchResults.isEmpty {
                searchEmptyState
            } else {
                cardWall(rows: model.searchResults.map(\.cardRow))
            }
        }
    }

    @ViewBuilder
    private func cardWall(rows: [JournalCardRow]) -> some View {
        LazyVStack(spacing: 14) {
            ForEach(rows) { row in
                JournalEntryCard(
                    row: row,
                    liked: model.isLiked(row.id),
                    onTap: { onOpenEntry(tmdbID(for: row.id)) },
                    onToggleLike: { Task { await model.toggleLike(entryID: row.id) } }
                )
            }
        }
    }

    /// Resolve the tmdb_id for a card so `onOpenEntry` can probe the composer.
    /// The card row drops it, so look it back up on the model's source rows.
    private func tmdbID(for entryID: UUID) -> String {
        if let row = model.entries.first(where: { $0.id == entryID }) { return row.tmdb_id }
        if let row = model.searchResults.first(where: { $0.id == entryID }) { return row.tmdb_id }
        return ""
    }

    // MARK: empty states

    private var emptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Text(L10n.t("journal.listEmpty"))
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }

    private var searchEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 8) {
                Spacer(minLength: 40)
                Text(L10n.t("journal.nothingMatches"))
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension JournalRow {
    static func fixture(id: UUID = UUID(), title: String, review: String?,
                        moods: [String], likes: Int, visibility: String?) -> JournalRow {
        JournalRow(
            id: id, user_id: UUID(), tmdb_id: "tmdb_\(title)", title: title,
            poster_url: nil, rating_tier: "A", review_text: review,
            contains_spoilers: false, mood_tags: moods, vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: "2019-06-15", watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: [], visibility_override: visibility,
            like_count: likes, created_at: "2026-07-01T12:00:00+00:00"
        )
    }
}

/// A model pre-seeded with fixture rows for previews (no network / no client).
@MainActor
private func previewModel(entries: [JournalRow]) -> JournalListModel {
    let model = JournalListModel(
        listOwnEntries: { entries },
        likedEntryIDs: { _ in Set(entries.prefix(1).map(\.id)) },
        search: { _ in [] },
        toggleLike: { _, _ in }
    )
    return model
}

private struct JournalListPreviewHost: View {
    let model: JournalListModel
    var body: some View {
        SpoolScreen {
            JournalListView(model: model)
                .task { await model.load() }
        }
    }
}

#Preview("journal · with entries") {
    JournalListPreviewHost(model: previewModel(entries: [
        .fixture(title: "In the Mood for Love",
                 review: "cried on the 6 train. wong kar-wai understood something about longing.",
                 moods: ["moved", "melancholy"], likes: 12, visibility: "public"),
        .fixture(title: "Paris, Texas", review: "a slow ache of a movie.",
                 moods: ["contemplative"], likes: 3, visibility: "friends"),
        .fixture(title: "Moonlight", review: nil,
                 moods: ["heartbroken"], likes: 0, visibility: "private"),
    ]))
    .spoolMode(.paper)
}

#Preview("journal · empty") {
    JournalListPreviewHost(model: previewModel(entries: []))
        .spoolMode(.paper)
}

#Preview("journal · with entries (dark)") {
    JournalListPreviewHost(model: previewModel(entries: [
        .fixture(title: "Portrait of a Lady on Fire", review: "the last shot.",
                 moods: ["haunted", "moved"], likes: 7, visibility: nil),
    ]))
    .spoolMode(.dark)
}
#endif
