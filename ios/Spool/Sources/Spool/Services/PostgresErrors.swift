import Foundation

/// Shared Postgres error classification for supabase-swift call sites.
/// Extracted from FollowRepository's proven private check so every
/// repository detects unique violations the same way.
public enum PostgresErrors {
    /// SQLSTATE 23505 (unique_violation), surfaced through supabase-swift
    /// error descriptions in slightly different shapes per version.
    /// Matches the exact three patterns FollowRepository shipped with so
    /// its behavior is unchanged by the extraction.
    public static func isUniqueViolation(_ error: Error) -> Bool {
        let s = String(describing: error)
        return s.contains("23505")
            || s.lowercased().contains("duplicate key")
            || s.lowercased().contains("unique constraint")
    }
}
