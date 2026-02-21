"""Add PLAY media type support and manual media dedupe index.

Revision ID: 0002
Revises: 0001
Create Date: 2026-02-21 00:00:00
"""
from typing import Sequence, Union

from alembic import op

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Extend enum with PLAY for stage plays/manual media entries.
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE media_type ADD VALUE IF NOT EXISTS 'PLAY'")

    # Enforce PLAY rows never carry a TMDB identifier.
    op.execute(
        """
        ALTER TABLE media_items
        ADD CONSTRAINT chk_play_tmdb_null
        CHECK (media_type <> 'PLAY' OR tmdb_id IS NULL)
        """
    )

    # Owner-scoped duplicate prevention for user-generated manual stubs.
    op.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS uq_media_items_manual_owner_title_year
        ON media_items (created_by_user_id, media_type, lower(title), COALESCE(release_year, 0))
        WHERE is_user_generated = true
        """
    )


def downgrade() -> None:
    # Drop newly added index/constraint.
    op.execute("DROP INDEX IF EXISTS uq_media_items_manual_owner_title_year")
    op.execute("ALTER TABLE media_items DROP CONSTRAINT IF EXISTS chk_play_tmdb_null")

    # NOTE: PostgreSQL does not support dropping enum values directly.
    # PLAY remains in media_type on downgrade unless manually recreated.
