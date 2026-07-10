import SwiftUI

/// Settings presented as a sheet from Profile's top-right gear button.
///
/// Scoped to actions we can reliably perform today:
///  - Sign out (AuthService)
///  - Theme toggle (paper / dark) — pass-through binding from SpoolAppRoot
///  - Language toggle (EN / 中文) — writes the `spool_locale` slot via
///    `@AppStorage`; the root's `.id(rawLocale)` re-renders `L10n.t` views live
///    (C6-iOS Task 2)
///  - Profile visibility (public/friends/private) — the explore opt-in loop's
///    other half, backed by `profiles.profile_visibility` (signed-in only)
///  - App version / build info
///  - Placeholder rows for Privacy / Terms (non-destructive, easy to wire later)
///
/// Destructive actions (delete account) are intentionally absent until we have
/// a proper server-side cascade + confirmation flow.
///
/// Header last reviewed: 2026-07-10
public struct SettingsScreen: View {
    public var onClose: () -> Void
    public var onSignedOut: () -> Void
    /// User's theme preference — three values, one of which (`.system`)
    /// tracks the device light/dark setting at render time.
    @Binding public var preference: ThemePreference
    /// Resolved mode that the rest of the app is actually using right now.
    /// Passed in so the sheet itself renders in the live theme — needed
    /// when the user picks `.system` and we want Settings to reflect the
    /// active appearance.
    public var effectiveMode: SpoolMode

    @State private var signingOut: Bool = false
    @State private var profile: ProfileRow?
    @State private var email: String?
    @State private var editing: Bool = false
    /// True once we've confirmed a Supabase session exists. This is the
    /// single source of truth for session-dependent UI (sign out, edit
    /// profile) — previously the view gated those on `profile != nil`,
    /// so a transient profile-fetch failure stranded signed-in users
    /// without a way to sign out.
    @State private var hasSession: Bool = false
    /// Current `profiles.profile_visibility` — `public`/`friends`/`private`.
    /// Defaults to `public` until the read resolves; the picker writes back
    /// via `ProfileRepository.updateVisibility`.
    @State private var visibility: String = "public"
    /// A visibility write is in flight — disables the picker so a rapid
    /// re-tap can't race the round-trip.
    @State private var visibilityBusy: Bool = false
    /// Persisted app language (C6-iOS Task 2). Bound to `LocaleStore.storageKey`
    /// via the SAME raw-string `@AppStorage` contract the theme toggle uses.
    /// Writing here flips `LocaleStore.current` for every non-View reader
    /// (`L10n.t`, `TMDBService`/`SuggestionsClient` locale) AND, because the root
    /// (`SpoolAppRoot`) keys its content on this same slot, re-renders every
    /// `L10n.t`-reading view live.
    ///
    /// Fresh-install ordering (LocaleStore contract): the default is the DEVICE
    /// default (`LocaleStore.current.rawValue`), NOT a bare `"en"`, so opening
    /// Settings on a device-zh install never masks the `.zh` device seed.
    @AppStorage(LocaleStore.storageKey) private var rawLocale: String = LocaleStore.current.rawValue

