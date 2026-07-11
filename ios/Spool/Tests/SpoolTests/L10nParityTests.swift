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

    /// The owner's no-em-dash prose rule (2026-07-11) applies to EN as well.
    /// A small set of keys use em dashes as DECORATIVE marquee framing
    /// (`— THE RULES —`, `— vs —`) — an intentional ticket-stub stylistic
    /// choice, not sentence punctuation — and are allowlisted here. Any NEW
    /// sentence em dash in EN fails this test; recast it with a period.
    func testNoEnProseValueContainsEmDash() {
        let decorativeAllowlist: Set<String> = [
            "onb.theRules",
            "onb.headToHead",
            "onb.whoShallWeSeat",
            "onb.findYourPeople",
            "onb.comingThisYear",
            "auth.reserveSeat",
            "stubDetail.friendsWatched",
            "stubDetail.notes",
            "ceremony.vs",
        ]
        let offenders = EN.table
            .filter { !decorativeAllowlist.contains($0.key) }
            .filter { $0.value.rangeOfCharacter(from: emDash) != nil }
            .keys.sorted()
        XCTAssertEqual(
            offenders, [],
            "en prose values with em dashes (recast with a period): \(offenders.joined(separator: ", "))"
        )
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

    // MARK: - Injectable-table fallback tests (real coverage of zh→en→key chain)

    // Fixture tables: only the injectable-table overload can drive missing-key
    // scenarios without violating parity (the real tables are always in parity,
    // so testFallsBackToEnWhenZhMissing iterates zero times against them).

    private let fixtureEn: [String: String] = [
        "fixture.onlyEn": "English only",
        "fixture.both": "Both present",
        "fixture.interpolated": "Hello {name}",
    ]
    private let fixtureZh: [String: String] = [
        // "fixture.onlyEn" deliberately absent → should fall back to en value
        "fixture.both": "两者都有",
        "fixture.interpolated": "你好{name}",
    ]

    func testFallsBackToEnWhenZhMissing() {
        // zh table is missing "fixture.onlyEn" → must return the en value, not the key
        let result = L10n.t("fixture.onlyEn", locale: .zh, zhTable: fixtureZh, enTable: fixtureEn)
        XCTAssertEqual(result, "English only", "zh-missing key must fall back to en value")
    }

    func testReturnsBothPresentZhValue() {
        XCTAssertEqual(
            L10n.t("fixture.both", locale: .zh, zhTable: fixtureZh, enTable: fixtureEn),
            "两者都有"
        )
    }

    func testReturnsBothPresentEnValue() {
        XCTAssertEqual(
            L10n.t("fixture.both", locale: .en, zhTable: fixtureZh, enTable: fixtureEn),
            "Both present"
        )
    }

    func testReturnsBothMissingAsKey() {
        // key absent from BOTH fixture tables → raw key is the result
        let key = "fixture.totally.absent"
        XCTAssertEqual(L10n.t(key, locale: .zh, zhTable: fixtureZh, enTable: fixtureEn), key)
        XCTAssertEqual(L10n.t(key, locale: .en, zhTable: fixtureZh, enTable: fixtureEn), key)
    }

    func testInterpolationOnFixtureFallbackPath() {
        // zh missing "fixture.interpolated" is NOT tested here (it exists in fixtureZh).
        // This tests interpolation after the zh→en fallback: only-en key resolved under zh.
        // "fixture.onlyEn" has no placeholder; use the injectable overload to
        // verify interpolation composes correctly on a plain fallback result.
        let resolved = L10n.t("fixture.onlyEn", locale: .zh, zhTable: fixtureZh, enTable: fixtureEn)
        XCTAssertEqual(L10n.interpolate(resolved, ["unused": "x"]), "English only")
    }

    func testInterpolationOnFixtureZhPath() {
        let resolved = L10n.t("fixture.interpolated", locale: .zh, zhTable: fixtureZh, enTable: fixtureEn)
        XCTAssertEqual(L10n.interpolate(resolved, ["name": "世界"]), "你好世界")
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

    func testDeviceDefaultPicksZhWhenZhIsFirstEntry() {
        // zh first → .zh (first-entry rule)
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["zh-Hans-CN", "en-US"]), .zh)
    }

    func testDeviceDefaultPicksEnWhenEnIsFirstEntry() {
        // en first → .en regardless of other entries
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["en-US", "fr-FR"]), .en)
    }

    func testDeviceDefaultEnPrimaryZhSecondaryIsEn() {
        // en-primary / zh-secondary device must be treated as .en — not flipped
        // to .zh by a zh entry further down the list (first-entry only semantics,
        // matching TMDBService / SuggestionsClient).
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["en-US", "zh-Hant-TW"]), .en)
    }

    func testDeviceDefaultZhHantFirstEntryIsZh() {
        // zh-Hant / zh-HK first entry must resolve as .zh
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["zh-Hant-TW", "en-US"]), .zh)
    }

    func testDeviceDefaultZhHKFirstEntryIsZh() {
        XCTAssertEqual(SpoolLocale.deviceDefault(preferredLanguages: ["zh-HK", "en-US"]), .zh)
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

    // MARK: - LocaleStore.current persistence (injectable UserDefaults)

    func testCurrentWritesDeviceDefaultOnFreshInstall() {
        // A fresh suite has no "spool_locale" key. readCurrent must derive the
        // device default AND write it back so every subsequent read is stable.
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        XCTAssertNil(suite.string(forKey: LocaleStore.storageKey), "suite must start empty")

        let result = LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["zh-Hans"])

        XCTAssertEqual(result, .zh, "device-default for zh-first must be .zh")
        // The write-back is the critical assertion: a dropped defaults.set
        // would leave the suite empty here, making this fail.
        XCTAssertEqual(
            suite.string(forKey: LocaleStore.storageKey), "zh",
            "fresh-install default must be persisted so later reads are stable"
        )
    }

    func testCurrentDoesNotOverwriteExistingStoredValue() {
        // A suite with a pre-existing "en" value must NOT be overwritten even
        // if the device language is zh.
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        suite.set("en", forKey: LocaleStore.storageKey)

        let result = LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["zh-Hans"])

        XCTAssertEqual(result, .en, "stored value wins over device default")
        XCTAssertEqual(suite.string(forKey: LocaleStore.storageKey), "en",
                       "stored value must not be overwritten")
    }
}
