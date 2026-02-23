"""
Reviews API — /reviews
──────────────────────
Movie reviews: create, list, like, delete.

Endpoints:
  POST   /reviews                     — Create/update a review
  GET    /reviews/movie/{media_id}    — Reviews for a movie
  GET    /reviews/user/{user_id}      — Reviews by a user
  DELETE /reviews/{review_id}         — Delete own review
  POST   /reviews/{review_id}/like    — Toggle like on a review
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.reviews import CreateReviewRequest, ReviewListResponse, ReviewResponse
from app.services.review_service import (
    NotReviewOwnerError,
    ReviewNotFoundError,
    create_or_update_review,
    delete_review,
    get_reviews_by_user,
    get_reviews_for_movie,
    toggle_review_like,
)

router = APIRouter()


@router.post("", response_model=ReviewResponse, status_code=status.HTTP_201_CREATED)
def create_review(
    payload: CreateReviewRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return create_or_update_review(
            db,
            current_user.id,
            payload.media_item_id,
            payload.body,
            payload.contains_spoilers,
        )
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.get("/movie/{media_item_id}", response_model=ReviewListResponse)
def get_movie_reviews(
    media_item_id: UUID,
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    return get_reviews_for_movie(db, media_item_id, current_user.id, limit=limit, offset=offset)


@router.get("/user/{user_id}", response_model=ReviewListResponse)
def get_user_reviews(
    user_id: UUID,
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    return get_reviews_by_user(db, user_id, current_user.id, limit=limit, offset=offset)


@router.delete("/{review_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_review_endpoint(
    review_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    try:
        delete_review(db, current_user.id, review_id)
    except ReviewNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotReviewOwnerError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


@router.post("/{review_id}/like")
def toggle_like(
    review_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return toggle_review_like(db, current_user.id, review_id)
    except ReviewNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
