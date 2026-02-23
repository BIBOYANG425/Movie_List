"""
Review request/response schemas.
"""
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class CreateReviewRequest(BaseModel):
    """Create or update a review for a movie."""

    media_item_id: UUID
    body: str = Field(..., min_length=10, max_length=2000)
    contains_spoilers: bool = False


class ReviewResponse(BaseModel):
    """A single review."""

    id: UUID
    user_id: UUID
    username: str
    display_name: str | None = None
    avatar_url: str | None = None
    media_item_id: UUID
    media_title: str
    body: str
    rating_tier: str | None = None
    contains_spoilers: bool = False
    like_count: int = 0
    is_liked_by_viewer: bool = False
    created_at: datetime
    updated_at: datetime


class ReviewListResponse(BaseModel):
    """Paginated list of reviews."""

    reviews: list[ReviewResponse]
    total: int
