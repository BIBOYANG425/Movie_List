import SwiftUI

public struct StubShareScreen: View {
    public var stub: WatchedDay
    public var onClose: () -> Void

    #if canImport(UIKit)
    private let shareService: ShareService
    #endif

    @State private var toast: String?

    #if canImport(UIKit)
    public init(
        stub: WatchedDay,
        shareService: ShareService = UIActivityViewControllerShareService(),
        onClose: @escaping () -> Void
    ) {
        self.stub = stub
        self.shareService = shareService
        self.onClose = onClose
    }
    #else
    public init(stub: WatchedDay, onClose: @escaping () -> Void) {
        self.stub = stub
        self.onClose = onClose
    }
    #endif

    private var stubMovie: Movie {
        Movie(id: stub.title, title: stub.title, year: 2023, director: "celine song", seed: 0)
    }
    private let stubLine = "cried on the 6 train."
    private let stubMoods = ["tender", "devastating"]
    private let stubDate = "APR · 18 · 2026"
    private let stubNo = "#0127"

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
                        Button("← BACK", action: onClose)
                            .font(SpoolFonts.mono(12))
                            .tracking(1)
                            .foregroundStyle(t.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 50)

                    Text("for your story ↓")
                        .font(SpoolFonts.script(28))
                        .foregroundStyle(t.ink)
                        .padding(.top, 4)

                    AdmitStub(
                        movie: stubMovie, tier: stub.tier,
                        line: stubLine, moods: stubMoods,
                        date: stubDate, stubNo: stubNo
                    )
                    .rotationEffect(.degrees(-2.5))
                    .padding(.top, 18)
                    .padding(.horizontal, 18)

                    HStack(spacing: 8) {
                        SpoolPill("↗ IG", filled: true, action: { share(subject: "Instagram", mode: mode) })
                        SpoolPill("↗ tiktok", action: { share(subject: "TikTok", mode: mode) })
                        SpoolPill("↗ save", action: { saveToPhotos(mode: mode) })
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 24)

                    SpoolPill("post to spool feed", action: {
                        toast = "post to feed coming soon"
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
    }

    // MARK: actions

    private func share(subject: String, mode: SpoolMode) {
        #if canImport(UIKit)
        guard let image = StubImageRenderer.render(
            movie: stubMovie, tier: stub.tier,
            line: stubLine, moods: stubMoods,
            date: stubDate, handle: "@yurui", stubNo: stubNo,
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
            movie: stubMovie, tier: stub.tier,
            line: stubLine, moods: stubMoods,
            date: stubDate, handle: "@yurui", stubNo: stubNo,
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
        stub: SpoolData.aprilWatched.first { $0.day == 18 }!,
        onClose: {}
    )
    .spoolMode(.paper)
}
