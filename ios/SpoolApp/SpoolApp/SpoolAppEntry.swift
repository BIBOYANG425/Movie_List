import SwiftUI
import Spool

@main
struct SpoolAppEntry: App {
    var body: some Scene {
        WindowGroup {
            SpoolAppRoot()
                .onOpenURL { url in
                    AuthService.handleOAuthCallback(url)
                }
        }
    }
}
