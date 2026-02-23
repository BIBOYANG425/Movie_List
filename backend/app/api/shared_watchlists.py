"""
Shared Watchlists API — /watchlists/shared
───────────────────────────────────────────
Collaborative watchlists with voting.

Endpoints:
  POST   /watchlists/shared                           — Create a shared watchlist
  GET    /watchlists/shared                           — List my shared watchlists
  GET    /watchlists/shared/{id}                      — Get watchlist detail
  DELETE /watchlists/shared/{id}                      — Delete watchlist (owner only)
  POST   /watchlists/shared/{id}/members              — Add a member
  POST   /watchlists/shared/{id}/items                — Add a movie
  POST   /watchlists/shared/{id}/items/{item_id}/vote — Toggle vote
"""
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.shared_watchlists import (
    AddItemRequest,
    AddMemberRequest,
    CreateSharedWatchlistRequest,
    SharedWatchlistDetailResponse,
    SharedWatchlistResponse,
    WatchlistItemResponse,
    WatchlistMemberResponse,
)
from app.services.shared_watchlist_service import (
    AlreadyMemberError,
    ItemAlreadyExistsError,
    NotWatchlistMemberError,
    NotWatchlistOwnerError,
    WatchlistNotFoundError,
    add_item,
    add_member,
    create_shared_watchlist,
    delete_shared_watchlist,
    get_shared_watchlist_detail,
    list_my_shared_watchlists,
    toggle_vote,
)

router = APIRouter()


@router.post("", response_model=SharedWatchlistResponse, status_code=status.HTTP_201_CREATED)
def create_watchlist(
    payload: CreateSharedWatchlistRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    return create_shared_watchlist(db, current_user.id, payload.name)


@router.get("", response_model=list[SharedWatchlistResponse])
def list_watchlists(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    return list_my_shared_watchlists(db, current_user.id)


@router.get("/{watchlist_id}", response_model=SharedWatchlistDetailResponse)
def get_watchlist(
    watchlist_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return get_shared_watchlist_detail(db, watchlist_id, current_user.id)
    except WatchlistNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotWatchlistMemberError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


@router.delete("/{watchlist_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_watchlist(
    watchlist_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> None:
    try:
        delete_shared_watchlist(db, watchlist_id, current_user.id)
    except WatchlistNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotWatchlistOwnerError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc


@router.post("/{watchlist_id}/members", response_model=WatchlistMemberResponse, status_code=status.HTTP_201_CREATED)
def invite_member(
    watchlist_id: UUID,
    payload: AddMemberRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return add_member(db, watchlist_id, current_user.id, payload.user_id)
    except WatchlistNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotWatchlistMemberError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    except AlreadyMemberError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.post("/{watchlist_id}/items", response_model=WatchlistItemResponse, status_code=status.HTTP_201_CREATED)
def add_watchlist_item(
    watchlist_id: UUID,
    payload: AddItemRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return add_item(db, watchlist_id, current_user.id, payload.media_item_id)
    except WatchlistNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotWatchlistMemberError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    except ItemAlreadyExistsError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.post("/{watchlist_id}/items/{item_id}/vote")
def vote_on_item(
    watchlist_id: UUID,
    item_id: UUID,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    try:
        return toggle_vote(db, watchlist_id, item_id, current_user.id)
    except WatchlistNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except NotWatchlistMemberError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
