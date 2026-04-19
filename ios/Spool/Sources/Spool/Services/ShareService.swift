import Foundation

#if canImport(UIKit)
import UIKit

/// Protocol so tests / previews can swap in a fake implementation without
/// touching UIKit. Default concrete type is `UIActivityViewControllerShareService`.
public protocol ShareService: Sendable {
    @MainActor func share(image: UIImage, subject: String?) async
    @MainActor func saveToPhotos(image: UIImage) async throws
}

public enum ShareServiceError: Error {
    case noPresenter
    case photosSaveFailed(Error?)
}

public final class UIActivityViewControllerShareService: ShareService {
    public init() {}

    @MainActor
    public func share(image: UIImage, subject: String? = nil) async {
        guard let presenter = Self.topViewController() else { return }
        let vc = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let subject { vc.setValue(subject, forKey: "subject") }
        vc.popoverPresentationController?.sourceView = presenter.view
        vc.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
            width: 0, height: 0
        )
        presenter.present(vc, animated: true)
    }

    @MainActor
    public func saveToPhotos(image: UIImage) async throws {
        let saver = PhotosAlbumSaver()
        try await saver.save(image)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        var root = scene?.keyWindow?.rootViewController
        while let presented = root?.presentedViewController { root = presented }
        return root
    }
}

/// Wraps `UIImageWriteToSavedPhotosAlbum` (a C callback API) as an async throw.
/// Requires `NSPhotoLibraryAddUsageDescription` in Info.plist.
private final class PhotosAlbumSaver: NSObject {
    private var continuation: CheckedContinuation<Void, Error>?

    @MainActor
    func save(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            UIImageWriteToSavedPhotosAlbum(
                image, self,
                #selector(didFinishSaving(image:error:contextInfo:)), nil
            )
        }
    }

    @objc private func didFinishSaving(
        image: UIImage, error: NSError?, contextInfo: UnsafeRawPointer
    ) {
        if let error {
            continuation?.resume(throwing: ShareServiceError.photosSaveFailed(error))
        } else {
            continuation?.resume(returning: ())
        }
        continuation = nil
    }
}
#endif
