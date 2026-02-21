"""
SQLAlchemy ORM models.

Schema mirrors marquee_schema.sql exactly — column names, constraints,
indexes and Postgres-specific types (JSONB, CITEXT via String, UUID) are
all intentional.

Relationships are declared here so services can navigate the graph
without writing raw joins everywhere.
"""
import uuid
from datetime import datetime, timezone
from enum import Enum as PyEnum

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy import Enum as SAEnum
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, relationship


# ── Base ──────────────────────────────────────────────────────────────────────

class Base(DeclarativeBase):
    pass


# ── Enums ─────────────────────────────────────────────────────────────────────

class TierEnum(str, PyEnum):
    S = "S"
    A = "A"
    B = "B"
    C = "C"
    D = "D"


class MediaTypeEnum(str, PyEnum):
    MOVIE = "MOVIE"
    PLAY = "PLAY"


# ── Timestamp helper ──────────────────────────────────────────────────────────

def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


# ── Models ────────────────────────────────────────────────────────────────────

class User(Base):
    """
    Application user.

    username / email are case-insensitive in Postgres (citext extension).
    SQLAlchemy uses String here; the migration DDL uses the native CITEXT type.
    """
    __tablename__ = "users"

    id = Column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        comment="Primary key — UUID v4",
    )
    username = Column(
        String(32),
        unique=True,
        nullable=False,
        index=True,
        comment="Case-insensitive username (3-32 chars, alphanumeric + underscore)",
    )
    email = Column(
        String(255),
        unique=True,
        nullable=False,
        index=True,
    )
    password_hash = Column(String, nullable=False)
    is_active = Column(Boolean, default=True, nullable=False)
    is_admin = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime(timezone=True), default=_utcnow, nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=_utcnow,
        onupdate=_utcnow,
        nullable=False,
    )

    # Relationships
    rankings = relationship(
        "UserRanking",
        back_populates="user",
        cascade="all, delete-orphan",
        lazy="dynamic",
    )
    # Follows where this user is the one following others
    following_assoc = relationship(
        "Follow",
        foreign_keys="Follow.follower_id",
        back_populates="follower",
        cascade="all, delete-orphan",
    )
    # Follows where this user is being followed
    followers_assoc = relationship(
        "Follow",
        foreign_keys="Follow.following_id",
        back_populates="following_user",
        cascade="all, delete-orphan",
    )

    def __repr__(self) -> str:
        return f"<User id={self.id} username={self.username!r}>"


class MediaItem(Base):
    """
    A movie or stage play that can be ranked.

    attributes (JSONB) stores flexible metadata:
        {
          "director": "...",
          "cast": ["...", "..."],
          "genres": ["Sci-Fi", "Drama"],   ← primary list for filtering
          "genre": "Sci-Fi",               ← denormalised fast-lookup value
          "runtime_minutes": 120,
          "release_date": "2024-03-01",
          "language": "en",
          "source": "tmdb" | "manual"
        }
    """
    __tablename__ = "media_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    # NULL means user-generated; unique only for MOVIE rows (enforced by partial index in DDL)
    tmdb_id = Column(Integer, unique=False, nullable=True, index=True)
    title = Column(String(500), nullable=False, index=True)
    release_year = Column(Integer, nullable=True)
    media_type = Column(
        SAEnum(MediaTypeEnum, name="media_type", create_type=False),
        nullable=False,
        default=MediaTypeEnum.MOVIE,
    )
    attributes = Column(JSONB, nullable=False, default=dict)
    is_verified = Column(Boolean, default=False, nullable=False)
    is_user_generated = Column(Boolean, default=False, nullable=False)
    created_by_user_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    created_at = Column(DateTime(timezone=True), default=_utcnow, nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=_utcnow,
        onupdate=_utcnow,
        nullable=False,
    )

    __table_args__ = (
        CheckConstraint(
            "release_year IS NULL OR release_year BETWEEN 1800 AND 2200",
            name="chk_release_year",
        ),
        CheckConstraint(
            "media_type <> 'PLAY' OR tmdb_id IS NULL",
            name="chk_play_tmdb_null",
        ),
    )

    # Relationships
    rankings = relationship("UserRanking", back_populates="media_item")
    created_by = relationship("User", foreign_keys=[created_by_user_id])

    def __repr__(self) -> str:
        return f"<MediaItem id={self.id} title={self.title!r} year={self.release_year}>"


