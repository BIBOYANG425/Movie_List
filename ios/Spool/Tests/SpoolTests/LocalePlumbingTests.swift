import XCTest
@testable import Spool

/// Task 2 spec: both content clients re-source their TMDB `language=` param from
/// `LocaleStore.current` (single source of truth) instead of each re-reading
/// `Locale.preferredLanguages.first`. This pins:
///
///  - the pure mapping `.zh → "zh-CN"`, `.en → "en-US"` for BOTH clients, and
///  - the behavior pin: a device-zh user's TMDB locale is UNCHANGED by default
///    (the store defaults to the device first-entry, so `.zh` maps to `zh-CN`),
///    while an en-device user who toggles to zh switches content locale on the
///    NEXT fetch (a stored `.zh` overrides the `.en` device default).
///
/// The mapping is tested through the pure `locale(for:)` overloads so no
/// `UserDefaults` / `Locale.preferredLanguages` read is required.
final class LocalePlumbingTests: XCTestCase {

    // MARK: - Pure mapping: TMDBService

    func testTMDBLocaleMapsZhToZhCN() {
        XCTAssertEqual(TMDBService.locale(for: .zh), "zh-CN")
    }

    func testTMDBLocaleMapsEnToEnUS() {
        XCTAssertEqual(TMDBService.locale(for: .en), "en-US")
    }

    // MARK: - Pure mapping: SuggestionsClient

    func testSuggestionsLocaleMapsZhToZhCN() {
        XCTAssertEqual(SuggestionsClient.locale(for: .zh), "zh-CN")
    }

    func testSuggestionsLocaleMapsEnToEnUS() {
        XCTAssertEqual(SuggestionsClient.locale(for: .en), "en-US")
    }

    // MARK: - Both clients agree (single mapping, two entry points)

    func testBothClientsMapIdentically() {
        XCTAssertEqual(TMDBService.locale(for: .zh), SuggestionsClient.locale(for: .zh))
        XCTAssertEqual(TMDBService.locale(for: .en), SuggestionsClient.locale(for: .en))
    }

    // MARK: - Behavior pin (via the store, injectable UserDefaults suite)

    /// A device-zh user with no explicit toggle: the store defaults to the device
    /// first-entry (`.zh`), so BOTH clients resolve `zh-CN` — UNCHANGED from the
    /// pre-Task-2 device-read behavior.
    func testDeviceZhUserDefaultsToZhCN() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Fresh suite + zh-first device → store resolves .zh and persists it.
        let resolved = LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["zh-Hans-CN", "en-US"])
        XCTAssertEqual(resolved, .zh)
        XCTAssertEqual(TMDBService.locale(for: resolved), "zh-CN")
        XCTAssertEqual(SuggestionsClient.locale(for: resolved), "zh-CN")
    }

    /// An en-device user who toggles to zh: the stored `.zh` overrides the `.en`
    /// device default, so the NEXT fetch's content locale is `zh-CN`.
    func testEnDeviceUserTogglingZhSwitchesContentLocale() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Simulate the Settings toggle writing "zh" (same raw-string contract the
        // @AppStorage picker uses) into the slot on an en-primary device.
        suite.set(SpoolLocale.zh.rawValue, forKey: LocaleStore.storageKey)

        let resolved = LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["en-US"])
        XCTAssertEqual(resolved, .zh, "stored toggle wins over en device default")
        XCTAssertEqual(TMDBService.locale(for: resolved), "zh-CN")
        XCTAssertEqual(SuggestionsClient.locale(for: resolved), "zh-CN")
    }

    /// An en-device user who has NOT toggled: content locale stays `en-US`.
    func testEnDeviceUserDefaultsToEnUS() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let resolved = LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["en-US", "zh-Hant-TW"])
        XCTAssertEqual(resolved, .en, "en-primary device stays .en (first-entry rule)")
        XCTAssertEqual(TMDBService.locale(for: resolved), "en-US")
        XCTAssertEqual(SuggestionsClient.locale(for: resolved), "en-US")
    }

    // MARK: - Toggle persistence round-trip (Settings picker contract)

    /// Writing a raw locale string into the slot (what the @AppStorage picker does)
    /// then reading it back through the store's pure resolver returns the same
    /// locale and does NOT re-persist — a round-trip through the storage contract.
    func testTogglePersistenceRoundTrip() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!

        // User toggles EN → 中文.
        suite.set(SpoolLocale.zh.rawValue, forKey: LocaleStore.storageKey)
        XCTAssertEqual(LocaleStore.readCurrent(defaults: suite, preferredLanguages: ["en-US"]), .zh)

        // User toggles back 中文 → EN.
        suite.set(SpoolLocale.en.rawValue, forKey: LocaleStore.storageKey)
        let (locale, persist) = LocaleStore.resolve(
            stored: suite.string(forKey: LocaleStore.storageKey),
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(locale, .en)
        XCTAssertFalse(persist, "an explicit stored toggle is never re-persisted")
    }

    // MARK: - Settings language keys exist (both tables, faithful zh)

    func testSettingsLanguageKeysPresent() {
        XCTAssertEqual(L10n.t("settings.language", locale: .en), "language")
        XCTAssertEqual(L10n.t("settings.language", locale: .zh), "语言")
        XCTAssertEqual(L10n.t("settings.languageEnglish", locale: .en), "EN")
        XCTAssertEqual(L10n.t("settings.languageEnglish", locale: .zh), "EN")
        XCTAssertEqual(L10n.t("settings.languageChinese", locale: .en), "中文")
        XCTAssertEqual(L10n.t("settings.languageChinese", locale: .zh), "中文")
    }
}
