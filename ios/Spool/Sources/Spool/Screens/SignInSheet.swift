import SwiftUI

/// Modal sign-in / sign-up sheet used for recovery from preview mode.
///
/// Why a separate view (not just reusing `OnbSignInScreen`):
///  - OnbSignInScreen is wired into the onboarding sequence (step progress
///    dots, "reserve your seat" theatrical copy). Reusing it outside that
///    context would drag in visual debt that doesn't belong in a recovery
///    sheet.
///  - The behavior is subtly different too: this sheet's "skip" does not
///    mean "skip onboarding" — it means "close this sheet, keep my queued
///    ranking". The parent (RankH2HScreen) decides what to do with that
///    signal.
///
/// The email/password form itself is shared with OnbSignInScreen via
/// `SignInFormBody` below so the two entry points stay in lockstep.
///
/// Header last reviewed: 2026-04-18
public struct SignInSheet: View {
    public var onDone: (SignInResult) -> Void

    public init(onDone: @escaping (SignInResult) -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                t.cream.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Top bar with dismiss
                        HStack {
                            Spacer()
                            Button(action: { onDone(.skipped) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(t.inkSoft)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)

                        Text("— RESERVE YOUR SEAT —")
                            .font(SpoolFonts.mono(10))
                            .tracking(4)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 10)

                        Text("save your\nrankings.")
                            .font(SpoolFonts.serif(46))
                            .tracking(-1.4)
                            .foregroundStyle(t.ink)
                            .lineSpacing(-4)
                            .padding(.top, 14)

                        Text("your stubs live across devices.\nsign in to keep what you just ranked.")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)
                            .lineSpacing(3)
                            .padding(.top, 10)

                        SignInFormBody(onSuccess: { onDone(.signedIn) })
                            .padding(.top, 22)

                        Button(action: { onDone(.skipped) }) {
                            Text("not now — keep previewing")
                                .font(SpoolFonts.hand(12))
                                .foregroundStyle(t.inkSoft)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
        .spoolMode(.paper)
    }
}

// MARK: - Shared email / password form

/// The email + password fields + submit button used by both `OnbSignInScreen`
/// and `SignInSheet`. Owns its own form state — the parent only reacts to
/// `onSuccess`. Failure messages render inline; the parent doesn't need to
/// thread error state through.
///
/// Kept internal to the module on purpose: callers outside Spool should use
/// either `OnbSignInScreen` (onboarding step) or `SignInSheet` (recovery)
/// rather than build their own auth UI around this component.
struct SignInFormBody: View {
    var onSuccess: () -> Void

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var working: Bool = false
    @State private var error: String?
    /// When true, the primary CTA creates a new account instead of signing in.
    /// Default is false — the expected path is "existing user signing back in."
    /// New-account UX is an explicit opt-in below the primary button so a
    /// wrong-password typo can never silently spawn a phantom user (which is
    /// what the old "sign in / sign up" combo button used to do).
    @State private var mode: Mode = .signIn

    enum Mode { case signIn, signUp }

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                googleButton(theme: t)
                dividerRow(theme: t)

                VStack(alignment: .leading, spacing: 10) {
                    SignInFieldRow(label: "EMAIL", placeholder: "you@spool.co",
                                   text: $email, isSecure: false)
                    SignInFieldRow(label: "PASSCODE", placeholder: "8+ characters",
                                   text: $password, isSecure: true)
                }

                if let error {
                    Text(error)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.accent)
                        .padding(.top, 8)
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(t.cream) }
                        Text(working ? "working…" : primaryLabel)
                            .font(SpoolFonts.serif(16))
                            .tracking(0.3)
                            .foregroundStyle(t.cream)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(t.ink))
                }
                .buttonStyle(.plain)
                .disabled(working || !formValid)
                .opacity(formValid ? 1 : 0.45)
                .padding(.top, 22)

                // Mode toggle — small secondary link so the default CTA stays
                // obvious. Toggling clears any stale error for the new intent.
                Button(action: toggleMode) {
                    Text(toggleLabel)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)
                        .underline()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
            }
        }
    }

    private var primaryLabel: String {
        mode == .signIn ? "sign in" : "create account"
    }
    private var toggleLabel: String {
        mode == .signIn ? "new here? create an account" : "have an account? sign in"
    }

    private var formValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8
    }

    private func toggleMode() {
        mode = (mode == .signIn) ? .signUp : .signIn
        error = nil
    }

    private func submit() {
        guard formValid, !working else { return }
        working = true
        error = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let pw = password
        let currentMode = mode
        Task {
            let result: AuthService.AuthResult
            switch currentMode {
            case .signIn:
                result = await AuthService.shared.signIn(email: trimmedEmail, password: pw)
            case .signUp:
                result = await AuthService.shared.signUp(email: trimmedEmail, password: pw)
            }
            await MainActor.run {
                working = false
                switch result {
                case .success:
                    onSuccess()
                case .failure(let e):
                    error = e.userMessage
                }
            }
        }
    }

    // MARK: Google

    /// "Continue with Google" button. Placed above the email form because this
    /// matches the web app's primary auth path — most returning users tap it
    /// first.
    private func googleButton(theme t: SpoolPalette) -> some View {
        Button(action: startGoogle) {
            HStack(spacing: 10) {
                if googleWorking {
                    ProgressView().tint(t.ink)
                } else {
                    Text("G")
                        .font(SpoolFonts.serif(18))
                        .foregroundStyle(t.ink)
                        .frame(width: 22, height: 22)
                        .background(Circle().stroke(t.ink, lineWidth: 1.2))
                }
                Text(googleWorking ? "opening Google…" : "continue with Google")
                    .font(SpoolFonts.serif(16))
                    .tracking(0.2)
                    .foregroundStyle(t.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(t.cream2))
            .overlay(Capsule().stroke(t.ink, lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .disabled(working || googleWorking)
        .opacity(working || googleWorking ? 0.6 : 1)
    }

    private func dividerRow(theme t: SpoolPalette) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(t.rule).frame(height: 1)
            Text("or")
                .font(SpoolFonts.mono(10))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
            Rectangle().fill(t.rule).frame(height: 1)
        }
        .padding(.vertical, 18)
    }

    @State private var googleWorking: Bool = false

    private func startGoogle() {
        guard !googleWorking, !working else { return }
        googleWorking = true
        error = nil
        Task {
            let result = await AuthService.shared.signInWithGoogle()
            await MainActor.run {
                googleWorking = false
                switch result {
                case .success:
                    onSuccess()
                case .failure(let e):
                    error = e.userMessage
                }
            }
        }
    }
}

/// Field row used inside `SignInFormBody`. Mirrors the one in
/// `OnboardingScreens.swift` intentionally — kept separate so that file can
/// stay self-contained and this sheet can live without touching it.
private struct SignInFieldRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool

    @ViewBuilder
    private func emailField(placeholder: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
        #else
        TextField(placeholder, text: text)
        #endif
    }

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        emailField(placeholder: placeholder, text: $text)
                    }
                }
                .font(SpoolFonts.serif(20))
                .foregroundStyle(t.ink)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(t.ink).frame(height: 1.5)
                }
            }
        }
    }
}

#Preview("paper") {
    SignInSheet(onDone: { _ in })
        .spoolMode(.paper)
}

#Preview("dark") {
    SignInSheet(onDone: { _ in })
        .spoolMode(.dark)
}
