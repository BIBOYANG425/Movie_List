import Foundation
import Supabase

/// The notification-bell contract: badge count, latest-30 fetch with actor
/// profiles batch-joined, and bulk mark-read. Swift mirror of web's
/// `services/notificationService.ts` + the id-picking in
/// `components/social/NotificationBell.tsx` (branch
/// `fix/c1-feed-web-blocking`):
///
///  - `unreadCount()` — HEAD count of `is_read = false` (web
///    `getUnreadCount`, L68–77); the 15 s badge poll calls this
///  - `fetchLatest(limit: 30)` — newest first, actor profiles joined in one
///    batch (web `getNotifications`, L25–57); avatar comes from
///    `avatar_path` ONLY — the item carries the raw storage path, no
///    URL building, no `avatar_url` fallback chain (contract + web L52)
///  - `markRead(ids:)` — bulk `is_read = true` on EXACTLY the passed ids
///    (web `markNotificationsRead`, L60–65); callers pass
///    `NotificationAssembler.unreadIDs(from:)` — the fetched AND unread
///    ids, nothing else (bell L83)
///
/// The `new_follower` WRITE is NOT here on purpose: it already lives in
/// `FollowRepository.follow` (C0) — a second writer would double-notify.
/// The `notifications` table exists pre-#32, but this surface ships with
/// the C1 feed PR as one unit; all row logic is pure
/// (`NotificationAssembler`, NotificationTests) and the actor only moves
/// bytes. Follows the repository pattern: actor + `SpoolClient.shared`
/// guard, `[NotificationRepository]`-prefixed logs, reads fail soft to
/// empty without a session, write errors rethrow to callers.

// MARK: - Kinds

/// The six contract notification types. Unknown raw values (a newer client
/// wrote a type this build doesn't know) render with the `new_follower`
/// fallback — never drop a row over its type.
public enum NotificationKind: String, CaseIterable, Sendable {
    case newFollower = "new_follower"
    case reviewLike = "review_like"
    case listLike = "list_like"
    case badgeUnlock = "badge_unlock"
    case rankingComment = "ranking_comment"
    case journalTag = "journal_tag"

    /// Contract fallback: unknown → `.newFollower`.
    public static func orFallback(_ raw: String) -> NotificationKind {
        NotificationKind(rawValue: raw) ?? .newFollower
    }

    /// SF Symbol the bell renders for this kind. Lives here (not in the view) so
    /// the kind → icon mapping is unit-testable without SwiftUI. Total over the
    /// six cases — `badge_unlock` renders `rosette` (the C7 achievement bell row;
    /// the RPC writes these rows server-side, so the bell MUST render them, not
    /// filter them). `NotificationBellView` delegates to this.
    public var sfSymbol: String {
        switch self {
        case .newFollower:    return "person.badge.plus"
        case .reviewLike:     return "heart.fill"
        case .listLike:       return "list.star"
        case .badgeUnlock:    return "rosette"
        case .rankingComment: return "bubble.left.fill"
        case .journalTag:     return "tag.fill"
        }
    }
}

// MARK: - Wire rows

/// One `notifications` row exactly as the contract states it:
/// `{id, user_id, type, title, body?, actor_id?, reference_id?, is_read,
/// created_at}`. snake_case = wire format; `created_at` stays a String
/// (file-wide convention — no parse/reformat drift). `type` stays the raw
/// string so unknown kinds survive round trips.
public struct NotificationRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let type: String
    public let title: String
    public let body: String?
    public let actor_id: UUID?
    public let reference_id: String?
    public let is_read: Bool
    public let created_at: String

    public init(id: UUID, user_id: UUID, type: String, title: String,
                body: String?, actor_id: UUID?, reference_id: String?,
                is_read: Bool, created_at: String) {
        self.id = id
        self.user_id = user_id
        self.type = type
        self.title = title
        self.body = body
        self.actor_id = actor_id
        self.reference_id = reference_id
        self.is_read = is_read
        self.created_at = created_at
    }
}

/// One actor profile row as the batch join selects it — EXACTLY
/// `id, username, avatar_path` (web L38). Deliberately not
/// `ProfileRepository.ProfileRow`: this row has no `avatar_url` member at
/// all, so the feed's avatar fallback chain CANNOT sneak in here.
public struct NotificationActorRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let username: String?
    public let avatar_path: String?

    public init(id: UUID, username: String?, avatar_path: String?) {
        self.id = id
        self.username = username
        self.avatar_path = avatar_path
    }
}

// MARK: - DTO

/// One rendered bell entry: the contract row fields plus the joined actor's
/// `username` and raw `avatar_path` (storage path — the UI layer builds the
/// public URL, same split web makes at `notificationService.ts` L52).
public struct NotificationItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let userID: UUID
    /// Raw wire type — kept verbatim so unknown kinds stay inspectable.
    public let type: String
    public let title: String
    public let body: String?
    public let actorID: UUID?
    public let referenceID: String?
    public let isRead: Bool
    public let createdAt: String
    public let actorUsername: String?
    public let actorAvatarPath: String?

    /// What the UI renders as — unknown types fall back to `.newFollower`.
    public var kind: NotificationKind { .orFallback(type) }

    public init(id: UUID, userID: UUID, type: String, title: String,
                body: String?, actorID: UUID?, referenceID: String?,
                isRead: Bool, createdAt: String,
                actorUsername: String?, actorAvatarPath: String?) {
        self.id = id
        self.userID = userID
        self.type = type
        self.title = title
        self.body = body
        self.actorID = actorID
        self.referenceID = referenceID
        self.isRead = isRead
        self.createdAt = createdAt
        self.actorUsername = actorUsername
        self.actorAvatarPath = actorAvatarPath
    }
}

