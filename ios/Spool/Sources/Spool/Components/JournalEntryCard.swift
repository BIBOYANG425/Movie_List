import SwiftUI

/// A view-facing projection of a journal row that both `JournalRow` (owner list)
/// and `JournalSearchRow` (search results) map into, so ONE card renders both.
/// It carries only what the card draws — never `personal_takeaway` (owner-only,
/// and the card never shows it anyway).
public struct JournalCardRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let reviewText: String?
    public let moodTags: [String]
    public let photoPaths: [String]
    public let visibilityOverride: String?
    public let likeCount: Int
    /// `created_at` (NOT `updated_at`) — a like bumps `updated_at`, so the card
    /// renders the immutable creation stamp per the contract.
    public let createdAt: String
    /// `watched_date` ("yyyy-MM-dd") — the year source (there is no year column).
    public let watchedDate: String?

    public init(id: UUID, title: String, reviewText: String?, moodTags: [String],
                photoPaths: [String], visibilityOverride: String?, likeCount: Int,
                createdAt: String, watchedDate: String?) {
        self.id = id
        self.title = title
        self.reviewText = reviewText
        self.moodTags = moodTags
        self.photoPaths = photoPaths
        self.visibilityOverride = visibilityOverride
        self.likeCount = likeCount
        self.createdAt = createdAt
        self.watchedDate = watchedDate
    }
}

public extension JournalRow {
    /// Project the owner row to the card shape (drops `personal_takeaway`).
    var cardRow: JournalCardRow {
        JournalCardRow(
            id: id, title: title, reviewText: review_text,
            moodTags: mood_tags ?? [], photoPaths: photo_paths ?? [],
            visibilityOverride: visibility_override, likeCount: like_count,
            createdAt: created_at, watchedDate: watched_date
        )
    }
}

public extension JournalSearchRow {
    /// Project the search row to the card shape.
    var cardRow: JournalCardRow {
        JournalCardRow(
            id: id, title: title, reviewText: review_text,
            moodTags: mood_tags ?? [], photoPaths: photo_paths ?? [],
            visibilityOverride: visibility_override, likeCount: like_count,
            createdAt: created_at, watchedDate: watched_date
        )
    }
}

/// A torn-page paper card for one journal entry (plan Task 5), reusing the
/// AdmitStub / SpoolTokens paper idiom. Shows the film title + year, mood-tag
/// stamps (labels from `JournalConstants`), a review excerpt, the OWNER'S photo
/// thumbnail strip (signed URLs minted via `PhotoStore` — this is the owner's
/// own journal, so owner-only storage SELECT is sufficient; a camera glyph shows
/// while present-but-unloaded photos resolve), a visibility glyph, and the like
/// count. `created_at` is rendered, never `updated_at`.
///
/// Tapping the body calls `onTap` (Task 6 opens the composer via a `getOwnEntry`
/// probe); the heart calls `onToggleLike`. Photos load lazily on appear via the
/// injected `signPhotos` closure (defaults to the real `PhotoStore`).
public struct JournalEntryCard: View {
    public let row: JournalCardRow
    public let liked: Bool
    public let onTap: () -> Void
    public let onToggleLike: () -> Void
    /// Batch-sign a set of stored paths → a map keyed by the original path.
    /// Injected so previews can render without a live storage client.
    public let signPhotos: ([String]) async -> [String: URL]

    @State private var signedURLs: [String: URL] = [:]
    @State private var photosResolved = false

    public init(
        row: JournalCardRow,
        liked: Bool,
        onTap: @escaping () -> Void = {},
        onToggleLike: @escaping () -> Void = {},
        signPhotos: @escaping ([String]) async -> [String: URL] = { paths in
            (try? await PhotoStore.shared.signedURLs(forPaths: paths)) ?? [:]
        }
    ) {
        self.row = row
        self.liked = liked
        self.onTap = onTap
        self.onToggleLike = onToggleLike
        self.signPhotos = signPhotos
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                header(t: t)
                if let excerpt = reviewExcerpt {
                    Text(excerpt)
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                        .lineSpacing(2)
                        .padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.moodTags.isEmpty {
                    moodStamps(t: t)
                        .padding(.top, 10)
                }
                if !row.photoPaths.isEmpty {
                    photoStrip(t: t)
                        .padding(.top, 10)
                }
                footer(t: t)
                    .padding(.top, 12)
            }
            .padding(16)
            .background(t.cream)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task(id: row.id) { await loadPhotos() }
    }

    // MARK: header (title + year + visibility)