class UserRanking(Base):
    """
    A single user's ranking of a single media item.

    rank_position  — fractional index (float64). Gaps allow insertion between
                     any two items without renumbering the whole list.
                     The Postgres function insert_ranking_between() manages this.

    visual_score   — human-readable score (0.0–10.0) interpolated from
                     neighboring items' scores. Validated per-tier by a
                     CHECK constraint in the migration DDL.
    """
    __tablename__ = "user_rankings"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    media_item_id = Column(
        UUID(as_uuid=True),
        ForeignKey("media_items.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    tier = Column(
        SAEnum(TierEnum, name="ranking_tier", create_type=False),
        nullable=False,
    )
    # Fractional position — managed by insert_ranking_between() Postgres fn
    rank_position = Column(Float, nullable=False, default=1000.0)
    # Interpolated display score — enforced to tier range by DB CHECK
    visual_score = Column(Numeric(3, 1), nullable=False)
    notes = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=_utcnow, nullable=False)
    updated_at = Column(
        DateTime(timezone=True),
        default=_utcnow,
        onupdate=_utcnow,
        nullable=False,
    )

    __table_args__ = (
        # A user can only rank each item once
        UniqueConstraint("user_id", "media_item_id", name="uq_user_media"),
        # No two items can occupy the exact same fractional position in a tier
        UniqueConstraint("user_id", "tier", "rank_position", name="uq_user_tier_rank_position"),
        # Covering index: get user's full sorted list in one index scan
        Index("idx_user_rankings_user_tier_rank", "user_id", "tier", "rank_position"),
        CheckConstraint(
            "rank_position = rank_position "
            "AND rank_position < 'Infinity'::double precision "
            "AND rank_position > '-Infinity'::double precision",
            name="chk_rank_position_finite",
        ),
        CheckConstraint(
            "visual_score >= 0.0 AND visual_score <= 10.0",
            name="chk_visual_score_0_10",
        ),
        CheckConstraint(
            """
            (tier::text = 'S' AND visual_score BETWEEN 9.0 AND 10.0) OR
            (tier::text = 'A' AND visual_score BETWEEN 8.0 AND 8.9) OR
            (tier::text = 'B' AND visual_score BETWEEN 7.0 AND 7.9) OR
            (tier::text = 'C' AND visual_score BETWEEN 6.0 AND 6.9) OR
            (tier::text = 'D' AND visual_score BETWEEN 0.0 AND 5.9)
            """,
            name="chk_visual_score_by_tier",
        ),
    )

    # Relationships
    user = relationship("User", back_populates="rankings")
    media_item = relationship("MediaItem", back_populates="rankings")

    def __repr__(self) -> str:
        return (
            f"<UserRanking user={self.user_id} media={self.media_item_id} "
            f"tier={self.tier} pos={self.rank_position}>"
        )


class Follow(Base):
    """
    Directed follow relationship: follower → following_user.
    Used by the social feed to show what people you follow are ranking.
    """
    __tablename__ = "follows"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    follower_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    following_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    created_at = Column(DateTime(timezone=True), default=_utcnow, nullable=False)

    __table_args__ = (
        UniqueConstraint("follower_id", "following_id", name="uq_follow"),
        CheckConstraint("follower_id <> following_id", name="chk_no_self_follow"),
    )

    # Relationships
    follower = relationship("User", foreign_keys=[follower_id], back_populates="following_assoc")
    following_user = relationship("User", foreign_keys=[following_id], back_populates="followers_assoc")

    def __repr__(self) -> str:
        return f"<Follow {self.follower_id} → {self.following_id}>"
