"""
Social request/response schemas.
"""
from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class UserPreview(BaseModel):
    """Minimal public profile used in social views."""

    id: UUID
    username: str
    display_name: str | None = None
    avatar_url: str | None = None
    is_following: bool = False


class FollowRelationResponse(BaseModel):
    """Returned after a successful follow action."""

    follower_id: UUID
    following_id: UUID
    following_username: str
    created_at: datetime


class FollowListItem(BaseModel):
    """One user in followers/following lists."""

    user_id: UUID
    username: str
    display_name: str | None = None
    avatar_url: str | None = None
    followed_at: datetime


class FeedItemResponse(BaseModel):
    """One ranking event in the social feed."""

    ranking_id: UUID
    user_id: UUID
    username: str
    media_item_id: UUID
    media_title: str
    tier: str
    visual_score: float
    ranked_at: datetime


class LeaderboardItemResponse(BaseModel):
    """Aggregated leaderboard entry."""

    media_item_id: UUID
    media_title: str
    s_tier_count: int
    avg_visual_score: float


class MyProfileResponse(BaseModel):
    """Editable profile details for the authenticated user."""

    user_id: UUID
    username: str
    email: str
    display_name: str | None = None
    bio: str | None = None
    avatar_url: str | None = None
    avatar_path: str | None = None
    onboarding_completed: bool


class UpdateMyProfileRequest(BaseModel):
    """Partial update payload for the authenticated user profile."""

    display_name: str | None = Field(default=None, max_length=60)
    bio: str | None = Field(default=None, max_length=280)
    avatar_url: str | None = Field(default=None, max_length=500)
    avatar_path: str | None = Field(default=None, max_length=255)
    onboarding_completed: bool | None = None


class ProfileSummaryResponse(BaseModel):
    """Profile header data for the social profile page."""

    user_id: UUID
    username: str
    display_name: str | None = None
    bio: str | None = None
    avatar_url: str | None = None
    onboarding_completed: bool = False
    followers_count: int
    following_count: int
    is_self: bool
    is_following: bool
    is_followed_by: bool
    is_mutual: bool
