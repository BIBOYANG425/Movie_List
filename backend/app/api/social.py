"""
Social Service — /social
─────────────────────────
Follow graph + activity feed.

Endpoints:
  GET    /social/profile/{user_id}    — Profile summary for a user
  GET    /social/profile/{user_id}/followers — Followers list for a user
  GET    /social/profile/{user_id}/following — Following list for a user
  GET    /social/users                — Search users by username
  POST   /social/follow/{user_id}     — Follow a user
  DELETE /social/follow/{user_id}     — Unfollow
  GET    /social/following            — Users I follow
  GET    /social/followers            — Users who follow me
  GET    /social/feed                 — Recent rankings from people you follow
  GET    /social/leaderboard          — Top-ranked items across all users
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.social import (
    FeedItemResponse,
    FollowListItem,
    FollowRelationResponse,
    LeaderboardItemResponse,
    ProfileSummaryResponse,
    UserPreview,
)
from app.services.social_service import (
    AlreadyFollowingError,
    SelfFollowError,
    UserNotFoundError,
    create_follow,
    delete_follow,
    get_feed,
    get_leaderboard,
    get_profile_summary,
    list_followers,
    list_following,
    search_users,
)

router = APIRouter()


def _error(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}


# ── Routes ────────────────────────────────────────────────────────────────────

@router.get("/profile/{user_id}", response_model=ProfileSummaryResponse)
def get_profile_summary_endpoint(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return get_profile_summary(db, current_user.id, user_id)
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc


@router.get("/profile/{user_id}/followers", response_model=list[FollowListItem])
def get_profile_followers(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    try:
        get_profile_summary(db, current_user.id, user_id)
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc
    return list_followers(db, user_id)


@router.get("/profile/{user_id}/following", response_model=list[FollowListItem])
def get_profile_following(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    try:
        get_profile_summary(db, current_user.id, user_id)
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc
    return list_following(db, user_id)


@router.get("/users", response_model=list[UserPreview])
def search_users_endpoint(
    q: str = Query(..., min_length=1, description="Username search query"),
    limit: int = Query(10, ge=1, le=50),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    return search_users(db, current_user.id, q, limit=limit)


@router.post(
    "/follow/{user_id}",
    response_model=FollowRelationResponse,
    status_code=status.HTTP_201_CREATED,
)
def follow_user_endpoint(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return create_follow(db, current_user.id, user_id)
    except SelfFollowError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=_error("SELF_FOLLOW", str(exc)),
        ) from exc
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc
    except AlreadyFollowingError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=_error("ALREADY_FOLLOWING", str(exc)),
        ) from exc


@router.delete("/follow/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def unfollow_user_endpoint(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    deleted = delete_follow(db, current_user.id, user_id)
    if not deleted:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("NOT_FOLLOWING", "You do not follow this user"),
        )


@router.get("/following", response_model=list[FollowListItem])
def get_following(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    return list_following(db, current_user.id)


@router.get("/followers", response_model=list[FollowListItem])
def get_followers(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    return list_followers(db, current_user.id)


@router.get("/feed", response_model=list[FeedItemResponse])
def get_social_feed(
    limit: int = Query(50, ge=1, le=200),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    return get_feed(db, current_user.id, limit=limit)


@router.get("/leaderboard", response_model=list[LeaderboardItemResponse])
def get_social_leaderboard(
    limit: int = Query(25, ge=1, le=100),
    db: Session = Depends(get_db),
) -> list[dict]:
    return get_leaderboard(db, limit=limit)
