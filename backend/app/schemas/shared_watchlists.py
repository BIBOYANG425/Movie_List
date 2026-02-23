"""
Shared watchlist request/response schemas.
"""
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class CreateSharedWatchlistRequest(BaseModel):
    """Create a new shared watchlist."""

    name: str = Field(default="Movie Night", min_length=1, max_length=100)


class AddMemberRequest(BaseModel):
    """Add a member to a shared watchlist."""

    user_id: UUID


class AddItemRequest(BaseModel):
    """Add a movie to a shared watchlist."""

    media_item_id: UUID


class WatchlistMemberResponse(BaseModel):
    """A member of a shared watchlist."""

    user_id: UUID
    username: str
    display_name: str | None = None
    avatar_url: str | None = None
    joined_at: datetime


class WatchlistItemResponse(BaseModel):
    """An item in a shared watchlist."""

    id: UUID
    media_item_id: UUID
    media_title: str
    poster_url: str | None = None
    release_year: int | None = None
    added_by_username: str
    vote_count: int = 0
    viewer_has_voted: bool = False
    added_at: datetime


class SharedWatchlistResponse(BaseModel):
    """Full shared watchlist detail."""

    id: UUID
    name: str
    created_by: UUID
    creator_username: str
    member_count: int
    item_count: int
    created_at: datetime


class SharedWatchlistDetailResponse(SharedWatchlistResponse):
    """Shared watchlist with members and items."""

    members: list[WatchlistMemberResponse]
    items: list[WatchlistItemResponse]
