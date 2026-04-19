import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Spool typography. The design calls for Gloock (serif), Kalam (hand),
/// Caveat (script), and DM Mono. If those fonts are bundled into the host
/// app, these return them; otherwise we fall back to system fonts that
/// preserve the feel (serif / handwritten / monospace).
public enum SpoolFonts {

    private static func fontExists(_ name: String, size: CGFloat) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: name, size: size) != nil
        #elseif canImport(AppKit)
        return NSFont(name: name, size: size) != nil
        #else
        return false
        #endif
    }

    public static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontExists("Gloock", size: size) {
            return .custom("Gloock", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    public static func hand(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontExists("Kalam", size: size) {
            return .custom("Kalam", size: size).weight(weight)
        }
        if fontExists("Chalkboard SE", size: size) {
            return .custom("Chalkboard SE", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    public static func script(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontExists("Caveat", size: size) {
            return .custom("Caveat", size: size).weight(weight)
        }
        if fontExists("SnellRoundhand", size: size) {
            return .custom("SnellRoundhand", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif).italic()
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if fontExists("DMMono-Regular", size: size) {
            return .custom("DMMono-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
