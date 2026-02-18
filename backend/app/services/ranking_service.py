"""
Ranking business logic — list, create, move, delete.

CREATE delegates to the Postgres function insert_ranking_between().
MOVE uses Python-side locking with SELECT ... FOR UPDATE.
"""
from uuid import UUID

from sqlalchemy import case, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db.models import MediaItem, UserRanking
from app.schemas.rankings import CreateRankingRequest, MoveRankingRequest
from app.services.ranking_math import RankingMath


# ── Helpers ──────────────────────────────────────────────────────────────────


def tier_sort_case():
    """SQLAlchemy CASE expression to order tiers: S=1, A=2, B=3, C=4, D=5."""
    return case(
        (UserRanking.tier == "S", 1),
        (UserRanking.tier == "A", 2),
        (UserRanking.tier == "B", 3),
        (UserRanking.tier == "C", 4),
        (UserRanking.tier == "D", 5),
        else_=6,
    )


def _hydrate_ranking(ranking: UserRanking, media: MediaItem) -> dict:
    """Build a dict matching the RankingListItem schema from ORM objects."""
    return {
        "id": ranking.id,
        "media_item_id": ranking.media_item_id,
        "tier": ranking.tier.value if hasattr(ranking.tier, "value") else str(ranking.tier),
        "rank_position": float(ranking.rank_position),
        "visual_score": float(ranking.visual_score),
        "notes": ranking.notes,
        "media_title": media.title,
        "media_type": media.media_type,
        "attributes": media.attributes or {},
        "created_at": ranking.created_at,
        "updated_at": ranking.updated_at,
    }


# ── Read operations ──────────────────────────────────────────────────────────


def list_rankings(
    db: Session,
    user_id: UUID,
    *,
    tier: str | None = None,
    genre: str | None = None,
    media_type: str | None = None,
    limit: int = 500,
    offset: int = 0,
) -> list[dict]:
    """
    Return the user's full ranked list, ordered S->A->B->C->D then by
    rank_position ASC within each tier.

    Supports optional filtering by tier, genre (JSONB containment), and
    media_type.
    """
    query = (
        db.query(UserRanking, MediaItem)
        .join(MediaItem, UserRanking.media_item_id == MediaItem.id)
        .filter(UserRanking.user_id == user_id)
    )

    if tier is not None:
        query = query.filter(UserRanking.tier == tier.upper())

    if media_type is not None:
        query = query.filter(MediaItem.media_type == media_type.upper())

    if genre is not None:
        # JSONB containment: attributes->'genres' @> '["Drama"]'
        query = query.filter(
            MediaItem.attributes["genres"].astext.contains(genre)
        )

    query = (
        query
        .order_by(tier_sort_case(), UserRanking.rank_position.asc())
        .limit(limit)
        .offset(offset)
    )

    rows = query.all()
    return [_hydrate_ranking(ranking, media) for ranking, media in rows]


def get_ranking_with_media(
    db: Session,
    ranking_id: UUID,
    user_id: UUID,
) -> dict | None:
    """
    Fetch a single ranking with its media item, scoped to the owning user.

    Returns a hydrated dict or None if not found.
    """
    row = (
        db.query(UserRanking, MediaItem)
        .join(MediaItem, UserRanking.media_item_id == MediaItem.id)
        .filter(UserRanking.id == ranking_id, UserRanking.user_id == user_id)
        .first()
    )
    if row is None:
        return None
    ranking, media = row
    return _hydrate_ranking(ranking, media)


# ── Neighbor validation ──────────────────────────────────────────────────────


def _validate_neighbors(
    db: Session,
    user_id: UUID,
    tier: str,
    prev_id: UUID | None,
    next_id: UUID | None,
    *,
    exclude_ranking_id: UUID | None = None,
    lock: bool = False,
) -> tuple[UserRanking | None, UserRanking | None]:
    """
    Validate that prev/next ranking IDs belong to the same user and tier,
    and are in the correct order. Optionally locks rows with FOR UPDATE.

    Returns (prev_row, next_row) — either may be None.
    Raises ValueError on validation failures.
    """

    def _fetch(ranking_id: UUID, label: str) -> UserRanking:
        q = db.query(UserRanking).filter(
            UserRanking.id == ranking_id,
            UserRanking.user_id == user_id,
        )
        if lock:
            q = q.with_for_update()
        row = q.first()
        if row is None:
            raise ValueError(f"{label} ranking {ranking_id} not found for this user")
        tier_value = row.tier.value if hasattr(row.tier, "value") else str(row.tier)
        if tier_value != tier.upper():
            raise ValueError(
                f"{label} ranking {ranking_id} is in tier {tier_value}, expected {tier.upper()}"
            )
        if exclude_ranking_id is not None and row.id == exclude_ranking_id:
            raise ValueError(
                f"{label} ranking cannot be the same as the ranking being moved"
            )
        return row

    prev_row = _fetch(prev_id, "prev") if prev_id else None
    next_row = _fetch(next_id, "next") if next_id else None

    if prev_row is not None and next_row is not None:
        if prev_row.rank_position >= next_row.rank_position:
            raise ValueError("prev must have a lower rank_position than next")

    return prev_row, next_row


# ── Position + score computation ─────────────────────────────────────────────


