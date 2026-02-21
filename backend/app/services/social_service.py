"""
Social business logic — follows, feed, leaderboard, and user search.
"""
from urllib.parse import quote_plus
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.db.models import Follow, MediaItem, User, UserRanking


class UserNotFoundError(Exception):
    """Raised when the target user does not exist."""


class SelfFollowError(Exception):
    """Raised when a user tries to follow themselves."""


class AlreadyFollowingError(Exception):
    """Raised when a follow relationship already exists."""


def _avatar_from_username(username: str) -> str:
    return f"https://api.dicebear.com/8.x/thumbs/svg?seed={quote_plus(username)}"


def create_follow(db: Session, follower_id: UUID, following_id: UUID) -> dict:
    """Create a follow relationship and return a response payload."""
    if follower_id == following_id:
        raise SelfFollowError("You cannot follow yourself")

    target_user = (
        db.query(User)
        .filter(User.id == following_id, User.is_active.is_(True))
        .first()
    )
    if target_user is None:
        raise UserNotFoundError(f"User {following_id} not found")

    existing = (
        db.query(Follow)
        .filter(
            Follow.follower_id == follower_id,
            Follow.following_id == following_id,
        )
        .first()
    )
    if existing is not None:
        raise AlreadyFollowingError("You already follow this user")

    follow = Follow(follower_id=follower_id, following_id=following_id)
    db.add(follow)
    db.commit()
    db.refresh(follow)

    return {
        "follower_id": follow.follower_id,
        "following_id": follow.following_id,
        "following_username": target_user.username,
        "created_at": follow.created_at,
    }


def delete_follow(db: Session, follower_id: UUID, following_id: UUID) -> bool:
    """Delete a follow relationship. Returns True when deleted."""
    count = (
        db.query(Follow)
        .filter(
            Follow.follower_id == follower_id,
            Follow.following_id == following_id,
        )
        .delete(synchronize_session=False)
    )
    db.commit()
    return count > 0


def list_following(db: Session, user_id: UUID) -> list[dict]:
    """Return users this user follows."""
    rows = (
        db.query(Follow, User)
        .join(User, Follow.following_id == User.id)
        .filter(Follow.follower_id == user_id)
        .order_by(User.username.asc())
        .all()
    )
    return [
        {
            "user_id": target.id,
            "username": target.username,
            "avatar_url": _avatar_from_username(target.username),
            "followed_at": follow.created_at,
        }
        for follow, target in rows
    ]


def list_followers(db: Session, user_id: UUID) -> list[dict]:
    """Return users who follow this user."""
    rows = (
        db.query(Follow, User)
        .join(User, Follow.follower_id == User.id)
        .filter(Follow.following_id == user_id)
        .order_by(User.username.asc())
        .all()
    )
    return [
        {
            "user_id": follower.id,
            "username": follower.username,
            "avatar_url": _avatar_from_username(follower.username),
            "followed_at": follow.created_at,
        }
        for follow, follower in rows
    ]


def get_feed(db: Session, user_id: UUID, limit: int = 50) -> list[dict]:
    """Return recent rankings from followed users."""
    rows = (
        db.query(UserRanking, User, MediaItem)
        .join(Follow, Follow.following_id == UserRanking.user_id)
        .join(User, User.id == UserRanking.user_id)
        .join(MediaItem, MediaItem.id == UserRanking.media_item_id)
        .filter(Follow.follower_id == user_id)
        .order_by(UserRanking.updated_at.desc())
        .limit(limit)
        .all()
    )

    return [
        {
            "ranking_id": ranking.id,
            "user_id": author.id,
            "username": author.username,
            "media_item_id": media.id,
            "media_title": media.title,
            "tier": ranking.tier.value if hasattr(ranking.tier, "value") else str(ranking.tier),
            "visual_score": float(ranking.visual_score),
            "ranked_at": ranking.updated_at,
        }
        for ranking, author, media in rows
    ]


def get_leaderboard(db: Session, limit: int = 25) -> list[dict]:
    """Return items with the most S-tier rankings."""
    rows = (
        db.query(
            MediaItem.id.label("media_item_id"),
            MediaItem.title.label("media_title"),
            func.count(UserRanking.id).label("s_tier_count"),
            func.avg(UserRanking.visual_score).label("avg_visual_score"),
        )
        .join(UserRanking, UserRanking.media_item_id == MediaItem.id)
        .filter(UserRanking.tier == "S")
        .group_by(MediaItem.id, MediaItem.title)
        .order_by(
            func.count(UserRanking.id).desc(),
            func.avg(UserRanking.visual_score).desc(),
            MediaItem.title.asc(),
        )
        .limit(limit)
        .all()
    )

    return [
        {
            "media_item_id": row.media_item_id,
            "media_title": row.media_title,
            "s_tier_count": int(row.s_tier_count),
            "avg_visual_score": float(row.avg_visual_score or 0),
        }
        for row in rows
    ]


def search_users(db: Session, user_id: UUID, query: str, limit: int = 10) -> list[dict]:
    """Search active users by username, excluding self."""
    q = query.strip()
    if not q:
        return []

    following_ids = {
        row.following_id
        for row in (
            db.query(Follow.following_id)
            .filter(Follow.follower_id == user_id)
            .all()
        )
    }

    users = (
        db.query(User)
        .filter(
            User.id != user_id,
            User.is_active.is_(True),
            User.username.ilike(f"%{q}%"),
        )
        .order_by(User.username.asc())
        .limit(limit)
        .all()
    )

    return [
        {
            "id": row.id,
            "username": row.username,
            "avatar_url": _avatar_from_username(row.username),
            "is_following": row.id in following_ids,
        }
        for row in users
    ]


def get_profile_summary(db: Session, viewer_id: UUID, target_id: UUID) -> dict:
    """Return profile header details and follow-state."""
    target = (
        db.query(User)
        .filter(User.id == target_id, User.is_active.is_(True))
        .first()
    )
    if target is None:
        raise UserNotFoundError(f"User {target_id} not found")

    followers_count = (
        db.query(Follow)
        .filter(Follow.following_id == target_id)
        .count()
    )
    following_count = (
        db.query(Follow)
        .filter(Follow.follower_id == target_id)
        .count()
    )

    is_following = (
        db.query(Follow)
        .filter(Follow.follower_id == viewer_id, Follow.following_id == target_id)
        .first()
        is not None
    )
    is_followed_by = (
        db.query(Follow)
        .filter(Follow.follower_id == target_id, Follow.following_id == viewer_id)
        .first()
        is not None
    )
    is_self = viewer_id == target_id

    return {
        "user_id": target.id,
        "username": target.username,
        "avatar_url": _avatar_from_username(target.username),
        "followers_count": followers_count,
        "following_count": following_count,
        "is_self": is_self,
        "is_following": is_following,
        "is_followed_by": is_followed_by,
        "is_mutual": is_following and is_followed_by,
    }
