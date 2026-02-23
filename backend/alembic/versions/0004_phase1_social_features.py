"""Phase 1 social features: movie reviews, shared watchlists.

Revision ID: 0004
Revises: 0003
Create Date: 2026-02-23 09:40:00
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0004"
down_revision: Union[str, None] = "0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── movie_reviews ─────────────────────────────────────────────────────
    op.create_table(
        "movie_reviews",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("media_item_id", UUID(as_uuid=True), sa.ForeignKey("media_items.id", ondelete="CASCADE"), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("rating_tier", sa.String(1), nullable=True),
        sa.Column("contains_spoilers", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("like_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("user_id", "media_item_id", name="uq_user_review"),
        sa.CheckConstraint(
            "length(btrim(body)) >= 10 AND length(btrim(body)) <= 2000",
            name="chk_review_body_len",
        ),
    )
    op.create_index("idx_reviews_user", "movie_reviews", ["user_id", sa.text("created_at DESC")])
    op.create_index("idx_reviews_media", "movie_reviews", ["media_item_id", sa.text("created_at DESC")])

    # ── review_likes ──────────────────────────────────────────────────────
    op.create_table(
        "review_likes",
        sa.Column("review_id", UUID(as_uuid=True), sa.ForeignKey("movie_reviews.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )

    # ── shared_watchlists ─────────────────────────────────────────────────
    op.create_table(
        "shared_watchlists",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("name", sa.String(100), nullable=False, server_default="Movie Night"),
        sa.Column("created_by", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint(
            "length(btrim(name)) >= 1 AND length(btrim(name)) <= 100",
            name="chk_shared_watchlist_name",
        ),
    )

    # ── shared_watchlist_members ───────────────────────────────────────────
    op.create_table(
        "shared_watchlist_members",
        sa.Column("watchlist_id", UUID(as_uuid=True), sa.ForeignKey("shared_watchlists.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )

    # ── shared_watchlist_items ────────────────────────────────────────────
    op.create_table(
        "shared_watchlist_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("watchlist_id", UUID(as_uuid=True), sa.ForeignKey("shared_watchlists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("media_item_id", UUID(as_uuid=True), sa.ForeignKey("media_items.id", ondelete="CASCADE"), nullable=False),
        sa.Column("added_by", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("vote_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("watchlist_id", "media_item_id", name="uq_shared_watchlist_item"),
    )
    op.create_index("idx_shared_watchlist_items_wl", "shared_watchlist_items", ["watchlist_id"])

    # ── shared_watchlist_votes ────────────────────────────────────────────
    op.create_table(
        "shared_watchlist_votes",
        sa.Column("item_id", UUID(as_uuid=True), sa.ForeignKey("shared_watchlist_items.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )


def downgrade() -> None:
    op.drop_table("shared_watchlist_votes")
    op.drop_table("shared_watchlist_items")
    op.drop_table("shared_watchlist_members")
    op.drop_table("shared_watchlists")
    op.drop_table("review_likes")
    op.drop_table("movie_reviews")
