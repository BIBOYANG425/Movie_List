"""
Ranking request/response schemas.
"""
from datetime import datetime
from enum import Enum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, field_validator, model_validator


class TierEnum(str, Enum):
    """Valid tier values — must match DB enum."""

    S = "S"
    A = "A"
    B = "B"
    C = "C"
    D = "D"


class CreateRankingRequest(BaseModel):
    """Payload for POST /rankings."""

    media_id: UUID
    tier: TierEnum
    prev_ranking_id: UUID | None = None
    next_ranking_id: UUID | None = None
    notes: str | None = None

    @field_validator("notes")
    @classmethod
    def cap_notes_length(cls, v: str | None) -> str | None:
        if v is not None and len(v) > 2000:
            raise ValueError("Notes cannot exceed 2000 characters")
        return v

    @model_validator(mode="after")
    def prev_and_next_must_differ(self) -> "CreateRankingRequest":
        if (
            self.prev_ranking_id is not None
            and self.next_ranking_id is not None
            and self.prev_ranking_id == self.next_ranking_id
        ):
            raise ValueError("prev_ranking_id and next_ranking_id must be different")
        return self


class MoveRankingRequest(BaseModel):
    """Payload for PATCH /rankings/{ranking_id}/move."""

    tier: TierEnum
    prev_ranking_id: UUID | None = None
    next_ranking_id: UUID | None = None

    @model_validator(mode="after")
    def prev_and_next_must_differ(self) -> "MoveRankingRequest":
        if (
            self.prev_ranking_id is not None
            and self.next_ranking_id is not None
            and self.prev_ranking_id == self.next_ranking_id
        ):
            raise ValueError("prev_ranking_id and next_ranking_id must be different")
        return self


class RankingListItem(BaseModel):
    """Single item in the ranked-list response."""

    id: UUID
    media_item_id: UUID
    tier: str
    rank_position: float
    visual_score: float
    notes: str | None
    media_title: str
    media_type: str
    attributes: dict
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)
