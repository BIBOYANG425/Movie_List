"""
Movie review business logic.
"""
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.db.models import MediaItem, MovieReview, ReviewLike, User, UserRanking


class ReviewNotFoundError(Exception):
    """Raised when a review does not exist."""


class NotReviewOwnerError(Exception):
    """Raised when a user tries to modify another user's review."""


class DuplicateReviewError(Exception):
    """Raised when a user already reviewed this movie."""


def _avatar_url(user: User) -> str:
    from app.services.social_service import _avatar_from_user
    return _avatar_from_user(user)


def _build_review_dict(
    review: MovieReview,
    user: User,
    media: MediaItem,
    viewer_id: UUID | None = None,
    is_liked: bool = False,
) -> dict:
    return {
        "id": review.id,
        "user_id": user.id,
        "username": user.username,
        "display_name": user.display_name,
        "avatar_url": _avatar_url(user),
        "media_item_id": media.id,
        "media_title": media.title,
        "body": review.body,
        "rating_tier": (
            review.rating_tier.value
            if hasattr(review.rating_tier, "value")
            else str(review.rating_tier) if review.rating_tier else None
        ),
        "contains_spoilers": review.contains_spoilers,
        "like_count": review.like_count,
        "is_liked_by_viewer": is_liked,
        "created_at": review.created_at,
        "updated_at": review.updated_at,
    }


def create_or_update_review(
    db: Session,
    user_id: UUID,
    media_item_id: UUID,
    body: str,
    contains_spoilers: bool = False,
) -> dict:
    """Create a review or update existing one. Pulls rating_tier from user ranking."""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise ValueError("User not found")

    media = db.query(MediaItem).filter(MediaItem.id == media_item_id).first()
    if not media:
        raise ValueError("Movie not found")

    # Look up user's ranking tier for this movie
    ranking = (
        db.query(UserRanking)
        .filter(
            UserRanking.user_id == user_id,
            UserRanking.media_item_id == media_item_id,
        )
        .first()
    )
    rating_tier = ranking.tier if ranking else None

    existing = (
        db.query(MovieReview)
        .filter(
            MovieReview.user_id == user_id,
            MovieReview.media_item_id == media_item_id,
        )
        .first()
    )

    if existing:
        existing.body = body
        existing.contains_spoilers = contains_spoilers
        existing.rating_tier = rating_tier
        db.add(existing)
        db.commit()
        db.refresh(existing)
        return _build_review_dict(existing, user, media)
    else:
        review = MovieReview(
            user_id=user_id,
            media_item_id=media_item_id,
            body=body,
            rating_tier=rating_tier,
            contains_spoilers=contains_spoilers,
        )
        db.add(review)
        db.commit()
        db.refresh(review)
        return _build_review_dict(review, user, media)


def get_reviews_for_movie(
    db: Session,
    media_item_id: UUID,
    viewer_id: UUID,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """Get all reviews for a movie, showing friend reviews first."""
    from app.db.models import Follow

    total = (
        db.query(func.count(MovieReview.id))
        .filter(MovieReview.media_item_id == media_item_id)
        .scalar()
    )

    # Get following IDs for priority ordering
    following_ids = {
        r.following_id
        for r in db.query(Follow.following_id)
        .filter(Follow.follower_id == viewer_id)
        .all()
    }

    # Get liked review IDs for viewer
    liked_ids = {
        r.review_id
        for r in db.query(ReviewLike.review_id)
        .filter(ReviewLike.user_id == viewer_id)
        .all()
    }

    rows = (
        db.query(MovieReview, User, MediaItem)
        .join(User, MovieReview.user_id == User.id)
        .join(MediaItem, MovieReview.media_item_id == MediaItem.id)
        .filter(MovieReview.media_item_id == media_item_id)
        .order_by(MovieReview.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    # Sort: friends first, then by date
    reviews = []
    for review, user, media in rows:
        reviews.append(_build_review_dict(
            review, user, media,
            viewer_id=viewer_id,
            is_liked=review.id in liked_ids,
        ))

    # Stable sort: friends first
    reviews.sort(key=lambda r: (r["user_id"] not in following_ids, r["user_id"] != viewer_id))

    return {"reviews": reviews, "total": total}


def get_reviews_by_user(
    db: Session,
    target_user_id: UUID,
    viewer_id: UUID,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """Get all reviews by a specific user."""
    total = (
        db.query(func.count(MovieReview.id))
        .filter(MovieReview.user_id == target_user_id)
        .scalar()
    )

    liked_ids = {
        r.review_id
        for r in db.query(ReviewLike.review_id)
        .filter(ReviewLike.user_id == viewer_id)
        .all()
    }

    rows = (
        db.query(MovieReview, User, MediaItem)
        .join(User, MovieReview.user_id == User.id)
        .join(MediaItem, MovieReview.media_item_id == MediaItem.id)
        .filter(MovieReview.user_id == target_user_id)
        .order_by(MovieReview.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )

    return {
        "reviews": [
            _build_review_dict(review, user, media, viewer_id=viewer_id, is_liked=review.id in liked_ids)
            for review, user, media in rows
        ],
        "total": total,
    }


def delete_review(db: Session, user_id: UUID, review_id: UUID) -> bool:
    """Delete a review. Only the owner can delete."""
    review = db.query(MovieReview).filter(MovieReview.id == review_id).first()
    if not review:
        raise ReviewNotFoundError(f"Review {review_id} not found")
    if review.user_id != user_id:
        raise NotReviewOwnerError("You can only delete your own reviews")

    db.delete(review)
    db.commit()
    return True


def toggle_review_like(db: Session, user_id: UUID, review_id: UUID) -> dict:
    """Like or unlike a review. Returns updated like state."""
    review = db.query(MovieReview).filter(MovieReview.id == review_id).first()
    if not review:
        raise ReviewNotFoundError(f"Review {review_id} not found")

    existing = (
        db.query(ReviewLike)
        .filter(ReviewLike.review_id == review_id, ReviewLike.user_id == user_id)
        .first()
    )

    if existing:
        db.delete(existing)
        review.like_count = max(0, review.like_count - 1)
        is_liked = False
    else:
        like = ReviewLike(review_id=review_id, user_id=user_id)
        db.add(like)
        review.like_count += 1
        is_liked = True

    db.add(review)
    db.commit()
    db.refresh(review)

    return {"review_id": review_id, "like_count": review.like_count, "is_liked": is_liked}