    public init(preference: Binding<ThemePreference>,
                effectiveMode: SpoolMode,
                onClose: @escaping () -> Void,
                onSignedOut: @escaping () -> Void) {
        self._preference = preference
        self.effectiveMode = effectiveMode
        self.onClose = onClose
        self.onSignedOut = onSignedOut
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 22) {
                        accountSection
                        if hasSession {
                            visibilitySection
                        }
                        preferencesSection
                        languageSection
                        aboutSection
                        if hasSession {
                            signOutButton
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
        .spoolMode(effectiveMode)
        .task { await loadProfile() }
        .sheet(isPresented: $editing) {
            if let profile {
                EditProfileScreen(
                    initial: profile,
                    onClose: { editing = false },
                    onSaved: { updated in
                        self.profile = updated
                    }
                )
                .spoolMode(effectiveMode)
            }
        }
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
                Text(L10n.t("settings.title"))
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                // Invisible balancer — keeps the title centered without
                // math. Matches the close button's width.
                Text(L10n.t("settings.close")).opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }

    // MARK: account

    private var accountSection: some View {
        section(title: L10n.t("settings.sectionAccount")) { t in
            if let profile {
                VStack(spacing: 0) {
                    row(title: profile.handle, subtitle: email ?? profile.displayedName, t: t)
                    divider(t: t)
                    linkRow(title: L10n.t("settings.editProfile"), t: t) { editing = true }
                }
            } else if hasSession {
                // Signed in, but neither profile fetch nor auth-session
                // email hydrated (transient network, RLS glitch). Show
                // something honest — the sign-out path elsewhere in the
                // sheet still works because it keys off `hasSession`.
                row(
                    title: email ?? L10n.t("settings.signedIn"),
                    subtitle: email == nil
                        ? L10n.t("settings.profileNotLoadedRetry")
                        : L10n.t("settings.profileNotLoaded"),
                    t: t
                )
            } else {
                row(title: L10n.t("settings.previewMode"),
                    subtitle: L10n.t("settings.previewModeHint"),
                    t: t)
            }
        }
    }

    // MARK: preferences

    private var preferencesSection: some View {
        section(title: L10n.t("settings.sectionAppearance")) { t in
            HStack(spacing: 8) {
                ForEach(ThemePreference.allCases, id: \.self) { p in
                    ThemeChip(label: L10n.t(Self.themeLabelKey(p)), selected: preference == p) { preference = p }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The L10n key for a theme preference's display label. Kept here (not on
    /// `ThemePreference`) so the copy sweep is a call-site string extraction and
    /// the Theme model type stays free of localization concerns. The raw
    /// preference value (`p.rawValue`) still drives persistence; only the
    /// user-facing label is localized.
    private static func themeLabelKey(_ p: ThemePreference) -> String {
        switch p {
        case .system: return "settings.themeSystem"
        case .paper:  return "settings.themePaper"
        case .dark:   return "settings.themeDark"
        }
    }

    // MARK: language (C6-iOS Task 2)

    /// EN / 中文 language picker — the same paper-capsule chip idiom as APPEARANCE
    /// and PRIVACY. Chips write `rawLocale` (the `LocaleStore` slot), which flips
    /// `LocaleStore.current` for every non-View reader and, via the root's
    /// `.id(rawLocale)`, re-renders every `L10n.t`-reading view live. The row
    /// label + option labels come from `L10n.t` so the row localizes itself.
    private var languageSection: some View {
        section(title: L10n.t("settings.language")) { t in
            HStack(spacing: 8) {
                ForEach(Self.languageOptions, id: \.raw) { option in
                    LanguageChip(
                        label: L10n.t(option.labelKey),
                        selected: rawLocale == option.raw
                    ) {
                        rawLocale = option.raw
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }

    /// The two language options, in EN-then-中文 order. `raw` is the `spool_locale`
    /// slot value; `labelKey` resolves the display label via `L10n.t`.
    static let languageOptions: [(raw: String, labelKey: String)] = [
        (SpoolLocale.en.rawValue, "settings.languageEnglish"),
        (SpoolLocale.zh.rawValue, "settings.languageChinese"),
    ]

    // MARK: profile visibility (explore opt-in)

    /// Lowercase copy per spec: `profile visibility` with a public/friends/
    /// private picker and the footnote that closes the explore opt-in loop.
    private var visibilitySection: some View {
        section(title: L10n.t("settings.sectionPrivacy")) { t in
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("settings.profileVisibility"))
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(Self.visibilityOptions, id: \.self) { option in
                        VisibilityChip(
                            // Localized DISPLAY label only; `option` (the raw
                            // public/friends/private value) still drives the DB
                            // write via setVisibility — never localize the value.
                            label: L10n.t(Self.visibilityLabelKey(option)),
                            selected: visibility == option,
                            disabled: visibilityBusy
                        ) {
                            setVisibility(option)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                Text(L10n.t("settings.visibilityExploreHint"))
                    .font(SpoolFonts.hand(12))
                    .foregroundStyle(t.inkSoft)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
        }
    }

    static let visibilityOptions = ["public", "friends", "private"]

    /// The L10n key for a visibility option's display label. The switch's input
    /// is the RAW option value (the DB-persisted string); only the returned key's
    /// resolved value is user-facing.
    private static func visibilityLabelKey(_ option: String) -> String {
        switch option {
        case "friends": return "settings.visFriends"
        case "private": return "settings.visPrivate"
        default:        return "settings.visPublic"
        }
    }

    private func setVisibility(_ value: String) {
        guard value != visibility, !visibilityBusy else { return }
        let previous = visibility
        visibility = value          // optimistic
        visibilityBusy = true
        Task {
            do {
                try await ProfileRepository.shared.updateVisibility(value)
            } catch {
                // Revert on failure — the write didn't take.
                await MainActor.run { visibility = previous }
            }
            await MainActor.run { visibilityBusy = false }
        }
    }

    // MARK: about

    private var aboutSection: some View {
        section(title: L10n.t("settings.sectionAbout")) { t in
            VStack(spacing: 0) {
                linkRow(title: L10n.t("settings.privacy"), t: t) { /* placeholder */ }
                divider(t: t)
                linkRow(title: L10n.t("settings.terms"), t: t) { /* placeholder */ }
                divider(t: t)
                row(title: L10n.t("settings.version"), subtitle: Self.versionLabel, t: t)
            }
        }
    }

    // MARK: sign-out button

    private var signOutButton: some View {
        SpoolThemeReader { t, _ in
            Button(action: signOut) {
                HStack(spacing: 8) {
                    if signingOut { ProgressView().tint(t.ink) }
                    Text(signingOut ? L10n.t("settings.signingOut") : L10n.t("settings.signOut"))
                        .font(SpoolFonts.serif(16))
                        .tracking(0.2)
                        .foregroundStyle(t.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(t.cream2)
                        .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                )
            }
            .buttonStyle(.plain)
            .disabled(signingOut)
            .padding(.top, 6)
        }
    }

    // MARK: helpers

    private func signOut() {
        guard !signingOut else { return }
        signingOut = true
        Task {
            await AuthService.shared.signOut()
            await MainActor.run {
                signingOut = false
                profile = nil
                email = nil
                hasSession = false
                onSignedOut()
            }
        }
    }

    private func loadProfile() async {
        // Check session independently of profile-fetch outcome so a transient
        // fetch error doesn't hide the sign-out button from a signed-in user.
        hasSession = await SpoolClient.currentUserID() != nil
        email = await SpoolClient.currentUserEmail()
        profile = (try? await ProfileRepository.shared.getMyProfile()) ?? nil
        // Read the current visibility (fails soft to the `public` default).
        if hasSession, let current = await ProfileRepository.shared.currentVisibility() {
            visibility = current
        }
    }

    private static var versionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    // MARK: section scaffolding

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        @ViewBuilder content: @escaping (SpoolPalette) -> Content) -> some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(SpoolFonts.mono(10))
                    .tracking(2.5)
                    .foregroundStyle(t.inkSoft)
                VStack(spacing: 0) {
                    content(t)
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(t.cream2.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.rule, lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private func row(title: String, subtitle: String?, t: SpoolPalette) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func linkRow(title: String, t: SpoolPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                Spacer()
                Text("→")
                    .font(SpoolFonts.mono(14))
                    .foregroundStyle(t.inkSoft)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func divider(t: SpoolPalette) -> some View {
        Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 14)
    }
}

private struct ThemeChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                Text(label)
                    .font(SpoolFonts.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(selected ? t.cream : t.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(selected ? t.ink : t.cream2)
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

/// Language picker chip — same paper-capsule idiom as `ThemeChip` (C6-iOS Task 2).
/// Selecting writes the `spool_locale` slot; the a11y label names the language.
private struct LanguageChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                Text(label)
                    .font(SpoolFonts.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(selected ? t.cream : t.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(selected ? t.ink : t.cream2)
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Visibility picker chip — same paper-capsule idiom as `ThemeChip`, with a
/// disabled state while a write is in flight.
private struct VisibilityChip: View {
    let label: String
    let selected: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                Text(label)
                    .font(SpoolFonts.mono(11))
                    .tracking(1.5)
                    .foregroundStyle(selected ? t.cream : t.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(selected ? t.ink : t.cream2)
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
                    )
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled && !selected ? 0.5 : 1)
            .accessibilityLabel(L10n.t("settings.visibilityA11y", ["label": label]))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}

#Preview {
    SettingsScreen(
        preference: .constant(.system),
        effectiveMode: .paper,
        onClose: {},
        onSignedOut: {}
    )
}
