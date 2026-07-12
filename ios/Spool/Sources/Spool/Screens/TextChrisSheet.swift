import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The Settings "text Chris" sheet (P1 M2b) — the user-facing half of the
/// iMessage-companion linking handshake.
///
/// Chris is Spool's iMessage movie friend (a Nolan-inspired companion). On
/// Photon's shared pool there is no static number: `AgentLinkClient.mint` posts
/// the user's phone and gets back THAT phone's personal number to text plus a
/// 6-char link code. This sheet collects the phone, mints, shows the code big,
/// and opens Messages prefilled (`sms:NUMBER&body=CODE`).
///
/// States (rendered from `TextChrisModel.state`, the pure state machine):
///   idle      → phone input + explanatory line + "text Chris" CTA
///   minting   → spinner
///   issued    → the 6-char code in mono, expiry note, "open messages" + "copy code"
///   linked    → linked-phone row (+ since date) + "unlink" (confirmation dialog)
///   unlinking → spinner over the linked row
///
/// All business logic lives on `TextChrisModel`; this view only renders and wires
/// buttons. Copy is Chris's register but the APP's voice rules (no em dashes).
/// Errors surface through the model's `onError` → `ToastCenter` with distinct
/// copy for too_many_codes / pool_unavailable / generic.
///
/// Header last reviewed: 2026-07-11
public struct TextChrisSheet: View {
    public var onClose: () -> Void
    public var effectiveMode: SpoolMode

    @StateObject private var model: TextChrisModel
    @Environment(\.openURL) private var openURL
    @State private var confirmingUnlink: Bool = false
    @State private var copied: Bool = false

    /// Production init — wires the model to `AgentLinkClient` and routes errors to
    /// the shared toast center with per-code copy.
    @MainActor
    public init(effectiveMode: SpoolMode, onClose: @escaping () -> Void) {
        self.effectiveMode = effectiveMode
        self.onClose = onClose
        _model = StateObject(wrappedValue: TextChrisModel.live(onError: { error in
            ToastCenter.shared.show(Self.errorCopy(error), level: .error)
        }))
    }

