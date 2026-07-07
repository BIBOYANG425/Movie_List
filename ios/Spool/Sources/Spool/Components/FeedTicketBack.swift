import SwiftUI

/// The flipped side of a feed ticket (spec §2 "flip the ticket"): five reaction
/// stamps with counts (mine stamped darker + rotated like a real rubber stamp),
/// a scrolling 1-level comment thread, a composer at the bottom (≤500 chars,
/// errors inline), and a `TAP TO FLIP BACK` affordance. Styled to match the
/// front — cream paper, ink border, corner radius 6 — so the flip reads as one
/// physical object turning over.
///
/// All engagement STATE + LOGIC lives in `TicketEngagementModel` (the
/// `@MainActor` `ObservableObject`, XCTest-covered): optimistic toggle +
/// revert, comment validation, thread mutation. This view is a thin renderer
/// over that model plus the reaction-stamp presentation table (`ReactionStamp`)
/// which is a pure spec decision, not a data-layer one. No UIKit.
///
/// Own-comment delete: `currentUserID` scopes the swipe/long-press delete
/// affordance to the viewer's own rows (Task 5 passes the resolved session id;
/// previews pass a fixture). Keyboard behavior (spec §2: "taller card, not a
/// sheet") is the caller's — the back grows with its content inside the flip
/// container rather than presenting a sheet.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 4), spec
/// docs/plans/2026-07-08-c1-ios-feed-ui-design.md §2.

// MARK: - Reaction stamp table (spec §2 — a presentation decision)

/// The five reaction stamps in display order with their glyphs (spec §2:
/// `love 🖤, fire 🔥, laugh 😂, sad 😢, mind_blown 🤯`). The `type` string is
/// the wire value passed to `TicketEngagementModel.toggle(reaction:)`.
public struct ReactionStamp: Identifiable, Sendable, Equatable {
    public let type: String
    public let glyph: String
    public var id: String { type }

    /// Fixed order — matches the spec's stamp row left-to-right.
    public static let all: [ReactionStamp] = [
        ReactionStamp(type: "love", glyph: "🖤"),
        ReactionStamp(type: "fire", glyph: "🔥"),
        ReactionStamp(type: "laugh", glyph: "😂"),
        ReactionStamp(type: "sad", glyph: "😢"),
        ReactionStamp(type: "mind_blown", glyph: "🤯"),
    ]

    /// VoiceOver label — `"love, 4 reactions, reacted"` (plan Task 4 pattern).
    /// Count segment pluralizes; the trailing `, reacted` appears only for the
    /// viewer's own stamps.
    public func accessibilityLabel(count: Int, mine: Bool) -> String {
        let unit = count == 1 ? "reaction" : "reactions"
        let base = "\(type), \(count) \(unit)"
        return mine ? base + ", reacted" : base
    }
}

// MARK: - Ticket back view

public struct FeedTicketBack: View {
    public let card: FeedCard
    @ObservedObject public var model: TicketEngagementModel
    public let currentUserID: UUID?
    public let onFlipBack: () -> Void

    /// The composer field's focus — used to keep the counter/keyboard layout
    /// tidy; the "taller card, not a sheet" growth is the container's.
    @FocusState private var composerFocused: Bool

