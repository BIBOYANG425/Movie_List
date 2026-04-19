import SwiftUI

/// User-visible ephemeral messages. Surfaces persistence failures and other
/// per-action feedback that previously got swallowed by `try?`. Latest-wins
/// semantics: calling `show` while a toast is already on screen replaces it
/// and restarts the auto-dismiss timer. Tap to dismiss immediately.
///
/// Usage sites:
/// - `RankH2HScreen.persistRanking` (signed-in branch) on insert failure
/// - Future: any view-layer catch site that needs user-visible feedback
///
/// Not used for fire-and-forget telemetry (e.g. the `activity_events` insert
/// inside `RankingRepository.insertRanking`) — those stay silent or log.

public enum ToastLevel: Sendable {
    case info
    case error
    case success
}

public struct ToastMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let level: ToastLevel

    public init(id: UUID = UUID(), text: String, level: ToastLevel) {
        self.id = id
        self.text = text
        self.level = level
    }
}

@MainActor
public final class ToastCenter: ObservableObject {

    public static let shared = ToastCenter()

    @Published public private(set) var current: ToastMessage?

    private let sleeper: @Sendable (TimeInterval) async -> Void
    private var pendingDismiss: Task<Void, Never>?

    /// Production singleton — uses real `Task.sleep`. Keep `private` so tests
    /// go through `makeForTesting` with an injected clock instead.
    private init() {
        self.sleeper = { t in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
        }
    }

    internal init(sleeper: @escaping @Sendable (TimeInterval) async -> Void) {
        self.sleeper = sleeper
    }

    /// Factory for tests. Separate from `shared` so unit tests don't leak
    /// state into each other (or into the singleton that the app will reuse).
    internal static func makeForTesting(
        sleeper: @escaping @Sendable (TimeInterval) async -> Void
    ) -> ToastCenter {
        ToastCenter(sleeper: sleeper)
    }

    /// Show a toast. Replaces any current toast (latest wins) and cancels
    /// any in-flight auto-dismiss so the new message gets its own full
    /// `duration` window.
    public func show(_ text: String, level: ToastLevel = .info, duration: TimeInterval = 3) {
        pendingDismiss?.cancel()
        let message = ToastMessage(text: text, level: level)
        current = message
        pendingDismiss = Task { [weak self, sleeper] in
            await sleeper(duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Only dismiss if this message is still the one on screen —
                // a later `show` would have cancelled us, but guard anyway.
                if self.current?.id == message.id {
                    self.current = nil
                }
            }
        }
    }

    public func dismiss() {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        current = nil
    }
}

/// Renders the active `ToastCenter.shared` message as a pill anchored to the
/// top of its container. Mount once at the app root inside a `ZStack` so it
/// floats above all tab content. Native `.sheet` presents above overlays, so
/// this sits below sign-in / other modal sheets as intended.
public struct ToastHost: View {
    @ObservedObject private var center: ToastCenter

    @MainActor
    public init(center: ToastCenter? = nil) {
        self.center = center ?? ToastCenter.shared
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            VStack {
                if let message = center.current {
                    toastPill(for: message, palette: t)
                        .padding(.top, 12)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: center.current?.id)
            .allowsHitTesting(center.current != nil)
        }
    }

    @ViewBuilder
    private func toastPill(for message: ToastMessage, palette: SpoolPalette) -> some View {
        Button {
            center.dismiss()
        } label: {
            Text(message.text)
                .font(SpoolFonts.hand(14))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(background(for: message.level, palette: palette))
                )
                .overlay(Capsule().stroke(palette.ink, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func background(for level: ToastLevel, palette: SpoolPalette) -> Color {
        switch level {
        case .error:   return Color(hex: 0xCE3B1F)
        case .info:    return palette.cream
        case .success: return palette.yellow
        }
    }
}

#Preview("error toast") {
    ZStack {
        Color(hex: 0xF2ECDC).ignoresSafeArea()
        ToastHost()
    }
    .spoolMode(.paper)
    .task {
        ToastCenter.shared.show("couldn't save your rank — check connection", level: .error)
    }
}
