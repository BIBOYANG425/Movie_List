import SwiftUI
import Supabase

/// The front face of a feed ticket — an admit-one stub for one `FeedCard`.
/// Extends the existing `AdmitStub`/`TierStamp`/`Tape`/`SpoolTokens` family
/// (spec §1 "ticket wall"): perforated left/right seam, poster-forward, mono
/// caps `ADMIT ONE · @HANDLE · <relativeTime>` header, a rotated tier stamp
/// (S = gold-on-ink) carrying the score for ranking/review events.
///
/// Four event-type variants (spec §FeedTicket): ranking (poster + stamp/score
/// + notes line), review (review-body chip + spoiler shield), list (title +
/// item count), milestone (badge glyph + description). Unknown kinds already
/// coerce to `.ranking` upstream in `FeedCards.kind(forEventType:)`.
///
/// All copy/format decisions that can drift from web live in the pure
/// `FeedTicketPresenter` below (XCTest-covered in FeedTicketLogicTests); this
/// view is a thin renderer over those strings. No UIKit.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 3),
/// spec docs/plans/2026-07-08-c1-ios-feed-ui-design.md.

// MARK: - Pure presentation helpers

/// Variant of the ticket front. Distinct from `FeedCardKind` so the view
/// layer can evolve presentation without touching the data enum, though today
/// they map 1:1.
public enum FeedTicketVariant: Sendable, Equatable {
    case ranking, review, list, milestone
}

/// Pure, testable string/flag composition for the ticket front. No SwiftUI,
/// no environment — everything is a function of the card's fields + metadata.
public enum FeedTicketPresenter {

    /// 1:1 map from data kind to presentation variant.
    public static func variant(for kind: FeedCardKind) -> FeedTicketVariant {
        switch kind {
        case .ranking:   return .ranking
        case .review:    return .review
        case .list:      return .list
        case .milestone: return .milestone
        }
    }

    /// Tier stamp caption. With a score → `"S · 9.4"`; without → `"S"`.
    /// Score renders like web's `card.mediaScore.toFixed(1)`
    /// (FeedRankingCard.tsx L92 / FeedReviewCard.tsx L98): exactly one decimal,
    /// trailing zero kept.
    public static func stampText(tier: Tier, score: Double?) -> String {
        guard let score else { return tier.rawValue }
        return "\(tier.rawValue) · \(toFixed1(score))"
    }

