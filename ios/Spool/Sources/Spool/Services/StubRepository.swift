import Foundation
import Supabase

/// Reads against `movie_stubs` and the ranking tables that Profile / Stubs
/// tabs need. Complements `RankingRepository.insertStub` (the write side)
/// and `RankingRepository.getTierItems` (the S-tier top-4 helper).
///
///  - `getStubsForMonth(userID:year:month:)` — Stubs tab month grid
///  - `getAllStubs(userID:limit:)` — Profile "RECENT STUBS" row + Stubs list
///  - `getTopTier(userID:tier:limit:)` — Profile "MY TOP 4" row
///  - `countStubs(userID:)` — Profile stats count
///
/// Shape of `StubRow` is defined in `RankingRepository.swift` alongside
/// `StubInsert` — no duplicate types.
///
/// Header last reviewed: 2026-04-19
public actor StubRepository {

    public static let shared = StubRepository()

    public enum RepoError: Error {
        case notConfigured
    }

    // MARK: reads

    /// All stubs watched in `year`-`month` for `userID`. Returns `[]` on any
    /// error so the calendar can render an empty heatmap — a network hiccup
    /// shouldn't block the month grid.
    public func getStubsForMonth(userID: UUID, year: Int, month: Int) async throws -> [StubRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        let (start, end) = Self.monthBounds(year: year, month: month)

        let rows: [StubRow] = try await client
            .from("movie_stubs")
            .select()
            .eq("user_id", value: userID.uuidString)
            .gte("watched_date", value: start)
            .lte("watched_date", value: end)
            .order("watched_date", ascending: true)
            .execute()
            .value
        return rows
    }

    /// Most-recent stubs for `userID`. Used by Profile recent row (limit 5)
    /// and the Stubs tab "all" view.
    public func getAllStubs(userID: UUID, limit: Int = 40) async throws -> [StubRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let rows: [StubRow] = try await client
            .from("movie_stubs")
            .select()
            .eq("user_id", value: userID.uuidString)
            .order("watched_date", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    /// Top items in `tier` for `userID`, ordered by rank_position ascending.
    /// Powers Profile "MY TOP 4" (tier = .S, limit = 4).
    public func getTopTier(userID: UUID, tier: Tier, limit: Int = 4) async throws -> [RankingRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let rows: [RankingRow] = try await client
            .from("user_rankings")
            .select()
            .eq("user_id", value: userID.uuidString)
            .eq("tier", value: tier.rawValue)
            .order("rank_position", ascending: true)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    /// Total stubs count for the Profile header. `HEAD` request with a
    /// count-only response — avoids pulling rows across the wire.
    public func countStubs(userID: UUID) async throws -> Int {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let response = try await client
            .from("movie_stubs")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userID.uuidString)
            .execute()
        return response.count ?? 0
    }

    // MARK: private

    /// Returns ISO yyyy-MM-dd strings for the first and last day of `month`.
    /// Uses a gregorian calendar in UTC to match what Postgres stores.
    private static func monthBounds(year: Int, month: Int) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        var startComponents = DateComponents()
        startComponents.year = year
        startComponents.month = month
        startComponents.day = 1
        let startDate = calendar.date(from: startComponents) ?? Date()
        let range = calendar.range(of: .day, in: .month, for: startDate)
        let lastDay = range?.upperBound.advanced(by: -1) ?? 28

        let mm = String(format: "%02d", month)
        let start = String(format: "%04d-%@-01", year, mm)
        let end = String(format: "%04d-%@-%02d", year, mm, lastDay)
        return (start, end)
    }
}