    /// Test / preview init — inject a pre-built model (stub closures).
    @MainActor
    init(model: TextChrisModel, effectiveMode: SpoolMode, onClose: @escaping () -> Void) {
        self.effectiveMode = effectiveMode
        self.onClose = onClose
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 20) {
                        intro
                        content
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 44)
                }
            }
        }
        .spoolMode(effectiveMode)
        .task { await model.load() }
    }

    // MARK: header

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Button(action: onClose) {
                    Text(L10n.t("agent.close"))
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(L10n.t("agent.title"))
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                Text(L10n.t("agent.close")).opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }

    // MARK: intro (Chris framing)

    private var intro: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("agent.introTitle"))
                    .font(SpoolFonts.serif(18))
                    .foregroundStyle(t.ink)
                Text(L10n.t("agent.introBody"))
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(t.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: state-driven content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            unlinkedContent
        case .minting:
            loadingContent(L10n.t("agent.minting"))
        case let .issued(grant):
            issuedContent(grant)
        case let .linked(links):
            linkedContent(links, busy: false)
        case let .unlinking(links):
            linkedContent(links, busy: true)
        }
    }

    // MARK: (a) unlinked → phone input + CTA

    private var unlinkedContent: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("agent.phoneLabel"))
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                TextField(L10n.t("agent.phonePlaceholder"), text: $model.phoneInput)
                    .font(SpoolFonts.mono(18))
                    .foregroundStyle(t.ink)
                    #if canImport(UIKit)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    #endif
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.rule, lineWidth: 1)
                    )
                    .accessibilityLabel(L10n.t("agent.phoneLabel"))
                Text(L10n.t("agent.phoneHint"))
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                primaryButton(L10n.t("agent.cta"), enabled: !trimmedPhoneEmpty) {
                    Task { await model.mint() }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trimmedPhoneEmpty: Bool {
        model.phoneInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: (b) loading

    private func loadingContent(_ label: String) -> some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                ProgressView().tint(t.ink)
                Text(label)
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    // MARK: (c) code issued → big code + open messages

    private func issuedContent(_ grant: LinkGrant) -> some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                Text(L10n.t("agent.codeCaption"))
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                Text(grant.code)
                    .font(SpoolFonts.mono(40, weight: .medium))
                    .tracking(6)
                    .foregroundStyle(t.ink)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.cream2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(t.ink, lineWidth: 1.2)
                    )
                    .accessibilityLabel(L10n.t("agent.codeA11y", ["code": grant.code]))
                Text(L10n.t("agent.expiryNote"))
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                primaryButton(L10n.t("agent.openMessages"), enabled: true) {
                    openMessages(grant)
                }
                Button(action: { copyCode(grant.code) }) {
                    Text(copied ? L10n.t("agent.copied") : L10n.t("agent.copyCode"))
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(t.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            Capsule().fill(t.cream2).overlay(Capsule().stroke(t.rule, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: (d) linked → row + unlink

    private func linkedContent(_ links: [AgentLink], busy: Bool) -> some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("agent.linkedCaption"))
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                ForEach(links) { link in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.phone)
                            .font(SpoolFonts.mono(18))
                            .foregroundStyle(t.ink)
                        Text(L10n.t("agent.linkedSince", ["date": Self.sinceLabel(link.linkedAt)]))
                            .font(SpoolFonts.hand(12))
                            .foregroundStyle(t.inkSoft)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.rule, lineWidth: 1)
                    )
                }
                Button(action: { confirmingUnlink = true }) {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(t.ink) }
                        Text(busy ? L10n.t("agent.unlinking") : L10n.t("agent.unlink"))
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(t.cream2).overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.top, 4)
                .confirmationDialog(
                    L10n.t("agent.unlinkConfirmTitle"),
                    isPresented: $confirmingUnlink,
                    titleVisibility: .visible
                ) {
                    Button(L10n.t("agent.unlink"), role: .destructive) {
                        Task { await model.unlink() }
                    }
                    Button(L10n.t("agent.cancel"), role: .cancel) {}
                } message: {
                    Text(L10n.t("agent.unlinkConfirmMessage"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: shared primary button

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                Text(title)
                    .font(SpoolFonts.serif(16))
                    .tracking(0.2)
                    .foregroundStyle(enabled ? t.cream : t.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule().fill(enabled ? t.ink : t.cream2)
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)
        }
    }

    // MARK: actions

    private func openMessages(_ grant: LinkGrant) {
        guard let url = SMSLink.compose(number: grant.assignedPhoneNumber, body: grant.code) else { return }
        openURL(url)
    }

    private func copyCode(_ code: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        #endif
        copied = true
        ToastCenter.shared.show(L10n.t("agent.copiedToast"), level: .success)
    }

    // MARK: error copy (typed error → toast string)

    /// Map a typed `AgentLinkError` to user-facing toast copy. Distinct copy for
    /// too_many_codes / pool_unavailable per spec; everything else is the generic
    /// line. Static + pure so it is exercised by the model's error tests via the
    /// same key set.
    static func errorCopy(_ error: AgentLinkClient.AgentLinkError) -> String {
        switch error {
        case .tooManyCodes:    return L10n.t("agent.errorTooManyCodes")
        case .poolUnavailable: return L10n.t("agent.errorPoolUnavailable")
        case .invalidPhone:    return L10n.t("agent.errorInvalidPhone")
        case .notAuthenticated: return L10n.t("agent.errorSignIn")
        case .network:         return L10n.t("agent.errorNetwork")
        case .notConfigured, .spectrumError, .server:
            return L10n.t("agent.errorGeneric")
        }
    }

    // MARK: since-date formatting

    /// Format an ISO-8601 `linkedAt` into a short "MMM d, yyyy" label, or the raw
    /// string if it can't be parsed (never blanks). Mirrors the FeedCards ISO
    /// parse (fractional-or-plain).
    static func sinceLabel(_ raw: String) -> String {
        guard let date = parseTimestamp(raw) else { return raw }
        return dateFormatter.string(from: date).lowercased()
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}

#Preview("unlinked") {
    TextChrisSheet(
        model: TextChrisModel(
            mintFn: { _ in LinkGrant(assignedPhoneNumber: "+13105551234", code: "AB12CD", expiresAt: "", alreadyRegistered: false) },
            statusFn: { [] },
            unlinkFn: {},
            onError: { _ in }
        ),
        effectiveMode: .paper,
        onClose: {}
    )
}
