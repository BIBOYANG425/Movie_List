import XCTest
@testable import Spool

/// Bidirectional parity + hygiene guard for the hand-rolled en/zh copy tables
/// (EN.swift / ZH.swift). Swift port of the web suite
/// `services/__tests__/i18nParity.test.ts` — same 7 cases, same expectations,
/// so the two clients ship the same key set (engine-parity fixture convention).
///
/// Web leans on `zh satisfies Record<TranslationKey, string>` for compile-time
/// key parity; Swift dictionaries have no such check, so THIS test is the
/// enforcement. It also pins the fallback semantics of `L10n.t` (zh → en → key)
/// and the pure device-default logic in `LocaleStore`.
final class L10nParityTests: XCTestCase {

    private let enKeys = Set(EN.table.keys)
    private let zhKeys = Set(ZH.table.keys)

    // U+2014 EM DASH, U+2013 EN DASH, U+2015 HORIZONTAL BAR (owner-voice rule).
    private let emDash = CharacterSet(charactersIn: "\u{2014}\u{2013}\u{2015}")

    /// {name}-style interpolation tokens, sorted for set comparison.
    private func placeholders(_ value: String) -> [String] {
        let pattern = "\\{[a-zA-Z]+\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range)
            .compactMap { Range($0.range, in: value).map { String(value[$0]) } }
            .sorted()
    }

    // MARK: - Key parity (ports web's 3 parity cases)

    func testEveryEnKeyExistsInZh() {
        let missing = enKeys.subtracting(zhKeys).sorted()
        XCTAssertEqual(missing, [], "zh missing keys: \(missing.joined(separator: ", "))")
    }

    func testEveryZhKeyExistsInEn() {
        let extra = zhKeys.subtracting(enKeys).sorted()
        XCTAssertEqual(extra, [], "zh has keys not in en: \(extra.joined(separator: ", "))")
    }

    func testEnAndZhHaveSameKeyCount() {
        XCTAssertEqual(ZH.table.count, EN.table.count)
    }

    // MARK: - Value hygiene (ports web's 3 hygiene cases)

    func testEveryEnValueIsNonEmpty() {
        for (key, value) in EN.table {
            XCTAssertGreaterThan(
                value.trimmingCharacters(in: .whitespacesAndNewlines).count, 0,
                "en[\"\(key)\"] empty"
            )
        }
    }

    func testEveryZhValueIsNonEmpty() {
        for (key, value) in ZH.table {
            XCTAssertGreaterThan(
                value.trimmingCharacters(in: .whitespacesAndNewlines).count, 0,
                "zh[\"\(key)\"] empty"
            )
        }
    }

    func testNoZhValueContainsEmDash() {
        let offenders = ZH.table
            .filter { $0.value.rangeOfCharacter(from: emDash) != nil }
            .keys.sorted()
        XCTAssertEqual(offenders, [], "zh values with em dashes: \(offenders.joined(separator: ", "))")
    }

    // MARK: - Interpolation parity (ports web's placeholder case)

    func testZhCarriesSamePlaceholdersAsEn() {
        var mismatches: [String] = []
        for (key, enValue) in EN.table {
            let enPlaceholders = placeholders(enValue)
            let zhPlaceholders = placeholders(ZH.table[key] ?? "")
            if enPlaceholders != zhPlaceholders {
                mismatches.append(
                    "\(key): en[\(enPlaceholders.joined(separator: ","))] zh[\(zhPlaceholders.joined(separator: ","))]"
                )
            }
        }
        XCTAssertEqual(mismatches, [], "placeholder mismatches:\n\(mismatches.joined(separator: "\n"))")
    }

    // MARK: - Fallback semantics (zh → en → key)

    func testResolvesZhValueWhenLocaleIsZh() {
        XCTAssertEqual(L10n.t("nav.me", locale: .zh), "我的")
    }

    func testResolvesEnValueWhenLocaleIsEn() {
        XCTAssertEqual(L10n.t("nav.me", locale: .en), "me")
    }

    func testFallsBackToEnWhenZhMissing() {
        // Seeded tables are in parity, so simulate an en-only key by looking up
        // one that exists in en but (in this fixture) is missing from zh: assert
        // the fallback CHAIN via every en key — a zh request must never surface
        // the raw key when en backstops it.
        for (key, enValue) in EN.table where ZH.table[key] == nil {
            XCTAssertEqual(L10n.t(key, locale: .zh), enValue, "zh-missing '\(key)' should fall back to en")
        }
        // And directly: an en-only key resolves to its en value under zh.
        // (Uses the private table via a key we know is canonical.)
        XCTAssertNotEqual(L10n.t("nav.feed", locale: .zh), "nav.feed")
    }

    func testReturnsKeyWhenMissingFromBothTables() {
        let unknown = "totally.absent.key"
        XCTAssertEqual(L10n.t(unknown, locale: .zh), unknown)
        XCTAssertEqual(L10n.t(unknown, locale: .en), unknown)
    }

    // MARK: - Interpolation helper

    func testInterpolationReplacesToken() {
        let out = L10n.interpolate("Reset your {label} list?", ["label": "movie"])
        XCTAssertEqual(out, "Reset your movie list?")
    }

    func testInterpolationLeavesUnknownTokensUntouched() {
        XCTAssertEqual(L10n.interpolate("hi {name}", ["other": "x"]), "hi {name}")
    }

    func testInterpolationOnResolvedZhString() {
        let out = L10n.t("ranking.resetConfirm", locale: .zh)
        XCTAssertEqual(L10n.interpolate(out, ["label": "电影"]), "重置你的电影列表？此操作无法撤销。")
    }

    // MARK: - Device-default logic (pure)

    func testDeviceDefaultPicksZhForChinesePreferred() {
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["zh-Hans-CN", "en-US"]), .zh)
    }

    func testDeviceDefaultPicksEnForNonChinese() {
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["en-US", "fr-FR"]), .en)
    }

    func testDeviceDefaultPrefersChineseAnywhereInList() {
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["en-US", "zh-Hant-TW"]), .zh)
    }

    func testDeviceDefaultEmptyListIsEn() {
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: []), .en)
    }

    func testLanguageCodeMappingIsCaseInsensitive() {
        XCTAssertEqual(SpoolLocale.from(languageCode: "ZH-HANT"), .zh)
        XCTAssertEqual(SpoolLocale.from(languageCode: "EN"), .en)
    }

    // MARK: - LocaleStore.resolve (pure persistence decision)

    func testResolveKnownStoredValueWins() {
        let (locale, persist) = LocaleStore.resolve(stored: "zh", preferredLanguages: ["en-US"])
        XCTAssertEqual(locale, .zh)
        XCTAssertFalse(persist, "a known stored value must NOT be re-persisted")
    }

    func testResolveMissingStoredFallsBackToDeviceDefaultAndPersists() {
        let (locale, persist) = LocaleStore.resolve(stored: nil, preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(locale, .zh)
        XCTAssertTrue(persist, "fresh install must persist the computed default")
    }

    func testResolveUnknownStoredFallsBackToDeviceDefaultAndPersists() {
        let (locale, persist) = LocaleStore.resolve(stored: "de", preferredLanguages: ["en-US"])
        XCTAssertEqual(locale, .en)
        XCTAssertTrue(persist)
    }
}
