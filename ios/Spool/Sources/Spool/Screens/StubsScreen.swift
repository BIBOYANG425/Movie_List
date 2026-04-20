import SwiftUI

public struct StubsScreen: View {
    public var onOpenDetail: (WatchedDay) -> Void

    @State private var monthDays: [WatchedDay] = []
    @State private var lastStub: StubRow?
    @State private var monthTierCounts: [Tier: Int] = [:]
    @State private var hasSession: Bool = false
    @State private var loading: Bool = true
    /// Total stubs across all time. Drives the `#nnnn` sequence on the
    /// "last watched" card — that card shows the newest stub overall, so
    /// its number should reflect the global count, not this month's count.
    @State private var totalStubsCount: Int = 0
    /// User ID whose data `lastStub`/`totalStubsCount` were fetched for.
    /// When the signed-in user changes (sign out + sign in as someone
    /// else), we clear the cache so the new account's data shows up.
    @State private var cachedForUserID: UUID? = nil
    /// The month currently being viewed. Stored as plain (year, month) ints
    /// rather than a Date so arithmetic never drifts across timezones — the
    /// previous Date-based version mixed `Calendar.current` adds with a
    /// UTC-anchored `firstOfMonth` helper, which skipped or doubled months
    /// whenever the user's local wall clock and UTC disagreed on which
    /// calendar day it was.
    @State private var displayedYM: YearMonth = YearMonth.current()
    /// Currently running reload, tracked so we can cancel it when the user
    /// rapidly taps ‹/› and the older fetch would clobber newer state.
    @State private var loadTask: Task<Void, Never>? = nil

    public init(onOpenDetail: @escaping (WatchedDay) -> Void = { _ in }) {
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "my stubs") {
                    monthStepper
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(countsLine)
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 2)

                        FilmStripCalendar(days: monthDays, totalDays: daysInDisplayedMonth, onTap: onOpenDetail)
                            .padding(.top, 10)

                        SpoolThemeReader { t, _ in
                            Text("tap a day to see the stub ↑")
                                .font(SpoolFonts.script(13))
                                .foregroundStyle(t.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 6)
                        }

