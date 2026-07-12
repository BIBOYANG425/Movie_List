import XCTest
@testable import Spool

/// State-machine spec for `DigestPrefsModel` (the "daily reel" section of the Text
/// Chris sheet) plus the pure hour-label formatting. Every transition (load,
/// optimistic edit, save success/failure/revert) is driven with injected stub
/// closures. No SwiftUI, no Supabase, no network.
@MainActor
final class DigestPrefsModelTests: XCTestCase {

    /// Reference sink so the escaping `onError` closure can record without
    /// capturing a `var`.
    final class Sink { var errors = 0; func bump() { errors += 1 } }

    /// Reference sink recording every (cadence, hour) pair passed to `saveFn`.
    final class SaveLog { var calls: [(DigestCadence, Int)] = []; func record(_ c: DigestCadence, _ h: Int) { calls.append((c, h)) } }

    private func makeModel(
        load: @escaping () async -> DigestPreferences? = { nil },
        save: @escaping (DigestCadence, Int) async throws -> Void = { _, _ in },
        sink: Sink
    ) -> DigestPrefsModel {
        DigestPrefsModel(loadFn: load, saveFn: save, onError: { sink.bump() })
    }

    // MARK: - load()

    func testStartsLoading() {
        let m = makeModel(sink: Sink())
        XCTAssertEqual(m.phase, .loading)
    }

    func testLoadMissingRowUsesDefaults() async {
        let m = makeModel(load: { nil }, sink: Sink())
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.prefs, .defaults)
        XCTAssertEqual(m.prefs.cadence, .daily)
        XCTAssertEqual(m.prefs.hour, 9)
    }

    func testLoadExistingRowPopulatesPrefs() async {
        let saved = DigestPreferences(cadence: .weekly, hour: 7, timezone: "America/New_York")
        let m = makeModel(load: { saved }, sink: Sink())
        await m.load()
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.prefs, saved)
    }

    // MARK: - setCadence()

    func testSetCadencePersistsAndAdvancesSnapshot() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()
        await m.setCadence(.weekly)
        XCTAssertEqual(m.prefs.cadence, .weekly)
        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(log.calls[0].0, .weekly)
        XCTAssertEqual(log.calls[0].1, 9, "hour carries through unchanged")
    }

    func testSetCadenceSameValueIsNoOp() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()  // defaults → .daily
        await m.setCadence(.daily)
        XCTAssertTrue(log.calls.isEmpty, "re-selecting the current cadence must not write")
    }

    func testSetCadenceOffStillPersists() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()
        await m.setCadence(.off)
        XCTAssertEqual(m.prefs.cadence, .off)
        XCTAssertEqual(log.calls.count, 1)
    }

    // MARK: - setHour()

    func testSetHourPersistsClampedValue() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()
        await m.setHour(18)
        XCTAssertEqual(m.prefs.hour, 18)
        XCTAssertEqual(log.calls.last?.1, 18)
    }

    func testSetHourClampsOutOfRange() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()
        await m.setHour(99)
        XCTAssertEqual(m.prefs.hour, 23, "hour clamps to the 0...23 CHECK range")
        XCTAssertEqual(log.calls.last?.1, 23)
    }

    func testSetHourSameValueIsNoOp() async {
        let log = SaveLog()
        let m = makeModel(load: { .defaults }, save: { c, h in log.record(c, h) }, sink: Sink())
        await m.load()  // hour 9
        await m.setHour(9)
        XCTAssertTrue(log.calls.isEmpty)
    }

    // MARK: - save failure → revert + onError

    func testSaveFailureRevertsCadenceAndReportsError() async {
        struct Boom: Error {}
        let sink = Sink()
        let m = makeModel(load: { .defaults }, save: { _, _ in throw Boom() }, sink: sink)
        await m.load()
        await m.setCadence(.weekly)
        XCTAssertEqual(m.prefs.cadence, .daily, "a failed save reverts to the last saved cadence")
        XCTAssertEqual(sink.errors, 1, "the failure is reported once")
    }

    func testSaveFailureRevertsHour() async {
        struct Boom: Error {}
        let sink = Sink()
        let m = makeModel(load: { .defaults }, save: { _, _ in throw Boom() }, sink: sink)
        await m.load()
        await m.setHour(20)
        XCTAssertEqual(m.prefs.hour, 9, "a failed hour save reverts")
        XCTAssertEqual(sink.errors, 1)
    }

    func testCancellationRevertsWithoutError() async {
        let sink = Sink()
        let m = makeModel(load: { .defaults }, save: { _, _ in throw CancellationError() }, sink: sink)
        await m.load()
        await m.setCadence(.off)
        XCTAssertEqual(m.prefs.cadence, .daily, "cancellation reverts")
        XCTAssertEqual(sink.errors, 0, "cancellation is not an error toast")
    }

    func testSecondEditRevertsToFirstSaved() async {
        // A successful weekly save, then a failed off save, must revert to weekly
        // (the last SAVED snapshot), not all the way to the original daily.
        var failNext = false
        let sink = Sink()
        let m = makeModel(
            load: { .defaults },
            save: { _, _ in if failNext { throw NSError(domain: "x", code: 1) } },
            sink: sink
        )
        await m.load()
        await m.setCadence(.weekly)   // saves ok
        XCTAssertEqual(m.prefs.cadence, .weekly)
        failNext = true
        await m.setCadence(.off)      // fails
        XCTAssertEqual(m.prefs.cadence, .weekly, "revert target is the last saved value")
        XCTAssertEqual(sink.errors, 1)
    }

    // MARK: - pure hour-label formatting

    func testClockLabelMorning() {
        XCTAssertEqual(DigestHour.clockLabel(9), "9am")
    }

    func testClockLabelMidnightIs12am() {
        XCTAssertEqual(DigestHour.clockLabel(0), "12am")
    }

    func testClockLabelNoonIs12pm() {
        XCTAssertEqual(DigestHour.clockLabel(12), "12pm")
    }

    func testClockLabelEvening() {
        XCTAssertEqual(DigestHour.clockLabel(17), "5pm")
    }

    func testClockLabelClampsOutOfRange() {
        XCTAssertEqual(DigestHour.clockLabel(25), "11pm", "out-of-range clamps before formatting")
        XCTAssertEqual(DigestHour.clockLabel(-3), "12am")
    }

    func testAllHoursCoversFullDay() {
        XCTAssertEqual(DigestHour.all, Array(0...23))
    }

    func testHourArrivalLabelComposesFrame() {
        XCTAssertEqual(TextChrisSheet.hourArrivalLabel(9), "arrives around 9am")
    }

    func testHourArrivalLabelZh() {
        XCTAssertEqual(
            L10n.interpolate(L10n.t("digest.arrivesAround", locale: .zh), ["hour": DigestHour.clockLabel(9)]),
            "大约 9am 送到"
        )
    }

    // MARK: - DigestPreferences value + cadence mapping

    func testCadenceRawValuesMatchDBContract() {
        XCTAssertEqual(DigestCadence.daily.rawValue, "daily")
        XCTAssertEqual(DigestCadence.weekly.rawValue, "weekly")
        XCTAssertEqual(DigestCadence.off.rawValue, "off")
    }

    func testDigestPreferencesClampsHourOnInit() {
        let p = DigestPreferences(cadence: .daily, hour: 30, timezone: "UTC")
        XCTAssertEqual(p.hour, 23)
    }
}
