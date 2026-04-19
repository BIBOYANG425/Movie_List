import Spool
import SwiftUI

@main
struct SpoolMacApp: App {
    var body: some Scene {
        WindowGroup {
            SpoolAppRoot()
                .frame(minWidth: 390, minHeight: 720)
        }
        .defaultSize(width: 430, height: 900)
    }
}
