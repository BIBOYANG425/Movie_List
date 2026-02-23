"""
Discovery request/response schemas.
"""
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class FriendRecommendation(BaseModel):
    """A movie recommended based on friends' rankings."""

    tmdb_id: str
    title: str
    poster_url: str | None = None
    year: str | None = None
    genres: list[str] = []
    avg_tier: str
    avg_tier_numeric: float
    friend_count: int
    friend_avatars: list[str] = []
    friend_usernames: list[str] = []
    top_tier: str  # highest tier any friend gave it

    model_config = ConfigDict(from_attributes=True)


class TrendingMovie(BaseModel):
    """A movie trending among the user's friends."""

    tmdb_id: str
    title: str
    poster_url: str | None = None
    year: str | None = None
    genres: list[str] = []
    ranker_count: int
    avg_tier: str
    avg_tier_numeric: float
    recent_rankers: list[str] = []  # usernames

    model_config = ConfigDict(from_attributes=True)


class GenreProfileItem(BaseModel):
    """One genre slice in a user's taste profile."""

    genre: str
    count: int
    percentage: float
    avg_tier: str
    avg_tier_numeric: float


class GenreProfileResponse(BaseModel):
    """Complete genre taste profile for a user."""

    user_id: str
    username: str
    total_ranked: int
    genres: list[GenreProfileItem]


class GenreComparisonResponse(BaseModel):
    """Side-by-side genre comparison between two users."""

    viewer_id: str
    viewer_username: str
    target_id: str
    target_username: str
    viewer_genres: list[GenreProfileItem]
    target_genres: list[GenreProfileItem]
    shared_top_genres: list[str]  # genres both rank highly


class DiscoveryFeedResponse(BaseModel):
    """Combined discovery feed response."""

    recommendations: list[FriendRecommendation]
    trending: list[TrendingMovie]
