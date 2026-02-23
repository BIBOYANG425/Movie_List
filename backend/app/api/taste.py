"""
Taste API — /taste
──────────────────
Taste compatibility, shared movies, ranking comparison.

Endpoints:
  GET /taste/compatibility/{user_id}  — Taste score vs. another user
  GET /taste/shared/{user_id}         — Paginated shared movies
  GET /taste/compare/{user_id}        — Full ranking comparison
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.taste import (
    RankingComparisonResponse,
    SharedMovieListResponse,
    TasteCompatibilityResponse,
)
from app.services.taste_service import (
    compute_taste_compatibility,
    get_ranking_comparison,
    get_shared_movies,
)
from app.services.social_service import UserNotFoundError

router = APIRouter()


def _error(code: str, message: str) -> dict:
    return {"error": {"code": code, "message": message}}


@router.get("/compatibility/{user_id}", response_model=TasteCompatibilityResponse)
def get_compatibility(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return compute_taste_compatibility(db, current_user.id, user_id)
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc


@router.get("/shared/{user_id}", response_model=SharedMovieListResponse)
def get_shared(
    user_id: UUID,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    return get_shared_movies(db, current_user.id, user_id, limit=limit, offset=offset)


@router.get("/compare/{user_id}", response_model=RankingComparisonResponse)
def get_comparison(
    user_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return get_ranking_comparison(db, current_user.id, user_id)
    except UserNotFoundError as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=_error("USER_NOT_FOUND", str(exc)),
        ) from exc