                        Text("LAST WATCHED")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 16)

                        lastWatchedCard
                            .rotationEffect(.degrees(-0.5))
                            .padding(.top, 6)

                        // MonthRecapBox intentionally hidden until the recap
                        // experience is real. Component code still exists so
                        // we can flip this back on without a rewrite.
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
                .refreshable {
                    // `refreshable` wants to suspend until the pull-to-refresh
                    // finishes, so await the task we kick off instead of
                    // returning immediately.
                    triggerReload()
                    await loadTask?.value
                }
            }
        }
        .task { triggerReload() }
        // iOS 16-compatible onChange signature (no oldValue/newValue pair).
        .onChange(of: displayedYM) { _ in
            triggerReload()
        }
    }

    /// Cancel any in-flight reload and start a fresh one. The old task's
    /// state mutations are guarded inside `reload()` by a requested-YM
    /// check, so even a late-returning cancelled fetch can't clobber newer
    /// data.
    private func triggerReload() {
        loadTask?.cancel()
        loadTask = Task { await reload() }
    }

    // MARK: header stepper

    /// Month stepper that replaces the old static year/month pills. Both
    /// arrows are always enabled — users can browse any month, including
    /// future ones (empty calendar is fine). Tapping the month label itself
    /// snaps back to the current month so there's always one tap home.
    private var monthStepper: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 6) {
                stepperButton(symbol: "‹", action: { displayedYM = displayedYM.adding(months: -1) }, t: t, enabled: true)
                Button(action: { displayedYM = YearMonth.current() }) {
                    Text(monthLabel)
                        .font(SpoolFonts.mono(11))
                        .tracking(2)
                        .foregroundStyle(t.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(minWidth: 96)
                        .background(
                            Capsule().fill(t.cream2)
                                .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                stepperButton(symbol: "›", action: { displayedYM = displayedYM.adding(months: +1) }, t: t, enabled: true)
            }
        }
    }

    @ViewBuilder
    private func stepperButton(symbol: String, action: @escaping () -> Void,
                               t: SpoolPalette, enabled: Bool) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(SpoolFonts.serif(18))
                .foregroundStyle(enabled ? t.ink : t.inkSoft.opacity(0.4))
                .frame(width: 28, height: 28)
                .background(Circle().fill(t.cream2))
                .overlay(Circle().stroke(enabled ? t.ink : t.inkSoft.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: derived strings

    private var displayedYear: Int { displayedYM.year }
    private var displayedMonthNumber: Int { displayedYM.month }
    private var monthLabel: String { displayedYM.lowercasedLabel() }
    private var daysInDisplayedMonth: Int { displayedYM.dayCount }

    private var countsLine: String {
        // Rewatches were hardcoded to 0 before (`movie_stubs` uses upsert
        // on (user, media, tmdb_id) so reprints don't show as extra rows,
        // and we don't read `journal_entries.is_rewatch` here yet). Ship
        // the accurate WATCHED count alone until we wire real data.
        "\(monthDays.count) WATCHED"
    }

    @ViewBuilder
    private var lastWatchedCard: some View {
        if let stub = lastStub,
           let tier = Tier(rawValue: stub.tier) {
            AdmitStub(
                movie: Movie(
                    id: stub.tmdb_id, title: stub.title,
                    year: Self.parseYear(stub.watched_date),
                    director: "—",
                    seed: Self.stableSeed(stub.tmdb_id),
                    posterUrl: stub.poster_path
                ),
                tier: tier,
                line: stub.stub_line ?? "",
                moods: stub.mood_tags,
                date: Self.admitDate(stub.watched_date),
                // "Last watched" is the newest stub across ALL time, so the
                // sequence number should reflect the global count (total
                // stubs ever), not just this month. `totalStubsCount` is
                // populated by `reload()` via `StubRepository.countStubs`.
                stubNo: Self.stubNumber(totalStubsCount),
                compact: true
            )
        } else if loading {
            Color.clear.frame(height: 80)
        } else {
            SpoolThemeReader { t, _ in
                Text(hasSession
                     ? "nothing here yet · rank something to start your stub collection."
                     : "sign in to see your real stubs.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    // MARK: loader

    private func reload() async {
        loading = true
        defer { loading = false }

        let userID = await SpoolClient.currentUserID()
        hasSession = userID != nil
        // Capture the requested month up front so the comparison below
        // rejects stale responses even if the user tapped ‹/› mid-flight.
        let requested = displayedYM
        NSLog("[StubsScreen] reload: hasSession=\(hasSession) year=\(requested.year) month=\(requested.month)")

        guard let userID else {
            if !Task.isCancelled, requested == displayedYM {
                // Only populate the April fixture when the user is actually
                // browsing April 2026 — otherwise a preview-mode user
                // scrolling to May/March sees fake "April watched" days
                // sprinkled into the wrong month. Filter instead of
                // unconditionally assigning the whole fixture.
                if requested == Self.aprilFixtureYM {
                    monthDays = SpoolData.aprilWatched
                } else {
                    monthDays = []
                }
                monthTierCounts = Self.bucketTiers(monthDays)
                lastStub = nil
                totalStubsCount = 0
                cachedForUserID = nil
            }
            return
        }

        // Account switch → wipe the cache so the new user sees their
        // own "last watched" card, not the previous account's.
        if cachedForUserID != userID {
            lastStub = nil
            totalStubsCount = 0
            cachedForUserID = userID
        }

        do {
            let stubs = try await StubRepository.shared.getStubsForMonth(
                userID: userID, year: requested.year, month: requested.month
            )
            if Task.isCancelled || requested != displayedYM {
                NSLog("[StubsScreen] month stubs stale — dropping")
                return
            }
            NSLog("[StubsScreen] month stubs ok: \(stubs.count)")
            monthDays = stubs.compactMap(Self.rowToDay)
            monthTierCounts = Self.bucketTiers(monthDays)
        } catch {
            if Task.isCancelled { return }
            NSLog("[StubsScreen] getStubsForMonth FAIL: \(error)")
            monthDays = []
            monthTierCounts = [:]
        }

        // "Last watched" + total count are month-independent — only fetch
        // them on the first load of a session to avoid refetching when the
        // user pages through months.
        if lastStub == nil {
            do {
                async let recent = StubRepository.shared.getAllStubs(userID: userID, limit: 1)
                async let total = StubRepository.shared.countStubs(userID: userID)
                let (recentRows, totalCount) = try await (recent, total)
                if Task.isCancelled { return }
                NSLog("[StubsScreen] last stub ok: \(recentRows.first?.title ?? "nil") total=\(totalCount)")
                lastStub = recentRows.first
                totalStubsCount = totalCount
            } catch {
                if Task.isCancelled { return }
                NSLog("[StubsScreen] getAllStubs/countStubs FAIL: \(error)")
            }
        }
    }

    // MARK: converters

    private static func rowToDay(_ row: StubRow) -> WatchedDay? {
        guard let tier = Tier(rawValue: row.tier) else { return nil }
        // watched_date is "yyyy-MM-dd"; split into year / month / day so the
        // detail sheet can format the full "APR · 18 · 2026" string instead
        // of the hardcoded "APR · 18 · 2026" default.
        let parts = row.watched_date.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return WatchedDay(day: day, tier: tier, title: row.title, year: year, month: month)
    }

    private static func bucketTiers(_ days: [WatchedDay]) -> [Tier: Int] {
        var out: [Tier: Int] = [:]
        for day in days { out[day.tier, default: 0] += 1 }
        return out
    }

    private static func parseYear(_ dateString: String) -> Int {
        let parts = dateString.split(separator: "-")
        return parts.first.flatMap { Int($0) } ?? Calendar.current.component(.year, from: Date())
    }

    private static func stableSeed(_ id: String) -> Int {
        // Deterministic 0-9 seed across process launches. `String.hashValue`
        // is process-seeded, so relying on it would re-shuffle poster
        // palettes every cold launch. Parse TMDB-ish ids ("tmdb_12345" →
        // 12345) when we can; fall back to a plain djb2 digest otherwise.
        if let digits = id.split(separator: "_").last.flatMap({ Int($0) }) {
            return abs(digits) % 10
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 10)
    }

    private static func admitDate(_ dateString: String) -> String {
        let parts = dateString.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateString.uppercased() }
        let months = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let m = month >= 1 && month <= 12 ? months[month] : "—"
        return "\(m) · \(String(format: "%02d", day)) · \(parts[0])"
    }

    /// The year/month the `SpoolData.aprilWatched` fixture represents.
    /// Keep in sync with the fixture content in `SpoolData.swift`. The
    /// preview-mode guard compares against this before surfacing fixture
    /// days so browsing past/future months doesn't show April tiles.
    private static let aprilFixtureYM = YearMonth(year: 2026, month: 4)

    private static func stubNumber(_ count: Int) -> String {
        "#" + String(format: "%04d", max(count, 0))
    }
}

struct FilmStripCalendar: View {
    let days: [WatchedDay]
    /// Number of day cells to render — varies by month (28-31). Default is
    /// 31 to preserve old call sites.
    let totalDays: Int
    let onTap: (WatchedDay) -> Void

    init(days: [WatchedDay], totalDays: Int = 31, onTap: @escaping (WatchedDay) -> Void) {
        self.days = days
        self.totalDays = totalDays
        self.onTap = onTap
    }

    private var byDay: [Int: WatchedDay] {
        // Two stubs watched on the same day crash `uniqueKeysWithValues`
        // (see StubsScreen crash 2026-04-20). Collapse collisions by keeping
        // the higher-tier one — S beats A beats B, etc. — so the calendar
        // cell reflects the best-rated watch of the day.
        Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { lhs, rhs in
            Self.tierRank(lhs.tier) >= Self.tierRank(rhs.tier) ? lhs : rhs
        })
    }

    /// Higher number = better tier. Mirrors `tasteService.TIER_NUMERIC` so
    /// "best tier wins" is consistent across the app.
    private static func tierRank(_ tier: Tier) -> Int {
        switch tier {
        case .S: return 5
        case .A: return 4
        case .B: return 3
        case .C: return 2
        case .D: return 1
        }
    }

    var body: some View {
        SpoolThemeReader { t, mode in
            VStack(spacing: 4) {
                SprocketRow()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                    ForEach(1...totalDays, id: \.self) { day in
                        let w = byDay[day]
                        Button { if let w = w { onTap(w) } } label: {
                            VStack {
                                Text("\(day)")
                                    .font(SpoolFonts.mono(7))
                                    .foregroundStyle(t.cream.opacity(0.6))
                                Spacer(minLength: 0)
                                if let w = w {
                                    Text(w.tier.rawValue)
                                        .font(SpoolFonts.serif(9))
                                        .foregroundStyle(t.cream)
                                        .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(2.0/3.0, contentMode: .fit)
                            .background((w != nil) ? tierColor(w!.tier, mode: mode) : Color(hex: 0x2A2A2A))
                            .cornerRadius(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(w == nil)
                    }
                }
                SprocketRow()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(t.ink)
            .cornerRadius(6)
        }
    }
}

struct SprocketRow: View {
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack {
                ForEach(0..<14, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(t.cream)
                        .frame(width: 6, height: 6)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

struct MonthRecapBox: View {
    let tierCounts: [Tier: Int]
    let monthLabel: String

    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(monthLabel), in letters.")
                    .font(SpoolFonts.serif(20))
                    .foregroundStyle(t.ink)
                Text(recapLine)
                    .font(SpoolFonts.script(20))
                    .foregroundStyle(t.inkSoft)
                    .padding(.top, 4)

                HStack(spacing: 10) {
                    ForEach(Tier.allCases, id: \.self) { tier in
                        VStack(spacing: -4) {
                            TierStamp(tier: tier, size: 34)
                            Text("× \(tierCounts[tier] ?? 0)")
                                .font(SpoolFonts.mono(11))
                                .foregroundStyle(t.inkSoft)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 12)

                HStack {
                    Spacer()
                    SpoolPill("🎞 make \(monthLabel) recap", filled: true, size: .sm)
                    Spacer()
                }
                .padding(.top, 10)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.ink)
            )
        }
    }

    private var recapLine: String {
        let total = tierCounts.values.reduce(0, +)
        let sCount = tierCounts[.S] ?? 0
        if total == 0 { return "nothing yet." }
        if sCount >= 3 { return "a pretty stacked month." }
        if total < 3 { return "a slow month." }
        return "a solid month."
    }
}

// MARK: - YearMonth

/// Plain (year, month) value used by the stub calendar stepper. Using
/// integers rather than Date sidesteps timezone pitfalls — month arithmetic
/// on a Date anchored to one timezone and added with Calendar.current
/// (another timezone) would occasionally skip or repeat a month near
/// midnight UTC. Integers just work.
public struct YearMonth: Hashable, Sendable {
    public let year: Int
    public let month: Int   // 1...12

    public init(year: Int, month: Int) {
        // Normalize by rolling overflow/underflow into year. Callers should
        // already pass 1...12 but this keeps bad inputs from exploding.
        let zeroBased = month - 1
        let yearDelta = Int((Double(zeroBased) / 12.0).rounded(.down))
        let normalizedMonth = zeroBased - yearDelta * 12 + 1
        self.year = year + yearDelta
        self.month = normalizedMonth
    }

    /// Current wall-clock year/month in the user's local calendar. This is
    /// the one place we consult `Calendar.current`, deliberately — "current
    /// month" means "what month is it for the user right now."
    public static func current(now: Date = Date()) -> YearMonth {
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        return YearMonth(year: comps.year ?? 2000, month: comps.month ?? 1)
    }

    /// Shift by `delta` calendar months. Wraps year correctly at Jan/Dec
    /// boundaries in either direction.
    public func adding(months delta: Int) -> YearMonth {
        YearMonth(year: year, month: month + delta)
    }

    /// Number of days in this month, accounting for leap years via the
    /// gregorian calendar.
    public var dayCount: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let comps = DateComponents(year: year, month: month, day: 1)
        guard let date = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: date) else {
            return 30
        }
        return range.count
    }

    /// "april 2026" — used in the header stepper pill.
    public func lowercasedLabel() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        let comps = DateComponents(year: year, month: month, day: 1)
        let date = calendar.date(from: comps) ?? Date()
        return f.string(from: date).lowercased()
    }
}

#Preview {
    StubsScreen(onOpenDetail: { _ in }).spoolMode(.paper)
}