def _compute_position_and_score(
    db: Session,
    user_id: UUID,
    tier: str,
    prev_row: UserRanking | None,
    next_row: UserRanking | None,
) -> tuple[float, float]:
    """
    Use RankingMath to compute the new rank_position and visual_score.

    If the gap is too small, triggers a rebalance via the Postgres function
    and re-fetches the neighbors before re-computing.
    """
    prev_rank = float(prev_row.rank_position) if prev_row else None
    next_rank = float(next_row.rank_position) if next_row else None

    try:
        new_position = RankingMath.calculate_position(prev_rank, next_rank)
    except ValueError:
        # Gap too small — rebalance the entire tier
        db.execute(
            text("SELECT rebalance_tier_positions(:uid, :tier::ranking_tier)"),
            {"uid": str(user_id), "tier": tier.upper()},
        )
        db.flush()

        # Re-fetch neighbors after rebalance
        if prev_row:
            db.refresh(prev_row)
            prev_rank = float(prev_row.rank_position)
        if next_row:
            db.refresh(next_row)
            next_rank = float(next_row.rank_position)

        new_position = RankingMath.calculate_position(prev_rank, next_rank)

    prev_score = float(prev_row.visual_score) if prev_row else None
    next_score = float(next_row.visual_score) if next_row else None
    new_score = RankingMath.interpolate_score(tier, prev_score, next_score)

    return new_position, new_score


# ── Create ───────────────────────────────────────────────────────────────────


class DuplicateRankingError(Exception):
    """Raised when the user has already ranked the given media item."""
    pass


class RankingNotFoundError(Exception):
    """Raised when a ranking row is not found or not owned by the user."""
    pass


def create_ranking(
    db: Session,
    user_id: UUID,
    payload: CreateRankingRequest,
) -> UserRanking:
    """
    Rank a media item for the first time using the Postgres function
    insert_ranking_between().

    The SQL function handles:
      - Fractional position calculation
      - Visual score interpolation and clamping
      - Automatic rebalance when gaps get too small
      - Row-level locking on neighbors

    After insertion, apply optional notes via a Python UPDATE
    (the SQL function does not accept notes).
    """
    tier_value = payload.tier.value if hasattr(payload.tier, "value") else str(payload.tier)

    try:
        result = db.execute(
            text(
                "SELECT * FROM insert_ranking_between("
                "  :user_id, :media_id, :tier::ranking_tier, :prev_id, :next_id"
                ")"
            ),
            {
                "user_id": str(user_id),
                "media_id": str(payload.media_id),
                "tier": tier_value,
                "prev_id": str(payload.prev_ranking_id) if payload.prev_ranking_id else None,
                "next_id": str(payload.next_ranking_id) if payload.next_ranking_id else None,
            },
        )
        row = result.fetchone()
    except IntegrityError as exc:
        db.rollback()
        error_str = str(exc.orig).lower()
        if "uq_user_media" in error_str:
            raise DuplicateRankingError(
                "You have already ranked this media item"
            ) from exc
        raise
    except Exception as exc:
        db.rollback()
        raise ValueError(str(exc)) from exc

    if row is None:
        raise ValueError("insert_ranking_between returned no row")

    # The SQL function returns a user_rankings row — extract the new ID
    new_ranking_id = row[0]  # id is the first column

    # Apply notes if provided (SQL function doesn't handle notes)
    if payload.notes:
        db.execute(
            text("UPDATE user_rankings SET notes = :notes WHERE id = :rid"),
            {"notes": payload.notes, "rid": str(new_ranking_id)},
        )

    db.commit()

    # Load the ORM object for the response
    ranking = db.query(UserRanking).filter(UserRanking.id == new_ranking_id).first()
    return ranking


# ── Move ─────────────────────────────────────────────────────────────────────


def move_ranking(
    db: Session,
    user_id: UUID,
    ranking_id: UUID,
    payload: MoveRankingRequest,
) -> UserRanking:
    """
    Move an existing ranking to a new position (possibly a different tier).

    Transaction flow:
      1. SELECT ranking FOR UPDATE (lock the row being moved)
      2. Validate + lock neighbor rows
      3. Compute new position and score via RankingMath
      4. UPDATE the ranking row
      5. COMMIT
    """
    tier_value = payload.tier.value if hasattr(payload.tier, "value") else str(payload.tier)

    # Lock the row being moved
    ranking = (
        db.query(UserRanking)
        .filter(UserRanking.id == ranking_id, UserRanking.user_id == user_id)
        .with_for_update()
        .first()
    )
    if ranking is None:
        raise RankingNotFoundError(f"Ranking {ranking_id} not found")

    # Validate and lock neighbors
    try:
        prev_row, next_row = _validate_neighbors(
            db,
            user_id,
            tier_value,
            payload.prev_ranking_id,
            payload.next_ranking_id,
            exclude_ranking_id=ranking_id,
            lock=True,
        )
    except ValueError as exc:
        db.rollback()
        raise

    # Compute new position and visual score
    new_position, new_score = _compute_position_and_score(
        db, user_id, tier_value, prev_row, next_row
    )

    # Update the ranking
    ranking.tier = tier_value
    ranking.rank_position = new_position
    ranking.visual_score = new_score

    db.flush()
    db.commit()
    db.refresh(ranking)

    return ranking


# ── Delete ───────────────────────────────────────────────────────────────────


def delete_ranking(
    db: Session,
    user_id: UUID,
    ranking_id: UUID,
) -> bool:
    """
    Delete a ranking owned by the user.

    Returns True if deleted, False if not found.
    """
    count = (
        db.query(UserRanking)
        .filter(UserRanking.id == ranking_id, UserRanking.user_id == user_id)
        .delete(synchronize_session=False)
    )
    db.commit()
    return count > 0
