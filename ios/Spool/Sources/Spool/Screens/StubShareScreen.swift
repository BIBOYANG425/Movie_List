import SwiftUI

/// The "for your story" share sheet. Renders the tapped stub's REAL data
/// (title / tier / review line / moods / date / sequence number / handle) into
/// both the on-screen `AdmitStub` card AND the exported/shared PNG
/// (`StubImageRenderer`). Everything it draws comes from the `StubShare` payload
/// the caller built from the real `StubRow` (see `StubShare.from(row:)`); the
/// sharer's handle is resolved from the real profile on `.task`. There are
/// deliberately NO demo constants here — a real user's shared image must never
/// carry "@yurui" / "cried on the 6 train.".
public struct StubShareScreen: View {
    /// The fully-resolved real stub to render. Its `handle` starts as a best-
    /// effort fallback and is replaced with the signed-in profile handle once
    /// `loadHandle()` resolves.
    @State private var stub: StubShare

    public var onClose: () -> Void

    #if canImport(UIKit)
    private let shareService: ShareService
    #endif

    @State private var toast: String?

    #if canImport(UIKit)
    public init(
        stub: StubShare,
        shareService: ShareService = UIActivityViewControllerShareService(),
        onClose: @escaping () -> Void
    ) {
        _stub = State(initialValue: stub)
        self.shareService = shareService
        self.onClose = onClose
    }
    #else
    public init(stub: StubShare, onClose: @escaping () -> Void) {
        _stub = State(initialValue: stub)
        self.onClose = onClose
    }
    #endif

    public var body: some View {
        SpoolThemeReader { t, mode in
            SpoolScreen(
                background: AnyShapeStyle(
                    RadialGradient(colors: [t.cream2, t.cream], center: .init(x: 0.5, y: 0.2),
                                   startRadius: 0, endRadius: 400)
                )
            ) {
                VStack(spacing: 0) {
                    HStack {
                        Button(L10n.t("stubShare.back"), action: onClose)
                            .font(SpoolFonts.mono(12))
                            .tracking(1)
                            .foregroundStyle(t.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 50)

                    Text(L10n.t("stubShare.forYourStory"))
                        .font(SpoolFonts.script(28))
                        .foregroundStyle(t.ink)
                        .padding(.top, 4)

                    AdmitStub(
                        movie: stub.movie, tier: stub.tier,
                        line: stub.line, moods: stub.moods,
                        date: stub.date, handle: stub.handle, stubNo: stub.stubNo
                    )
                    .rotationEffect(.degrees(-2.5))
                    .padding(.top, 18)
                    .padding(.horizontal, 18)

                    HStack(spacing: 8) {
                        SpoolPill(L10n.t("stubShare.ig"), filled: true, action: { share(subject: "Instagram", mode: mode) })
                        SpoolPill(L10n.t("stubShare.tiktok"), action: { share(subject: "TikTok", mode: mode) })
                        SpoolPill(L10n.t("stubShare.save"), action: { saveToPhotos(mode: mode) })
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 24)

                    SpoolPill(L10n.t("stubShare.postToFeed"), action: {
                        toast = L10n.t("stubShare.comingSoon")
                    })
                        .padding(.horizontal, 18)
                        .padding(.top, 8)

                    if let toast {
                        Text(toast)
                            .font(SpoolFonts.mono(11))
                            .tracking(1)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 16)
                            .transition(.opacity)
                    }

                    Spacer()
                }
            }
        }
        .task { await loadHandle() }
    }

    // MARK: real handle

    /// Resolve the sharer's own handle from the real profile so the exported
    /// image is stamped with their `@handle`, never the literal "@yurui".
    /// Mirrors `ProfileScreen.displayedHandle`: the profile handle when signed
    /// in, else leave the payload's fallback untouched.
    private func loadHandle() async {
        if let profile = try? await ProfileRepository.shared.getMyProfile() {
            await MainActor.run { stub.handle = profile.handle }
        }
    }

    // MARK: actions

    private func share(subject: String, mode: SpoolMode) {
        #if canImport(UIKit)
        guard let image = StubImageRenderer.render(
            movie: stub.movie, tier: stub.tier,
            line: stub.line, moods: stub.moods,
            date: stub.date, handle: stub.handle, stubNo: stub.stubNo,
            mode: mode
        ) else {
            flash("couldn't render stub")
            return
        }
        Task { await shareService.share(image: image, subject: subject) }
        #else
        flash("\(subject) share is iOS-only")
        #endif
    }

    private func saveToPhotos(mode: SpoolMode) {
        #if canImport(UIKit)
        guard let image = StubImageRenderer.render(
            movie: stub.movie, tier: stub.tier,
            line: stub.line, moods: stub.moods,
            date: stub.date, handle: stub.handle, stubNo: stub.stubNo,
            mode: mode
        ) else {
            flash("couldn't render stub")
            return
        }
        Task {
            do {
                try await shareService.saveToPhotos(image: image)
                flash("saved to photos")
            } catch {
                flash("save failed")
            }
        }
        #else
        flash("save is iOS-only")
        #endif
    }

    private func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { if toast == message { toast = nil } }
        }
    }
}

#Preview {
    StubShareScreen(
        stub: StubShare.from(
            day: SpoolData.aprilWatched.first { $0.day == 18 }!,
            stubCount: 127,
            handle: SpoolData.me.handle
        ),
        onClose: {}
    )
    .spoolMode(.paper)
}