    /// `Number.toFixed(1)` equivalent: one fractional digit, trailing zero
    /// retained. Uses a locale-independent formatter so `9.0` never becomes
    /// `9,0` in a comma-decimal locale.
    /// Accepted divergence (Task 6 ledgers it): `%.1f` rounds exact .x5 ties
    /// half-even (8.25 → "8.2") where JS toFixed rounds half-up ("8.3");
    /// non-tie values agree.
    static func toFixed1(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Review spoiler flag — `metadata["containsSpoilers"] == true`
    /// (feedService.ts L411). Absent / non-bool / nil metadata → false.
    public static func spoilerFlag(from metadata: JSONObject?) -> Bool {
        metadata?["containsSpoilers"]?.boolValue ?? false
    }

    /// Ranking notes line — `metadata["notes"]` (plan Task 3). Trimmed;
    /// empty/whitespace/absent → nil (no empty caption row).
    public static func notesLine(from metadata: JSONObject?) -> String? {
        trimmedNonEmpty(metadata?["notes"]?.stringValue)
    }

    /// Review body chip — `metadata["reviewBody"]` (feedService.ts L409).
    /// Trimmed; empty/absent → nil.
    public static func reviewBody(from metadata: JSONObject?) -> String? {
        trimmedNonEmpty(metadata?["reviewBody"]?.stringValue)
    }

    /// List card summary — `listTitle` + `listItemCount`
    /// (feedService.ts L417–420). Missing title → `"untitled list"`; missing
    /// or malformed count → nil and the view hides the row, mirroring web's
    /// `card.listItemCount != null &&` gate (FeedListCard.tsx L92). A whole
    /// number arriving as a JSON double is coerced via `Int(exactly:)`, which
    /// also degrades NaN / ±inf / out-of-range / non-integral values to nil
    /// instead of trapping.
    public static func listSummary(from metadata: JSONObject?) -> (title: String, count: Int?) {
        let title = trimmedNonEmpty(metadata?["listTitle"]?.stringValue) ?? "untitled list"
        let raw = metadata?["listItemCount"]
        let count = raw?.intValue ?? raw?.doubleValue.flatMap { Int(exactly: $0) }
        return (title, count)
    }

    /// List count row — web-exact wording `{count} movies`, ALWAYS plural even
    /// for 1 (FeedListCard.tsx L94); nil count → nil (row hidden).
    public static func listCountLine(count: Int?) -> String? {
        count.map { "\($0) movies" }
    }

    /// Milestone summary — `badgeIcon` + `milestoneDescription`
    /// (feedService.ts L413–415). Missing icon → fallback medal glyph;
    /// missing description → nil.
    public static func milestoneSummary(from metadata: JSONObject?) -> (icon: String, description: String?) {
        let icon = trimmedNonEmpty(metadata?["badgeIcon"]?.stringValue) ?? "🎖"
        let desc = trimmedNonEmpty(metadata?["milestoneDescription"]?.stringValue)
        return (icon, desc)
    }

    /// Header line — `ADMIT ONE · @HANDLE · <relativeTime>` mono caps (spec §1).
    /// Missing/blank username collapses the handle segment
    /// (`ADMIT ONE · 2H`). Tolerates a username that already carries a leading
    /// `@` so we never render `@@`.
    public static func admitLine(username: String?, relativeTime: String) -> String {
        let time = relativeTime.uppercased()
        guard let bare = bareHandle(username) else {
            return "ADMIT ONE · \(time)"
        }
        return "ADMIT ONE · @\(bare.uppercased()) · \(time)"
    }

    /// Context-menu label — `"<action> @<handle>"` with the same `@` dedup as
    /// `admitLine`; missing/blank username → `"<action> <fallback>"`.
    /// Lowercase, matching the app's menu copy voice.
    public static func menuLabel(action: String, username: String?, fallback: String) -> String {
        guard let bare = bareHandle(username) else {
            return "\(action) \(fallback)"
        }
        return "\(action) @\(bare)"
    }

    /// Media title with the shared fallback — trimmed, `"untitled"` when
    /// missing or blank.
    public static func displayTitle(_ title: String?) -> String {
        trimmedNonEmpty(title) ?? "untitled"
    }

    /// VoiceOver label for the actor avatar — `"avatar of @<handle>"` with the
    /// same `@` dedup + blank collapse as `admitLine`/`menuLabel`; missing or
    /// blank username → plain `"avatar"`. Routes through `bareHandle` so a
    /// username already carrying `@` never renders `@@`.
    public static func avatarAccessibilityLabel(username: String?) -> String {
        guard let bare = bareHandle(username) else { return "avatar" }
        return "avatar of @\(bare)"
    }

    /// VoiceOver label for the tier-stamp cluster: `"tier S, score 9.4"`,
    /// score segment omitted when absent.
    public static func stampAccessibilityLabel(tier: Tier, score: Double?) -> String {
        guard let score else { return "tier \(tier.rawValue)" }
        return "tier \(tier.rawValue), score \(toFixed1(score))"
    }

    // MARK: helpers

    /// Trimmed username minus any leading `@`; nil when missing/blank.
    private static func bareHandle(_ username: String?) -> String? {
        guard let handle = trimmedNonEmpty(username) else { return nil }
        return handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
    }

    private static func trimmedNonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }
}

// MARK: - Front face view

/// The ticket front. Long-press opens the mute/open-actor context menu; a tap
/// anywhere fires `onFlip` (the flip container owns the animation).
public struct FeedTicket: View {
    public var card: FeedCard
    public var onFlip: () -> Void
    public var onMuteUser: () -> Void
    public var onMuteMedia: () -> Void
    public var onOpenActor: () -> Void

    /// Spoiler reveal is view-local state — tapping the shield uncovers the
    /// review body without touching the card model or flipping the ticket.
    @State private var spoilerRevealed = false

    public init(card: FeedCard,
                onFlip: @escaping () -> Void = {},
                onMuteUser: @escaping () -> Void = {},
                onMuteMedia: @escaping () -> Void = {},
                onOpenActor: @escaping () -> Void = {}) {
        self.card = card
        self.onFlip = onFlip
        self.onMuteUser = onMuteUser
        self.onMuteMedia = onMuteMedia
        self.onOpenActor = onOpenActor
    }

    private var variant: FeedTicketVariant { FeedTicketPresenter.variant(for: card.kind) }

