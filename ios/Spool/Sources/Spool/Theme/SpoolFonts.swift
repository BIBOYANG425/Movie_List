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
///
/// ## CJK behaviour (design-check Defect 7)
/// Gloock / Kalam / Caveat / DM Mono are Latin-only display faces — they carry
/// NO CJK glyphs. When the active locale is `.zh`, rendering a Chinese string in
/// one of them makes iOS silently substitute the system CJK face *per glyph*,
/// which mismatches baseline/weight and shows two faces on a mixed EN+zh line.
/// So when `LocaleStore.current == .zh` we skip the Latin custom face entirely
/// and return a system CJK-capable font at the SAME size/weight, mapped by style
/// (`systemDesign(for:)`). The Latin faces add nothing for Chinese and only cause
/// the mismatch. The EN path is unchanged.
///
/// Locale is read from `LocaleStore.current` the same way `L10n.t` reads it: the
/// public entry points resolve the locale synchronously and delegate to a pure
/// `locale:`-parameterised implementation (unit-testable with zero UserDefaults
/// reads). Live re-render on a language switch rides the root's `.id(rawLocale)`
/// rebuild (the canonical LocaleStore Task-3 pattern), exactly like `L10n.t`.
public enum SpoolFonts {

    /// The four display styles Spool exposes. Used only to key the pure
    /// locale→system-design decision (`systemDesign(for:)`) so it can be tested
    /// without constructing a `Font`.
    public enum Style: CaseIterable {
        case serif, hand, script, mono
    }

    private static func fontExists(_ name: String, size: CGFloat) -> Bool {
        #if canImport(UIKit)
        return UIFont(name: name, size: size) != nil
        #elseif canImport(AppKit)
        return NSFont(name: name, size: size) != nil
        #else
        return false
        #endif
    }

    /// Pure locale→(design, italic) decision for the CJK substitute of each
    /// style. Returns `nil` when the locale keeps the Latin custom face (EN), so
    /// callers know NOT to swap. For `.zh` it returns the system `Font.Design`
    /// that renders Chinese in ONE consistent face with no per-glyph fallback:
    ///
    ///  * `serif`  → `.serif`      — Gloock is a display serif; the system serif
    ///                               design (Songti / 宋体) is the closest CJK
    ///                               analog and keeps the editorial serif feel.
    ///  * `hand`   → `.rounded`    — no system handwriting CJK face exists;
    ///                               rounded is the friendliest/least-jarring
    ///                               casual design (matches the existing
    ///                               non-CJK Kalam fallback, which is `.rounded`).
    ///  * `script` → `.rounded`    — same gap as `hand`; deliberately NOT the
    ///                               EN italic-serif fallback, since CJK italics
    ///                               are synthetic slants that read as broken.
    ///  * `mono`   → `.monospaced` — system monospaced is CJK-capable and keeps
    ///                               the fixed-width / technical look.
    ///
    /// The `italic` flag is always `false` for zh (see `script` above) — CJK
    /// synthetic italics look wrong, so no zh substitute is italicised.
    static func systemDesign(for style: Style, locale: SpoolLocale) -> (design: Font.Design, italic: Bool)? {
        guard locale == .zh else { return nil }
        switch style {
        case .serif:  return (.serif, false)
        case .hand:   return (.rounded, false)
        case .script: return (.rounded, false)
        case .mono:   return (.monospaced, false)
        }
    }

    /// Build the system CJK substitute for `style` at `size`/`weight`, or `nil`
    /// when the locale keeps the Latin custom face. Pure over its inputs.
    static func cjkSubstitute(for style: Style, size: CGFloat, weight: Font.Weight, locale: SpoolLocale) -> Font? {
        guard let d = systemDesign(for: style, locale: locale) else { return nil }
        let base = Font.system(size: size, weight: weight, design: d.design)
        return d.italic ? base.italic() : base
    }

    public static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        serif(size, weight: weight, locale: LocaleStore.current)
    }

    static func serif(_ size: CGFloat, weight: Font.Weight, locale: SpoolLocale) -> Font {
        if let cjk = cjkSubstitute(for: .serif, size: size, weight: weight, locale: locale) {
            return cjk
        }
        if fontExists("Gloock", size: size) {
            return .custom("Gloock", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    public static func hand(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        hand(size, weight: weight, locale: LocaleStore.current)
    }

    static func hand(_ size: CGFloat, weight: Font.Weight, locale: SpoolLocale) -> Font {
        if let cjk = cjkSubstitute(for: .hand, size: size, weight: weight, locale: locale) {
            return cjk
        }
        if fontExists("Kalam", size: size) {
            return .custom("Kalam", size: size).weight(weight)
        }
        if fontExists("Chalkboard SE", size: size) {
            return .custom("Chalkboard SE", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .rounded)
    }

    public static func script(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        script(size, weight: weight, locale: LocaleStore.current)
    }

    static func script(_ size: CGFloat, weight: Font.Weight, locale: SpoolLocale) -> Font {
        if let cjk = cjkSubstitute(for: .script, size: size, weight: weight, locale: locale) {
            return cjk
        }
        if fontExists("Caveat", size: size) {
            return .custom("Caveat", size: size).weight(weight)
        }
        if fontExists("SnellRoundhand", size: size) {
            return .custom("SnellRoundhand", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif).italic()
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        mono(size, weight: weight, locale: LocaleStore.current)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight, locale: SpoolLocale) -> Font {
        if let cjk = cjkSubstitute(for: .mono, size: size, weight: weight, locale: locale) {
            return cjk
        }
        if fontExists("DMMono-Regular", size: size) {
            return .custom("DMMono-Regular", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
