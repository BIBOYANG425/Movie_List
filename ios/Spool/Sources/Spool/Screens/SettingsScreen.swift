import SwiftUI

/// Settings presented as a sheet from Profile's top-right gear button.
///
/// Scoped to actions we can reliably perform today:
///  - Sign out (AuthService)
///  - Theme toggle (paper / dark) — pass-through binding from SpoolAppRoot
///  - App version / build info
///  - Placeholder rows for Privacy / Terms (non-destructive, easy to wire later)
///
/// Destructive actions (delete account) are intentionally absent until we have
/// a proper server-side cascade + confirmation flow.
///
/// Header last reviewed: 2026-04-20
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
                        preferencesSection
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
                    Text("close")
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("settings")
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                // Invisible balancer — keeps the title centered without
                // math. Matches the close button's width.
                Text("close").opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
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
        section(title: "ACCOUNT") { t in
            if let profile {
                VStack(spacing: 0) {
                    row(title: profile.handle, subtitle: email ?? profile.displayedName, t: t)
                    divider(t: t)
                    linkRow(title: "edit profile", t: t) { editing = true }
                }
            } else if hasSession {
                // Signed in, but neither profile fetch nor auth-session
                // email hydrated (transient network, RLS glitch). Show
                // something honest — the sign-out path elsewhere in the
                // sheet still works because it keys off `hasSession`.
                row(
                    title: email ?? "signed in",
                    subtitle: email == nil
                        ? "profile not loaded yet — pull to retry"
                        : "profile not loaded yet",
                    t: t
                )
            } else {
                row(title: "preview mode",
                    subtitle: "sign in from the home screen to save your rankings",
                    t: t)
            }
        }
    }

    // MARK: preferences

    private var preferencesSection: some View {
        section(title: "APPEARANCE") { t in
            HStack(spacing: 8) {
                ForEach(ThemePreference.allCases, id: \.self) { p in
                    ThemeChip(label: p.label, selected: preference == p) { preference = p }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: about

    private var aboutSection: some View {
        section(title: "ABOUT") { t in
            VStack(spacing: 0) {
                linkRow(title: "privacy", t: t) { /* placeholder */ }
                divider(t: t)
                linkRow(title: "terms", t: t) { /* placeholder */ }
                divider(t: t)
                row(title: "version", subtitle: Self.versionLabel, t: t)
            }
        }
    }

    // MARK: sign-out button

    private var signOutButton: some View {
        SpoolThemeReader { t, _ in
            Button(action: signOut) {
                HStack(spacing: 8) {
                    if signingOut { ProgressView().tint(t.ink) }
                    Text(signingOut ? "signing out…" : "sign out")
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
                Text(title)
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

#Preview {
    SettingsScreen(
        preference: .constant(.system),
        effectiveMode: .paper,
        onClose: {},
        onSignedOut: {}
    )
}