    public var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 0) {
                leftSide(t: t)
                rightSide(t: t)
            }
            .background(t.cream)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 0, x: 0, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { onFlip() }
            // The whole front is the flip tap surface — surface it as a
            // button to VoiceOver, with the header line as its label.
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(FeedTicketPresenter.admitLine(
                username: card.actorUsername,
                relativeTime: FeedCards.relativeTime(from: card.createdAt, now: Date())
            ))
            .accessibilityHint("flips the ticket to reactions and comments")
            .contextMenu {
                Button { onOpenActor() } label: {
                    Label(FeedTicketPresenter.menuLabel(action: "open", username: card.actorUsername,
                                                        fallback: "profile"),
                          systemImage: "person.crop.circle")
                }
                Button(role: .destructive) { onMuteUser() } label: {
                    Label(FeedTicketPresenter.menuLabel(action: "mute", username: card.actorUsername,
                                                        fallback: "user"),
                          systemImage: "speaker.slash")
                }
                // Media mute only makes sense when the event carries a title.
                if card.mediaTmdbID != nil {
                    Button(role: .destructive) { onMuteMedia() } label: {
                        Label("mute this title", systemImage: "film")
                    }
                }
            }
        }
    }

    // MARK: left side — header + variant body

    @ViewBuilder
    private func leftSide(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(t: t)

            switch variant {
            case .ranking:   rankingBody(t: t)
            case .review:    reviewBody(t: t)
            case .list:      listBody(t: t)
            case .milestone: milestoneBody(t: t)
            }

            Spacer(minLength: 0)

            Divider().overlay(t.rule).padding(.top, 12)
            Text("TAP TO FLIP · REACT + REPLY")
                .font(SpoolFonts.mono(8))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
                .padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            // dashed right edge (perforation) — same idiom as AdmitStub L118–126.
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(t.ink)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }

    @ViewBuilder
    private func header(t: SpoolPalette) -> some View {
        HStack(spacing: 8) {
            avatar
            Text(FeedTicketPresenter.admitLine(
                username: card.actorUsername,
                relativeTime: FeedCards.relativeTime(from: card.createdAt, now: Date())
            ))
            .font(SpoolFonts.mono(9))
            .tracking(2)
            .foregroundStyle(t.inkSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    /// Actor avatar — AsyncImage over the post-fallback-chain URL, gray circle
    /// placeholder while loading / on failure (plan Task 3).
    @ViewBuilder
    private var avatar: some View {
        let placeholder = Circle().fill(Color.gray.opacity(0.35)).frame(width: 20, height: 20)
        if let urlString = card.actorAvatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
            .accessibilityLabel(avatarAccessibilityLabel)
        } else {
            placeholder
                .accessibilityLabel(avatarAccessibilityLabel)
        }
    }

    private var avatarAccessibilityLabel: String {
        FeedTicketPresenter.avatarAccessibilityLabel(username: card.actorUsername)
    }

    // MARK: variant bodies

    @ViewBuilder
    private func rankingBody(t: SpoolPalette) -> some View {
        titleLine(t: t)
        if let notes = FeedTicketPresenter.notesLine(from: card.metadata) {
            Text("\"\(notes)\"")
                .font(SpoolFonts.script(20))
                .foregroundStyle(t.accent)
                .lineSpacing(2)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func reviewBody(t: SpoolPalette) -> some View {
        titleLine(t: t)
        let body = FeedTicketPresenter.reviewBody(from: card.metadata)
        let hasSpoilers = FeedTicketPresenter.spoilerFlag(from: card.metadata)

        if let body {
            ZStack(alignment: .topLeading) {
                Text(body)
                    .font(SpoolFonts.serif(15))
                    .foregroundStyle(t.ink)
                    .lineLimit(4)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .blur(radius: hasSpoilers && !spoilerRevealed ? 7 : 0)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.cream2)
                    )

                if hasSpoilers && !spoilerRevealed {
                    // Spoiler shield: cover the chip until tapped. Its own tap
                    // handler wins over the card's flip tap.
                    Button {
                        spoilerRevealed = true
                    } label: {
                        Text("spoilers — tap to reveal")
                            .font(SpoolFonts.mono(10))
                            .tracking(1)
                            .foregroundStyle(t.cream)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.ink.opacity(0.85))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func listBody(t: SpoolPalette) -> some View {
        let summary = FeedTicketPresenter.listSummary(from: card.metadata)
        Text("MADE A LIST")
            .font(SpoolFonts.mono(9))
            .tracking(2)
            .foregroundStyle(t.inkSoft)
            .padding(.top, 8)
        Text(summary.title)
            .font(SpoolFonts.serif(24))
            .tracking(-0.3)
            .lineLimit(2)
            .foregroundStyle(t.ink)
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
        // Row hidden when the count is absent/malformed — web parity
        // (FeedListCard.tsx L92); wording via the tested presenter helper.
        if let countLine = FeedTicketPresenter.listCountLine(count: summary.count) {
            Text(countLine)
                .font(SpoolFonts.mono(10))
                .tracking(1)
                .foregroundStyle(t.inkSoft)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func milestoneBody(t: SpoolPalette) -> some View {
        let summary = FeedTicketPresenter.milestoneSummary(from: card.metadata)
        HStack(alignment: .top, spacing: 10) {
            Text(summary.icon)
                .font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text("UNLOCKED A BADGE")
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                if let desc = summary.description {
                    Text(desc)
                        .font(SpoolFonts.serif(18))
                        .foregroundStyle(t.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 10)
    }

    /// Media title line, shared by ranking + review variants.
    @ViewBuilder
    private func titleLine(t: SpoolPalette) -> some View {
        Text(FeedTicketPresenter.displayTitle(card.title))
            .font(SpoolFonts.serif(26))
            .tracking(-0.3)
            .lineLimit(2)
            .foregroundStyle(t.ink)
            .padding(.top, 10)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: right side — poster + tier stamp

    @ViewBuilder
    private func rightSide(t: SpoolPalette) -> some View {
        VStack(spacing: 8) {
            // Poster-forward for media-bearing events; list/milestone with no
            // poster fall through to the stamp column alone.
            if card.mediaTmdbID != nil || card.posterURL != nil {
                PosterBlock(
                    title: FeedTicketPresenter.displayTitle(card.title),
                    seed: Self.stableSeed(card.mediaTmdbID ?? card.id.uuidString),
                    cornerRadius: 3,
                    posterUrl: card.posterURL
                )
                .frame(width: 60)
            }

            // Rotated tier stamp carrying the score (ranking/review). Missing
            // tier → no stamp, no crash (plan Task 3).
            if let tier = card.tier {
                VStack(spacing: 2) {
                    TierStamp(tier: tier, size: 44)
                        .colorScheme(.dark)
                    Text(FeedTicketPresenter.stampText(tier: tier, score: card.score))
                        .font(SpoolFonts.mono(8))
                        .tracking(1)
                        .foregroundStyle(t.cream.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(6)
                .background(Circle().stroke(t.cream.opacity(0.5), lineWidth: 1))
                .rotationEffect(.degrees(-8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(FeedTicketPresenter.stampAccessibilityLabel(
                    tier: tier, score: card.score
                ))
            }

            Text("SPOOL · 2026")
                .font(SpoolFonts.mono(8))
                .tracking(3)
                .foregroundStyle(t.cream.opacity(0.5))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(height: 70)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .background(t.ink)
    }

    /// Deterministic 0-9 poster seed across launches — same djb2/tmdb rule as
    /// StubsScreen.stableSeed so a title always draws the same synthetic art.
    static func stableSeed(_ id: String) -> Int {
        if let digits = id.split(separator: "_").last.flatMap({ Int($0) }) {
            return abs(digits) % 10
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 10)
    }
}

// MARK: - Previews

#if DEBUG
extension FeedCard {
    /// Preview/fixture builder — keeps the #Preview blocks terse.
    static func preview(kind: FeedCardKind,
                        title: String? = "past lives",
                        tier: Tier? = .S,
                        score: Double? = 9.4,
                        tmdbID: String? = "tmdb_5",
                        metadata: JSONObject? = nil,
                        username: String? = "yurui",
                        createdAt: String = "2026-07-07T10:00:00+00:00") -> FeedCard {
        FeedCard(
            id: UUID(), kind: kind, actorID: UUID(),
            eventType: kind.rawValue, mediaTmdbID: tmdbID,
            title: title, tier: tier, posterURL: nil, metadata: metadata,
            createdAt: createdAt, boostedTs: createdAt,
            actorUsername: username, actorAvatarURL: nil, score: score
        )
    }
}

#Preview("ranking · paper") {
    FeedTicket(card: .preview(
        kind: .ranking,
        metadata: ["notes": .string("cried on the 6 train.")]
    ))
    .frame(height: 220)
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("review · spoiler shield") {
    FeedTicket(card: .preview(
        kind: .review, tier: .A, score: 8.7,
        metadata: ["reviewBody": .string("the twist recontextualizes the whole third act."),
                   "containsSpoilers": .bool(true)]
    ))
    .frame(height: 240)
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("review · no spoiler") {
    FeedTicket(card: .preview(
        kind: .review, tier: .B, score: 7.5,
        metadata: ["reviewBody": .string("quietly devastating and beautifully shot.")]
    ))
    .frame(height: 240)
    .padding()
    .background(SpoolTokens.dark.cream)
    .spoolMode(.dark)
}

#Preview("list") {
    FeedTicket(card: .preview(
        kind: .list, title: nil, tier: nil, score: nil, tmdbID: nil,
        metadata: ["listTitle": .string("comfort rewatches"), "listItemCount": .integer(12)]
    ))
    .frame(height: 200)
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("milestone") {
    FeedTicket(card: .preview(
        kind: .milestone, title: nil, tier: nil, score: nil, tmdbID: nil,
        metadata: ["badgeIcon": .string("🏆"), "milestoneDescription": .string("100 films ranked")]
    ))
    .frame(height: 200)
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("ranking · nil tier") {
    FeedTicket(card: .preview(kind: .ranking, tier: nil, score: nil, metadata: nil))
        .frame(height: 200)
        .padding()
        .background(SpoolTokens.paper.cream)
        .spoolMode(.paper)
}
#endif