    public init(card: FeedCard,
                model: TicketEngagementModel,
                currentUserID: UUID? = nil,
                onFlipBack: @escaping () -> Void = {}) {
        self.card = card
        self.model = model
        self.currentUserID = currentUserID
        self.onFlipBack = onFlipBack
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                header(t: t)
                stampRow(t: t)
                Divider().overlay(t.rule).padding(.vertical, 10)
                threadSection(t: t)
                composer(t: t)
                footer(t: t)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.cream)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.ink, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 0, x: 0, y: 1)
        }
    }

    // MARK: header

    @ViewBuilder
    private func header(t: SpoolPalette) -> some View {
        HStack {
            Text("TICKET BACK")
                .font(SpoolFonts.mono(11)).tracking(3)
                .foregroundStyle(t.inkSoft)
            Spacer()
            Text(FeedTicketPresenter.displayTitle(card.title))
                .font(SpoolFonts.mono(9)).tracking(1)
                .foregroundStyle(t.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ticket back for \(FeedTicketPresenter.displayTitle(card.title))")
        .padding(.bottom, 12)
    }

    // MARK: stamp row

    @ViewBuilder
    private func stampRow(t: SpoolPalette) -> some View {
        HStack(spacing: 8) {
            ForEach(ReactionStamp.all) { stamp in
                stampButton(stamp, t: t)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stampButton(_ stamp: ReactionStamp, t: SpoolPalette) -> some View {
        let count = model.counts?.reactions[stamp.type] ?? 0
        let mine = model.counts?.myReactions.contains(stamp.type) ?? false
        Button {
            Task { await model.toggle(reaction: stamp.type) }
        } label: {
            HStack(spacing: 4) {
                Text(stamp.glyph).font(.system(size: 16))
                // Count appears only once it's > 0 (plan Task 4).
                if count > 0 {
                    Text("\(count)")
                        .font(SpoolFonts.mono(10, weight: .medium))
                        .foregroundStyle(mine ? t.cream : t.ink)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    // Mine = darker stamp (ink fill); not-mine = paper.
                    .fill(mine ? t.ink : t.cream2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(t.ink, lineWidth: mine ? 1.5 : 1)
            )
            // Slight rotation sells the rubber-stamp feel when it's mine.
            .rotationEffect(.degrees(mine ? -5 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stamp.accessibilityLabel(count: count, mine: mine))
        .accessibilityAddTraits(mine ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: thread

    @ViewBuilder
    private func threadSection(t: SpoolPalette) -> some View {
        if model.loadFailed {
            emptyRow("couldn't load reactions", t: t)
        } else if model.thread.isEmpty {
            emptyRow("no replies yet — be first", t: t)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.thread, id: \.0.id) { top, replies in
                        commentRow(top, indent: 0, t: t)
                        ForEach(replies, id: \.id) { reply in
                            commentRow(reply, indent: 1, t: t)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private func emptyRow(_ text: String, t: SpoolPalette) -> some View {
        Text(text)
            .font(SpoolFonts.hand(15))
            .foregroundStyle(t.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func commentRow(_ comment: FeedComment, indent: Int, t: SpoolPalette) -> some View {
        let isMine = currentUserID != nil && comment.user_id == currentUserID
        VStack(alignment: .leading, spacing: 2) {
            Text(comment.body)
                .font(SpoolFonts.serif(15))
                .foregroundStyle(t.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, indent == 1 ? 20 : 0)   // one-level reply indent
        .overlay(alignment: .leading) {
            if indent == 1 {
                Rectangle().fill(t.rule).frame(width: 1.5).padding(.vertical, 1)
            }
        }
        .contentShape(Rectangle())
        // Own comment: long-press to delete (works on macOS + iOS).
        .contextMenu {
            if isMine {
                Button(role: .destructive) {
                    Task { await model.deleteComment(id: comment.id) }
                } label: {
                    Label("delete", systemImage: "trash")
                }
            }
        }
        // Own comment: swipe-to-delete on iOS list-like gesture parity.
        .modifier(SwipeDeleteModifier(enabled: isMine) {
            Task { await model.deleteComment(id: comment.id) }
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(indent == 1 ? "reply: \(comment.body)" : comment.body)
        .accessibilityHint(isMine ? "your comment, long-press to delete" : "")
    }

    // MARK: composer

    @ViewBuilder
    private func composer(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                composerField(t: t)
                sendButton(t: t)
            }
            HStack {
                if let error = model.inlineError {
                    Text(error)
                        .font(SpoolFonts.mono(10))
                        .foregroundStyle(t.accent)
                        .accessibilityLabel("error: \(error)")
                }
                Spacer()
                // Counter appears only as the draft nears the limit.
                if let counter = Self.counterText(count: model.draft.count) {
                    Text(counter)
                        .font(SpoolFonts.mono(10))
                        .foregroundStyle(model.draft.count > FeedPipelineComments.maxBodyLength ? t.accent : t.inkSoft)
                }
            }
            .frame(minHeight: 14)
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private func composerField(t: SpoolPalette) -> some View {
        let field = TextField("say something…", text: $model.draft, axis: .vertical)
            .font(SpoolFonts.serif(15))
            .foregroundStyle(t.ink)
            .lineLimit(1...4)
            .focused($composerFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.cream2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.rule, lineWidth: 1)
            )
        #if os(iOS)
        field.textInputAutocapitalization(.sentences)
        #else
        field
        #endif
    }

    @ViewBuilder
    private func sendButton(t: SpoolPalette) -> some View {
        Button {
            composerFocused = false
            Task { await model.addComment() }
        } label: {
            Group {
                if model.sending {
                    ProgressView().tint(t.cream)
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 14))
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(t.ink))
            .foregroundStyle(t.cream)
        }
        .buttonStyle(.plain)
        .disabled(model.sending)
        .opacity(model.sending ? 0.6 : 1)
        .accessibilityLabel("post comment")
    }

    // MARK: footer

    @ViewBuilder
    private func footer(t: SpoolPalette) -> some View {
        Button(action: onFlipBack) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9))
                Text("TAP TO FLIP BACK").font(SpoolFonts.mono(8)).tracking(2)
            }
            .foregroundStyle(t.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("flip back to the ticket front")
    }

    // MARK: pure copy

    /// The char counter appears only within 60 of the 500 cap (and stays on
    /// while over the limit); otherwise it's hidden so the composer reads clean.
    /// Returns `"<count>/500"`.
    static func counterText(count: Int) -> String? {
        guard count >= FeedPipelineComments.maxBodyLength - 60 else { return nil }
        return "\(count)/\(FeedPipelineComments.maxBodyLength)"
    }
}

// MARK: - Swipe-to-delete (own comments only)

/// Wraps a row in a `.swipeActions` delete on iOS when `enabled`; a no-op
/// elsewhere. `.swipeActions` needs a `List` context on some platforms, so
/// this degrades to the context-menu path (always present) when swipe isn't
/// available — the delete is never the ONLY affordance.
private struct SwipeDeleteModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive, action: action) {
                    Label("delete", systemImage: "trash")
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Previews

#if DEBUG
/// Fixed viewer id for previews — non-isolated so free preview helpers can
/// reference it too.
private let kPreviewMe = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private struct PreviewError: Error {}

extension TicketEngagementModel {
    static var previewMe: UUID { kPreviewMe }

    /// Preview builder — seeds counts + a nested thread through the real load
    /// path (injected closures return fixtures), so previews exercise the same
    /// state machine the app uses.
    @MainActor
    static func preview(counts: EngagementCounts,
                        thread: [FeedComment],
                        loadFails: Bool = false) -> TicketEngagementModel {
        let model = TicketEngagementModel(
            eventID: UUID(),
            loadCounts: {
                if loadFails { throw PreviewError() }
                return counts
            },
            loadThread: { thread },
            toggleReaction: { _, mine in !mine },
            addComment: { body in
                FeedComment(id: UUID(), event_id: UUID(), user_id: kPreviewMe,
                            body: body, parent_comment_id: nil,
                            created_at: "2026-07-07T12:00:00+00:00")
            },
            deleteComment: { _ in }
        )
        return model
    }
}

private func previewComment(_ body: String, mine: Bool = false, parent: UUID? = nil,
                            id: UUID = UUID()) -> FeedComment {
    FeedComment(id: id, event_id: UUID(),
                user_id: mine ? kPreviewMe : UUID(),
                body: body, parent_comment_id: parent,
                created_at: "2026-07-07T12:00:00+00:00")
}

private struct BackPreviewHost: View {
    let model: TicketEngagementModel
    var body: some View {
        FeedTicketBack(
            card: .preview(kind: .ranking, title: "past lives"),
            model: model,
            currentUserID: TicketEngagementModel.previewMe
        )
        .padding()
        .background(SpoolTokens.paper.cream)
        .spoolMode(.paper)
        .task { await model.load() }
    }
}

#Preview("back · thread + my reaction") {
    let top = previewComment("this wrecked me. the airport scene.")
    let reply = previewComment("RIGHT. couldn't speak after.", mine: true, parent: top.id)
    return BackPreviewHost(model: .preview(
        counts: EngagementCounts(
            reactions: ["love": 4, "fire": 2, "laugh": 0, "sad": 7, "mind_blown": 1],
            comments: 2,
            myReactions: ["love", "sad"]
        ),
        thread: [top, reply]
    ))
}

#Preview("back · empty thread") {
    BackPreviewHost(model: .preview(
        counts: EngagementCounts(
            reactions: ["love": 0, "fire": 0, "laugh": 0, "sad": 0, "mind_blown": 0],
            comments: 0, myReactions: []
        ),
        thread: []
    ))
}

#Preview("back · load error") {
    BackPreviewHost(model: .preview(
        counts: EngagementCounts(reactions: [:], comments: 0, myReactions: []),
        thread: [],
        loadFails: true
    ))
}

#Preview("back · dark") {
    let top = previewComment("the score alone earns the S.")
    return FeedTicketBack(
        card: .preview(kind: .review, title: "sinners"),
        model: .preview(
            counts: EngagementCounts(
                reactions: ["love": 9, "fire": 12, "laugh": 1, "sad": 0, "mind_blown": 5],
                comments: 1, myReactions: ["fire", "mind_blown"]
            ),
            thread: [top]
        ),
        currentUserID: TicketEngagementModel.previewMe
    )
    .padding()
    .background(SpoolTokens.dark.cream)
    .spoolMode(.dark)
}
#endif
