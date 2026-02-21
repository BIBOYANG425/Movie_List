"""
Media request/response schemas.
"""
from datetime import datetime
from enum import Enum
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class MediaTypeEnum(str, Enum):
    """Supported media categories."""

    MOVIE = "MOVIE"
    PLAY = "PLAY"


class SearchMeta(BaseModel):
    """Metadata returned by /media/search."""

    count: int
    source: Literal["db_only", "db_plus_tmdb", "tmdb_only"]


class MediaItemBaseResponse(BaseModel):
    """Shared fields across list/detail/create responses."""

    id: UUID
    title: str
    release_year: int | None
    media_type: str
    tmdb_id: int | None
    attributes: dict[str, Any]
    is_verified: bool
    is_user_generated: bool
    created_by_user_id: UUID | None

    model_config = ConfigDict(from_attributes=True)


class MediaItemDetailResponse(MediaItemBaseResponse):
    """Expanded media payload with timestamps."""

    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class MediaSearchResponse(BaseModel):
    """Response envelope for /media/search."""

    items: list[MediaItemBaseResponse]
    meta: SearchMeta


class CreateMediaStubRequest(BaseModel):
    """Payload for POST /media/create_stub."""

    title: str
    media_type: MediaTypeEnum
    release_year: int | None = Field(default=None, ge=1800, le=2200)
    tmdb_id: int | None = Field(default=None, ge=1)
    attributes: dict[str, Any] = Field(default_factory=dict)

    @field_validator("title")
    @classmethod
    def validate_title(cls, value: str) -> str:
        title = " ".join(value.strip().split())
        if not title:
            raise ValueError("title cannot be empty")
        if len(title) > 500:
            raise ValueError("title cannot exceed 500 characters")
        return title

    @model_validator(mode="after")
    def validate_play_constraints(self) -> "CreateMediaStubRequest":
        if self.media_type == MediaTypeEnum.PLAY and self.tmdb_id is not None:
            raise ValueError("PLAY entries cannot include tmdb_id")
        return self
