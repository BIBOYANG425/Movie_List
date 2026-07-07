import XCTest
@testable import Spool

/// Pure decision logic behind `FeedScreen`/`NotificationBellView` (Task 5):
///  - `FeedScreenLogic.shouldLoadNextPage` — the infinite-scroll trigger +
///    its concurrency guard;
///  - `FeedScreenLogic.allEventTypes` — the "no filter UI yet" allow-set;
///  - `NotificationDestination.destination(for:)` — the notification-row →
///    route table (only follower rows navigate in v1).
/// Source: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 5).
final class FeedScreenLogicTests: XCTestCase {

    private let actor = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    // MARK: - shouldLoadNextPage

    func testLoadsNextPageOnLastCardWithMore() {
        XCTAssertTrue(FeedScreenLogic.shouldLoadNextPage(
            appearedIndex: 19, lastIndex: 19, hasMore: true, isLoading: false))
    }

    func testDoesNotLoadOnNonLastCard() {
        XCTAssertFalse(FeedScreenLogic.shouldLoadNextPage(
            appearedIndex: 5, lastIndex: 19, hasMore: true, isLoading: false))
    }

    func testDoesNotLoadWhenNoMore() {
        XCTAssertFalse(FeedScreenLogic.shouldLoadNextPage(
            appearedIndex: 19, lastIndex: 19, hasMore: false, isLoading: false))
    }

    func testDoesNotLoadWhileAlreadyLoading() {
        // The concurrency guard: a second .onAppear during an in-flight fetch
        // must not double-trigger.
        XCTAssertFalse(FeedScreenLogic.shouldLoadNextPage(
            appearedIndex: 19, lastIndex: 19, hasMore: true, isLoading: true))
    }

    func testDoesNotLoadOnEmptyList() {
        // lastIndex -1 == empty; a stray appear can't fire a load.
        XCTAssertFalse(FeedScreenLogic.shouldLoadNextPage(
            appearedIndex: 0, lastIndex: -1, hasMore: true, isLoading: false))
    }

    // MARK: - allEventTypes

    func testAllEventTypesCoversTheContractSet() {
        XCTAssertEqual(FeedScreenLogic.allEventTypes,
                       ["ranking_add", "ranking_move", "review", "milestone", "list_create"])
    }

    // MARK: - NotificationDestination

    private func item(kind: String, actor: UUID?) -> NotificationItem {
        NotificationItem(id: UUID(), userID: UUID(), type: kind, title: "t",
                         body: nil, actorID: actor, referenceID: nil,
                         isRead: false, createdAt: "2026-07-07T00:00:00+00:00",
                         actorUsername: "mei", actorAvatarPath: nil)
    }

    func testFollowerRowRoutesToActorProfile() {
        let dest = NotificationDestination.destination(for: item(kind: "new_follower", actor: actor))
        XCTAssertEqual(dest, .actorProfile(actor))
    }

    func testFollowerRowWithoutActorIsInert() {
        let dest = NotificationDestination.destination(for: item(kind: "new_follower", actor: nil))
        XCTAssertEqual(dest, .none)
    }

    func testUnknownKindFallsBackToFollowerAndRoutes() {
        // Unknown type → NotificationKind.orFallback → .newFollower → routes
        // to the actor when present (never-drop-a-row contract).
        let dest = NotificationDestination.destination(for: item(kind: "brand_new_type", actor: actor))
        XCTAssertEqual(dest, .actorProfile(actor))
    }

    func testNonFollowerKindsAreInert() {
        for kind in ["review_like", "list_like", "badge_unlock", "ranking_comment", "journal_tag"] {
            XCTAssertEqual(NotificationDestination.destination(for: item(kind: kind, actor: actor)),
                           .none, "\(kind) should not navigate in v1")
        }
    }
}
