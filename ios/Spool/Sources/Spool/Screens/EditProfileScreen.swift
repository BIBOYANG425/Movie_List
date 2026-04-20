import SwiftUI

/// Editor for display name + bio. Opened as a sheet from Settings → Account.
///
/// Username is intentionally read-only here — on web it lives behind a
/// separate handle-change flow (with uniqueness checks) and we don't want to
/// split that validation across two surfaces. Avatar upload is also deferred:
/// the web app uses a storage bucket + signed URLs which needs more plumbing
/// than this first pass warrants.
///
/// Save semantics: empty fields write SQL NULL (ProfileRepository trims and
/// nils). A failed save shows the error inline; the sheet stays open so the
/// user doesn't lose their edits.
///
/// Header last reviewed: 2026-04-20
public struct EditProfileScreen: View {
    public var initial: ProfileRow
    public var onClose: () -> Void
    /// Called after a successful save with the freshly-read row so the
    /// parent can refresh its local profile state without a re-fetch.
    public var onSaved: (ProfileRow) -> Void

    @State private var displayName: String
    @State private var bio: String
    @State private var working: Bool = false
    @State private var errorMessage: String?

    public init(initial: ProfileRow,
                onClose: @escaping () -> Void,
                onSaved: @escaping (ProfileRow) -> Void) {
        self.initial = initial
        self.onClose = onClose
        self.onSaved = onSaved
        _displayName = State(initialValue: initial.display_name ?? "")
        _bio = State(initialValue: initial.bio ?? "")
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        usernameRow
                        fieldSection(label: "DISPLAY NAME",
                                     hint: "shown above your bio on your profile.") { t in
                            inputField(text: $displayName, placeholder: "e.g. yurui",
                                       multiline: false, t: t)
                        }
                        fieldSection(label: "BIO",
                                     hint: "two lines max. press return between them.") { t in
                            inputField(text: $bio, placeholder: "what's your vibe?",
                                       multiline: true, t: t)
                        }

                        if let errorMessage {
                            SpoolThemeReader { t, _ in
                                Text(errorMessage)
                                    .font(SpoolFonts.hand(12))
                                    .foregroundStyle(t.accent)
                            }
                        }

                        saveButton.padding(.top, 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
        }
    }

    // MARK: header

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Button(action: onClose) {
                    Text("cancel")
                        .font(SpoolFonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("edit profile")
                    .font(SpoolFonts.serif(22))
                    .tracking(-0.3)
                    .foregroundStyle(t.ink)
                Spacer()
                // Invisible balancer so the title stays centered without math.
                Text("cancel").opacity(0).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(t.rule).frame(height: 1).padding(.horizontal, 18)
            }
        }
    }

    // MARK: rows

    private var usernameRow: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("USERNAME").font(SpoolFonts.mono(10)).tracking(2.5).foregroundStyle(t.inkSoft)
                HStack {
                    Text(initial.handle)
                        .font(SpoolFonts.serif(20))
                        .foregroundStyle(t.ink)
                    Spacer()
                    Text("read-only")
                        .font(SpoolFonts.mono(10))
                        .tracking(1.5)
                        .foregroundStyle(t.inkSoft)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
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
    private func fieldSection<Content: View>(
        label: String, hint: String,
        @ViewBuilder content: @escaping (SpoolPalette) -> Content
    ) -> some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(SpoolFonts.mono(10)).tracking(2.5).foregroundStyle(t.inkSoft)
                content(t)
                Text(hint).font(SpoolFonts.hand(12)).foregroundStyle(t.inkSoft)
            }
        }
    }

    @ViewBuilder
    private func inputField(text: Binding<String>, placeholder: String,
                            multiline: Bool, t: SpoolPalette) -> some View {
        // iOS-only keyboard modifiers (textInputAutocapitalization etc.) need
        // the `#if os(iOS)` gate so the macOS target (the Swift Package uses
        // the same sources for a macOS tooling target) compiles cleanly.
        Group {
            if multiline {
                TextEditor(text: text)
                    .scrollContentBackground(.hidden)
                    .font(SpoolFonts.serif(16))
                    .foregroundStyle(t.ink)
                    .frame(minHeight: 90)
                    .padding(10)
            } else {
                singleLineField(text: text, placeholder: placeholder, t: t)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.cream2.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.rule, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func singleLineField(text: Binding<String>, placeholder: String, t: SpoolPalette) -> some View {
        let base = TextField(placeholder, text: text)
            .font(SpoolFonts.serif(18))
            .foregroundStyle(t.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        #if os(iOS)
        base
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled(false)
        #else
        base
        #endif
    }

    // MARK: save

    private var saveButton: some View {
        SpoolThemeReader { t, _ in
            Button(action: save) {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(t.cream) }
                    Text(working ? "saving…" : "save")
                        .font(SpoolFonts.serif(16))
                        .tracking(0.2)
                        .foregroundStyle(t.cream)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Capsule().fill(t.ink))
            }
            .buttonStyle(.plain)
            .disabled(working || !dirty)
            .opacity((working || !dirty) ? 0.55 : 1)
        }
    }

    /// Only enable save when the user actually changed something.
    private var dirty: Bool {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName != (initial.display_name ?? "")
            || cleanBio != (initial.bio ?? "")
    }

    private func save() {
        guard !working else { return }
        working = true
        errorMessage = nil
        let name = displayName
        let newBio = bio
        Task { @MainActor in
            // Single `defer` on the main actor ensures `working` is always
            // cleared, no matter which branch we take. Saves duplicating
            // `working = false` across the success and error paths.
            defer { working = false }
            do {
                let updated = try await ProfileRepository.shared.updateMyProfile(
                    displayName: name, bio: newBio
                )
                onSaved(updated)
                onClose()
            } catch {
                errorMessage = "couldn't save — \(errorDescription(error))"
            }
        }
    }

    /// Type-dispatched error mapping. Falls through to string matching only
    /// for surfaces we don't control (e.g., unexpected Supabase errors) —
    /// typed cases first avoids renames silently breaking the UX copy.
    private func errorDescription(_ error: Error) -> String {
        if case ProfileRepository.RepoError.notAuthenticated = error {
            return "sign in again and retry."
        }
        if case ProfileRepository.RepoError.notConfigured = error {
            return "sign-in is offline — try again later."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "check your connection."
            default: break
            }
        }
        return "try again."
    }
}

#Preview {
    EditProfileScreen(
        initial: ProfileRow(
            id: UUID(), username: "yurui",
            display_name: "Yurui", bio: "crying in public is a genre.\nnyc · mostly a24.",
            avatar_url: nil, avatar_path: nil
        ),
        onClose: {},
        onSaved: { _ in }
    )
}