// MARK: - Pure assembly

/// Pure row logic behind `NotificationRepository` — extracted so the join
/// and the mark-read id-picking are testable without a network
/// (NotificationTests).
public enum NotificationAssembler {

    /// Unique actor ids to batch-join, first-seen order, nils skipped —
    /// web's `[...new Set(data.filter(n => n.actor_id).map(n => n.actor_id))]`
    /// (L34).
    public static func actorIDs(from rows: [NotificationRow]) -> [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for row in rows {
            guard let actor = row.actor_id, seen.insert(actor).inserted else { continue }
            ids.append(actor)
        }
        return ids
    }

    /// Join notification rows with their actors' profiles, preserving row
    /// order (newest first from the query). A missing profile (deleted
    /// user, RLS) leaves the actor fields nil — the row still renders.
    public static func items(from rows: [NotificationRow],
                             actors: [NotificationActorRow]) -> [NotificationItem] {
        let byID = Dictionary(actors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            let actor = row.actor_id.flatMap { byID[$0] }
            return NotificationItem(id: row.id,
                                    userID: row.user_id,
                                    type: row.type,
                                    title: row.title,
                                    body: row.body,
                                    actorID: row.actor_id,
                                    referenceID: row.reference_id,
                                    isRead: row.is_read,
                                    createdAt: row.created_at,
                                    actorUsername: actor?.username,
                                    actorAvatarPath: actor?.avatar_path)
        }
    }

    /// The ids to bulk mark-read after a fetch: EXACTLY the fetched AND
    /// unread ones, order preserved — web bell's
    /// `data.filter((n) => !n.isRead).map((n) => n.id)` (NotificationBell
    /// L83). Never the whole inbox, never already-read rows.
    public static func unreadIDs(from items: [NotificationItem]) -> [UUID] {
        items.filter { !$0.isRead }.map(\.id)
    }
}

// MARK: - Repository

public actor NotificationRepository {

    public static let shared = NotificationRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    /// Badge count: HEAD request, exact count of the user's `is_read =
    /// false` rows — no row bytes cross the wire (web `getUnreadCount`,
    /// L68–77). No session → 0 (nothing to badge), read errors rethrow
    /// after logging.
    public func unreadCount() async throws -> Int {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else {
            NSLog("[NotificationRepository] unreadCount: no session — 0")
            return 0
        }

        do {
            let response = try await client
                .from("notifications")
                .select("id", head: true, count: .exact)
                .eq("user_id", value: me.uuidString.lowercased())
                .eq("is_read", value: false)
                .execute()
            return response.count ?? 0
        } catch {
            NSLog("[NotificationRepository] unreadCount failed: \(error)")
            throw error
        }
    }

    /// The newest `limit` notifications (default 30 — the contract page),
    /// actor profiles joined in ONE batch select of
    /// `id, username, avatar_path` (web `getNotifications`, L25–57).
    /// No session → empty. Marking read is the CALLER's second step:
    /// `markRead(ids: NotificationAssembler.unreadIDs(from: items))`.
    public func fetchLatest(limit: Int = 30) async throws -> [NotificationItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else {
            NSLog("[NotificationRepository] fetchLatest: no session — empty")
            return []
        }

        do {
            let rows: [NotificationRow] = try await client
                .from("notifications")
                .select("id, user_id, type, title, body, actor_id, reference_id, is_read, created_at")
                .eq("user_id", value: me.uuidString.lowercased())
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value

            let actorIDs = NotificationAssembler.actorIDs(from: rows)
            var actors: [NotificationActorRow] = []
            if !actorIDs.isEmpty {
                actors = try await client
                    .from("profiles")
                    .select("id, username, avatar_path")
                    .in("id", values: actorIDs.map { $0.uuidString.lowercased() })
                    .execute()
                    .value
            }
            return NotificationAssembler.items(from: rows, actors: actors)
        } catch {
            NSLog("[NotificationRepository] fetchLatest failed: \(error)")
            throw error
        }
    }

    /// Bulk `is_read = true` on EXACTLY the passed ids (web
    /// `markNotificationsRead`, L60–65 — an `.in('id', ids)` update; RLS
    /// scopes it to own rows, same as web sends no user filter). Empty ids
    /// = no-op without I/O. Write errors rethrow.
    public func markRead(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        do {
            _ = try await client
                .from("notifications")
                .update(MarkReadPayload(is_read: true))
                .in("id", values: ids.map { $0.uuidString.lowercased() })
                .execute()
        } catch {
            NSLog("[NotificationRepository] markRead(\(ids.count) ids) failed: \(error)")
            throw error
        }
    }
}

// MARK: - Wire payloads

/// The mark-read update body — web's `{ is_read: true }` literal.
private struct MarkReadPayload: Encodable {
    let is_read: Bool
}
