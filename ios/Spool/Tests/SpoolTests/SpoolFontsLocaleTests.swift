import XCTest
import SwiftUI
@testable import Spool

/// Unit tests for the locale branch in `Theme/SpoolFonts.swift` (design-check
/// Defect 7). `Font` is opaque and non-introspectable, so we can't assert the
/// rendered pixels — that needs an owner device-smoke. What we CAN pin is the
/// pure locale→system-design decision (`systemDesign(for:locale:)`) that drives
/// the CJK substitute, plus that the `.zh` and `.en` code paths diverge:
///
///  * `.en` keeps the Latin custom face → the pure decision returns `nil` and
///    the resolved `Font` equals the pre-change custom/system fallback.
///  * `.zh` swaps in a system CJK-capable design → the decision returns a design,
///    and the resolved `.zh` `Font` differs from the `.en` `Font`.
///
/// The style→design mapping is the load-bearing choice, so it's asserted
/// explicitly per style.
final class SpoolFontsLocaleTests: XCTestCase {

    // MARK: EN keeps the Latin face (no substitute)

    func testEnReturnsNoSubstituteForEveryStyle() {
        for style in SpoolFonts.Style.allCases {
            XCTAssertNil(
                SpoolFonts.systemDesign(for: style, locale: .en),
                "EN must keep the Latin custom face for \(style) — no system design swap"
            )
        }
    }

    func testEnCjkSubstituteIsNilForEveryStyle() {
        for style in SpoolFonts.Style.allCases {
            XCTAssertNil(
                SpoolFonts.cjkSubstitute(for: style, size: 17, weight: .regular, locale: .en),
                "EN must not build a CJK substitute font for \(style)"
            )
        }
    }

    // MARK: ZH swaps in a system CJK design (branch diverges)

    func testZhReturnsSystemDesignForEveryStyle() {
        for style in SpoolFonts.Style.allCases {
            XCTAssertNotNil(
                SpoolFonts.systemDesign(for: style, locale: .zh),
                "ZH must return a system CJK design for \(style)"
            )
        }
    }

    func testZhBuildsACjkSubstituteForEveryStyle() {
        for style in SpoolFonts.Style.allCases {
            XCTAssertNotNil(
                SpoolFonts.cjkSubstitute(for: style, size: 17, weight: .regular, locale: .zh),
                "ZH must build a system CJK substitute font for \(style)"
            )
        }
    }

    // MARK: The style→design mapping (the load-bearing choice)

    func testSerifZhMapsToSerifDesign() {
        let d = SpoolFonts.systemDesign(for: .serif, locale: .zh)
        XCTAssertEqual(d?.design, .serif)
        XCTAssertEqual(d?.italic, false)
    }

    func testHandZhMapsToRoundedDesign() {
        let d = SpoolFonts.systemDesign(for: .hand, locale: .zh)
        XCTAssertEqual(d?.design, .rounded)
        XCTAssertEqual(d?.italic, false)
    }

    func testScriptZhMapsToRoundedNonItalic() {
        // Deliberately NOT the EN italic-serif fallback: CJK synthetic italics
        // read as broken, so the zh script substitute is upright rounded.
        let d = SpoolFonts.systemDesign(for: .script, locale: .zh)
        XCTAssertEqual(d?.design, .rounded)
        XCTAssertEqual(d?.italic, false)
    }

    func testMonoZhMapsToMonospacedDesign() {
        let d = SpoolFonts.systemDesign(for: .mono, locale: .zh)
        XCTAssertEqual(d?.design, .monospaced)
        XCTAssertEqual(d?.italic, false)
    }

    // MARK: EN resolution is unchanged by the fix

    // The fix must touch ONLY the zh branch. The zh branch is added as the FIRST
    // check in each entry point; for `.en` it is never taken (`cjkSubstitute ==
    // nil`, pinned above), so the `.en` resolution is byte-for-byte the
    // pre-change fallback. `serif`/`mono` have no system face that could shadow
    // their fallback on any runner (Gloock / DMMono-Regular aren't installed),
    // so their `.en` fallback is deterministic and pinned exactly here.
    //
    // NOTE ON `Font`-EQUALITY DIVERGENCE: we deliberately do NOT assert
    // `en != zh` via `Font` equality. On this test host the custom faces aren't
    // registered, so `.en serif`/`.en mono` fall back to `.system(.serif)` /
    // `.system(.monospaced)` — which are byte-identical to the zh substitutes.
    // The zh↔en divergence only manifests on a real device where Gloock / DM Mono
    // ARE bundled (there `.en` is `.custom(...)`, `.zh` is `.system(...)`). The
    // portable proof that the branch diverges is the pure-decision tests above
    // (`.en` → nil, `.zh` → a design). Font equality would be a runner-dependent
    // assertion, so it's intentionally omitted (device-smoke covers the pixels).

    func testEnSerifIsSystemSerifFallback() {
        XCTAssertEqual(
            SpoolFonts.serif(30, weight: .regular, locale: .en),
            .system(size: 30, weight: .regular, design: .serif)
        )
    }

    func testEnMonoIsSystemMonospacedFallback() {
        XCTAssertEqual(
            SpoolFonts.mono(10, weight: .regular, locale: .en),
            .system(size: 10, weight: .regular, design: .monospaced)
        )
    }
}
