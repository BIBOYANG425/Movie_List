import SwiftUI
import Spool

@main
struct SpoolAppEntry: App {
    var body: some Scene {
        WindowGroup {
            // OAuth callback handling lives inside AuthService.signInWithGoogle
            // via ASWebAuthenticationSession — the SDK drives the callback URL
            // back into the same async call that opened the sheet, so we don't
            // need an onOpenURL bridge at the scene level. If a deep-link
            // flow is added later, hook it here.
            SpoolAppRoot()
        }
    }
}
