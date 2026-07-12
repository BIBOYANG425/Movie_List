import Foundation

/// View-model seam for the "daily reel" section of the Text Chris sheet (linked
/// state). Owns the load / edit / save flow for `agent_preferences` as PURE,
/// injectable logic so it is unit-tested without SwiftUI, Supabase, or network —
/// the same seam pattern as `TextChrisModel`.
///
/// Flow:
///   load()                → reads prefs (or contract defaults) → `.ready`
///   setCadence / setHour  → optimistic local edit, then save
///   save()                → writes cadence+hour; on failure reverts to the last
///                           saved snapshot and reports via `onError`
///
/// The client calls are injected as closures (`loadFn` / `saveFn`) so tests drive
/// every transition and the revert-on-failure path with stubs. Production wires
/// them to `AgentPreferencesRepository`. `onError` is the toast seam — the model
/// reports and the sheet maps to copy; the model never owns UI strings.
///
/// Header last reviewed: 2026-07-12
@MainActor
public final class DigestPrefsModel: ObservableObject {

    public enum Phase: Equatable {
        /// Not loaded yet — the section shows nothing / a placeholder.
        case loading
        /// Loaded and editable.
        case ready
    }

    @Published public private(set) var phase: Phase = .loading
    /// The currently-displayed prefs (optimistically updated on edit).
    @Published public private(set) var prefs: DigestPreferences = .defaults
    /// True while a save round-trip is in flight (drives a subtle busy affordance).
    @Published public private(set) var saving: Bool = false

    /// The last value known to be persisted — the revert target if a save fails.
    private var lastSaved: DigestPreferences = .defaults

    private let loadFn: () async -> DigestPreferences?
    private let saveFn: (DigestCadence, Int) async throws -> Void
    private let onError: () -> Void

    public init(
        loadFn: @escaping () async -> DigestPreferences?,
        saveFn: @escaping (DigestCadence, Int) async throws -> Void,
        onError: @escaping () -> Void
    ) {
        self.loadFn = loadFn
        self.saveFn = saveFn
        self.onError = onError
    }

    /// Production wiring: closures call `AgentPreferencesRepository`; `onError`
    /// toasts a generic save-failure line.
    @MainActor
    public static func live(onError: @escaping () -> Void) -> DigestPrefsModel {
        DigestPrefsModel(
            loadFn: { await AgentPreferencesRepository.shared.load() },
            saveFn: { try await AgentPreferencesRepository.shared.save(cadence: $0, hour: $1) },
            onError: onError
        )
    }

    // MARK: - Transitions

    /// Read prefs on appear. A missing row → contract defaults (never an error).
    /// Idempotent: re-loading after ready just refreshes the snapshot.
    public func load() async {
        let loaded = await loadFn() ?? .defaults
        prefs = loaded
        lastSaved = loaded
        phase = .ready
    }

    /// Optimistically set the cadence and persist. A no-op if the value is
    /// unchanged (avoids a redundant write when the user re-taps the current
    /// segment).
    public func setCadence(_ cadence: DigestCadence) async {
        guard cadence != prefs.cadence else { return }
        prefs.cadence = cadence
        await save()
    }

    /// Optimistically set the delivery hour and persist. Clamped to 0...23. A
    /// no-op if unchanged.
    public func setHour(_ hour: Int) async {
        let clamped = DigestPreferences.clampHour(hour)
        guard clamped != prefs.hour else { return }
        prefs.hour = clamped
        await save()
    }

    /// Persist the current prefs. On success the snapshot advances; on failure the
    /// visible prefs revert to the last saved snapshot and the error is reported.
    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await saveFn(prefs.cadence, prefs.hour)
            lastSaved = prefs
        } catch is CancellationError {
            prefs = lastSaved
        } catch {
            prefs = lastSaved
            onError()
        }
    }
}