    @ViewBuilder
    private func header(t: SpoolPalette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(SpoolFonts.serif(20))
                    .tracking(-0.3)
                    .lineLimit(2)
                    .foregroundStyle(t.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let year = Self.year(from: row.watchedDate) {
                    Text(String(year))
                        .font(SpoolFonts.mono(10))
                        .tracking(1)
                        .foregroundStyle(t.inkSoft)
                }
            }
            Spacer(minLength: 4)
            visibilityGlyph(t: t)
        }
    }

    /// public → 🌐, friends → 👥, private → 🔒, default (nil override) → a
    /// dashed circle meaning "follows your profile default". Rendered as a small
    /// glyph in the top-right corner.
    @ViewBuilder
    private func visibilityGlyph(t: SpoolPalette) -> some View {
        Text(Self.visibilitySymbol(row.visibilityOverride))
            .font(SpoolFonts.mono(11))
            .foregroundStyle(t.inkSoft)
            .accessibilityLabel(Self.visibilityAccessibility(row.visibilityOverride))
    }

    // MARK: review excerpt

    private var reviewExcerpt: String? {
        guard let text = row.reviewText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return Self.truncate(text, limit: 180)
    }

    // MARK: mood stamps

    @ViewBuilder
    private func moodStamps(t: SpoolPalette) -> some View {
        FlowLayout(spacing: 4, rowSpacing: 4) {
            ForEach(row.moodTags, id: \.self) { id in
                Text(JournalConstants.moodLabel(id).lowercased())
                    .font(SpoolFonts.hand(11))
                    .foregroundStyle(t.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1))
            }
        }
    }

    // MARK: photo strip

    @ViewBuilder
    private func photoStrip(t: SpoolPalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(row.photoPaths, id: \.self) { path in
                    photoThumb(path: path, t: t)
                }
            }
        }
    }

    @ViewBuilder
    private func photoThumb(path: String, t: SpoolPalette) -> some View {
        let size: CGFloat = 56
        if let url = signedURLs[path] {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    cameraGlyph(t: t)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.rule, lineWidth: 1))
        } else {
            // Present-but-unloaded: camera glyph until the signed URL resolves.
            cameraGlyph(t: t)
                .frame(width: size, height: size)
                .background(t.cream2)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.rule, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func cameraGlyph(t: SpoolPalette) -> some View {
        Image(systemName: "camera")
            .font(.system(size: 16))
            .foregroundStyle(t.inkSoft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: footer (date + like)

    @ViewBuilder
    private func footer(t: SpoolPalette) -> some View {
        HStack {
            Text(Self.displayDate(row.createdAt))
                .font(SpoolFonts.mono(9))
                .tracking(1)
                .foregroundStyle(t.inkSoft)
            Spacer()
            Button(action: onToggleLike) {
                HStack(spacing: 4) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 12))
                        .foregroundStyle(liked ? t.accent : t.inkSoft)
                    Text("\(row.likeCount)")
                        .font(SpoolFonts.mono(10))
                        .foregroundStyle(t.inkSoft)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Photo loading

    private func loadPhotos() async {
        guard !row.photoPaths.isEmpty, !photosResolved else { return }
        let map = await signPhotos(row.photoPaths)
        signedURLs = map
        photosResolved = true
    }

    // MARK: - Pure helpers

    /// Parse the "yyyy-MM-dd" `watched_date` to a year (nil when absent/unparsable).
    static func year(from watchedDate: String?) -> Int? {
        guard let d = watchedDate else { return nil }
        return d.split(separator: "-").first.flatMap { Int($0) }
    }

    /// The visibility corner glyph. nil override = "default" (follows profile).
    static func visibilitySymbol(_ override: String?) -> String {
        switch override {
        case "public":  return "🌐"
        case "friends": return "👥"
        case "private": return "🔒"
        default:        return "⌾"   // default → follows your profile setting
        }
    }

    static func visibilityAccessibility(_ override: String?) -> String {
        switch override {
        case "public":  return "public"
        case "friends": return "friends only"
        case "private": return "private"
        default:        return "default visibility"
        }
    }

    /// Truncate a review to `limit` chars on a word boundary, appending "…".
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    /// Render a stored ISO-ish `created_at` as "APR · 18 · 2026". Falls back to
    /// the raw leading date portion if it doesn't parse.
    static func displayDate(_ iso: String) -> String {
        // created_at is "yyyy-MM-ddТ…"; take the date part before 'T'.
        let datePart = iso.split(separator: "T").first.map(String.init) ?? iso
        let parts = datePart.split(separator: "-").map(String.init)
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return datePart.uppercased()
        }
        let months = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let m = (1...12).contains(month) ? months[month] : "—"
        return "\(m) · \(String(format: "%02d", day)) · \(parts[0])"
    }
}

// MARK: - Previews

#if DEBUG
private func previewRow(
    title: String, review: String?, moods: [String], photos: [String],
    visibility: String?, likes: Int
) -> JournalCardRow {
    JournalCardRow(
        id: UUID(), title: title, reviewText: review, moodTags: moods,
        photoPaths: photos, visibilityOverride: visibility, likeCount: likes,
        createdAt: "2026-07-01T12:00:00+00:00", watchedDate: "2000-06-15"
    )
}

#Preview("card · with photos + public") {
    JournalEntryCard(
        row: previewRow(
            title: "In the Mood for Love",
            review: "cried on the 6 train. wong kar-wai understood something about longing that i am still catching up to.",
            moods: ["moved", "melancholy", "nostalgic"],
            photos: ["a/b/0.jpg", "a/b/1.jpg"],
            visibility: "public", likes: 12
        ),
        liked: true,
        signPhotos: { _ in [:] }   // stays on the camera glyph in previews
    )
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("card · no photos + friends") {
    JournalEntryCard(
        row: previewRow(
            title: "Paris, Texas", review: "a slow ache of a movie.",
            moods: ["contemplative"], photos: [], visibility: "friends", likes: 3
        ),
        liked: false,
        signPhotos: { _ in [:] }
    )
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("card · private (dark)") {
    JournalEntryCard(
        row: previewRow(
            title: "Moonlight", review: nil, moods: ["heartbroken", "moved"],
            photos: [], visibility: "private", likes: 0
        ),
        liked: false,
        signPhotos: { _ in [:] }
    )
    .padding()
    .background(SpoolTokens.dark.cream)
    .spoolMode(.dark)
}

#Preview("card · default visibility") {
    JournalEntryCard(
        row: previewRow(
            title: "Portrait of a Lady on Fire", review: "the last shot.",
            moods: ["haunted"], photos: [], visibility: nil, likes: 7
        ),
        liked: true,
        signPhotos: { _ in [:] }
    )
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}
#endif
