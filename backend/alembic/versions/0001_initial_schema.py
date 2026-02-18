"""Initial schema — users, media_items, user_rankings, follows

Revision ID: 0001
Revises: —
Create Date: 2025-01-01 00:00:00
"""
from typing import Sequence, Union

import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB, UUID
from alembic import op

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── Extensions ────────────────────────────────────────────────────────────
    op.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
    op.execute("CREATE EXTENSION IF NOT EXISTS citext")
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    # ── Enum types ────────────────────────────────────────────────────────────
    # media_type: only MOVIE (PLAY removed per product decision)
    op.execute("CREATE TYPE media_type AS ENUM ('MOVIE')")
    op.execute("CREATE TYPE ranking_tier AS ENUM ('S', 'A', 'B', 'C', 'D')")

    # ── Trigger function (auto-update updated_at) ─────────────────────────────
    op.execute("""
        CREATE OR REPLACE FUNCTION set_updated_at()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          NEW.updated_at = now();
          RETURN NEW;
        END;
        $$
    """)

    # ── users ─────────────────────────────────────────────────────────────────
    op.create_table(
        "users",
        sa.Column("id", UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        # citext: case-insensitive unique — 'Alice' and 'alice' are the same
        sa.Column("username", sa.Text, nullable=False),
        sa.Column("email", sa.Text, nullable=False),
        sa.Column("password_hash", sa.Text, nullable=False),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default="true"),
        sa.Column("is_admin", sa.Boolean, nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            r"username ~ '^[a-zA-Z0-9_]{3,32}$'",
            name="chk_username_format",
        ),
        sa.UniqueConstraint("username", name="uq_users_username"),
        sa.UniqueConstraint("email", name="uq_users_email"),
    )
    # Alter columns to citext after table creation (SQLAlchemy doesn't have native citext)
    op.execute("ALTER TABLE users ALTER COLUMN username TYPE citext")
    op.execute("ALTER TABLE users ALTER COLUMN email TYPE citext")

    op.execute("""
        CREATE TRIGGER trg_users_updated_at
        BEFORE UPDATE ON users
        FOR EACH ROW EXECUTE FUNCTION set_updated_at()
    """)

    # ── media_items ───────────────────────────────────────────────────────────
    op.create_table(
        "media_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("media_type", sa.Text, nullable=False, server_default="'MOVIE'"),
        sa.Column("title", sa.Text, nullable=False),
        sa.Column("release_year", sa.Integer, nullable=True),
        sa.Column("tmdb_id", sa.BigInteger, nullable=True),
        sa.Column("attributes", JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("is_verified", sa.Boolean, nullable=False, server_default="false"),
        sa.Column("is_user_generated", sa.Boolean, nullable=False, server_default="false"),
        sa.Column(
            "created_by_user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.CheckConstraint(
            "jsonb_typeof(attributes) = 'object'",
            name="chk_attributes_object",
        ),
        sa.CheckConstraint(
            "release_year IS NULL OR release_year BETWEEN 1800 AND 2200",
            name="chk_release_year",
        ),
    )
    # Alter media_type to use the enum
    op.execute("ALTER TABLE media_items ALTER COLUMN media_type TYPE media_type USING media_type::media_type")

    # Unique tmdb_id only for MOVIE rows — partial index
    op.execute("""
        CREATE UNIQUE INDEX uq_media_items_movie_tmdb_id
          ON media_items (tmdb_id)
          WHERE media_type = 'MOVIE' AND tmdb_id IS NOT NULL
    """)

    # Full-text / trigram indexes
    op.execute("""
        CREATE INDEX idx_media_items_title_trgm
          ON media_items
          USING GIST (title gist_trgm_ops)
    """)
    op.execute("""
        CREATE INDEX idx_media_items_attributes_gin
          ON media_items
          USING GIN (attributes jsonb_path_ops)
    """)
    op.execute("""
        CREATE INDEX idx_media_items_genre_btree
          ON media_items ((attributes ->> 'genre'))
    """)

    op.execute("""
        CREATE TRIGGER trg_media_items_updated_at
        BEFORE UPDATE ON media_items
        FOR EACH ROW EXECUTE FUNCTION set_updated_at()
    """)

    # ── user_rankings ─────────────────────────────────────────────────────────
    op.create_table(
        "user_rankings",
        sa.Column("id", UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("user_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("media_item_id", UUID(as_uuid=True),
                  sa.ForeignKey("media_items.id", ondelete="CASCADE"), nullable=False),
        sa.Column("tier", sa.Text, nullable=False),
        sa.Column("rank_position", sa.Float, nullable=False),
        sa.Column("visual_score", sa.Numeric(3, 1), nullable=False),
        sa.Column("notes", sa.Text, nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.UniqueConstraint("user_id", "media_item_id", name="uq_user_media"),
        sa.UniqueConstraint("user_id", "tier", "rank_position", name="uq_user_tier_rank_position"),
        sa.CheckConstraint(
            "isfinite(rank_position) AND rank_position = rank_position",
            name="chk_rank_position_finite",
        ),
        sa.CheckConstraint(
            "visual_score >= 0.0 AND visual_score <= 10.0",
            name="chk_visual_score_0_10",
        ),
        sa.CheckConstraint(
            """
            (tier = 'S' AND visual_score BETWEEN 9.0 AND 10.0) OR
            (tier = 'A' AND visual_score BETWEEN 8.0 AND 8.9) OR
            (tier = 'B' AND visual_score BETWEEN 7.0 AND 7.9) OR
            (tier = 'C' AND visual_score BETWEEN 6.0 AND 6.9) OR
            (tier = 'D' AND visual_score BETWEEN 0.0 AND 5.9)
            """,
            name="chk_visual_score_by_tier",
        ),
    )
    # Convert tier text column to enum
    op.execute("ALTER TABLE user_rankings ALTER COLUMN tier TYPE ranking_tier USING tier::ranking_tier")

    # Covering index for sorted list queries
    op.execute("""
        CREATE INDEX idx_user_rankings_user_tier_rank
          ON user_rankings (user_id, tier, rank_position)
    """)

    op.execute("""
        CREATE TRIGGER trg_user_rankings_updated_at
        BEFORE UPDATE ON user_rankings
        FOR EACH ROW EXECUTE FUNCTION set_updated_at()
    """)

    # ── follows ───────────────────────────────────────────────────────────────
    op.create_table(
        "follows",
        sa.Column("id", UUID(as_uuid=True), primary_key=True,
                  server_default=sa.text("gen_random_uuid()")),
        sa.Column("follower_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("following_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  nullable=False, server_default=sa.text("now()")),
        sa.UniqueConstraint("follower_id", "following_id", name="uq_follow"),
        sa.CheckConstraint("follower_id <> following_id", name="chk_no_self_follow"),
    )

    # ── Postgres helper functions ──────────────────────────────────────────────

    op.execute("""
        CREATE OR REPLACE FUNCTION rebalance_tier_positions(p_user_id uuid, p_tier ranking_tier)
        RETURNS void
        LANGUAGE sql
        AS $$
          WITH ordered AS (
            SELECT
              id,
              (row_number() OVER (ORDER BY rank_position, id) * 1000.0)::double precision AS new_pos
            FROM user_rankings
            WHERE user_id = p_user_id AND tier = p_tier
          )
          UPDATE user_rankings ur
          SET rank_position = o.new_pos,
              updated_at = now()
          FROM ordered o
          WHERE ur.id = o.id;
        $$
    """)

    op.execute("""
        CREATE OR REPLACE FUNCTION insert_ranking_between(
          p_user_id uuid,
          p_media_item_id uuid,
          p_tier ranking_tier,
          p_prev_ranking_id uuid DEFAULT NULL,
          p_next_ranking_id uuid DEFAULT NULL
        )
        RETURNS user_rankings
        LANGUAGE plpgsql
        AS $$
        DECLARE
          v_prev user_rankings%ROWTYPE;
          v_next user_rankings%ROWTYPE;
          v_min_score numeric(3,1);
          v_max_score numeric(3,1);
          v_new_rank double precision;
          v_raw_score numeric;
          v_inserted user_rankings%ROWTYPE;
        BEGIN
          IF p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL
             AND p_prev_ranking_id = p_next_ranking_id THEN
            RAISE EXCEPTION 'prev and next ranking ids must be different';
          END IF;

          SELECT
            CASE p_tier WHEN 'S' THEN 9.0 WHEN 'A' THEN 8.0 WHEN 'B' THEN 7.0 WHEN 'C' THEN 6.0 ELSE 0.0 END,
            CASE p_tier WHEN 'S' THEN 10.0 WHEN 'A' THEN 8.9 WHEN 'B' THEN 7.9 WHEN 'C' THEN 6.9 ELSE 5.9 END
          INTO v_min_score, v_max_score;

          IF p_prev_ranking_id IS NOT NULL THEN
            SELECT * INTO v_prev
            FROM user_rankings
            WHERE id = p_prev_ranking_id AND user_id = p_user_id AND tier = p_tier
            FOR UPDATE;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'prev ranking % not found for user/tier', p_prev_ranking_id;
            END IF;
          END IF;

          IF p_next_ranking_id IS NOT NULL THEN
            SELECT * INTO v_next
            FROM user_rankings
            WHERE id = p_next_ranking_id AND user_id = p_user_id AND tier = p_tier
            FOR UPDATE;
            IF NOT FOUND THEN
              RAISE EXCEPTION 'next ranking % not found for user/tier', p_next_ranking_id;
            END IF;
          END IF;

          IF p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL THEN
            IF v_prev.rank_position >= v_next.rank_position THEN
              RAISE EXCEPTION 'prev.rank_position must be < next.rank_position';
            END IF;

            IF (v_next.rank_position - v_prev.rank_position) < 1e-9 THEN
              PERFORM rebalance_tier_positions(p_user_id, p_tier);

              SELECT * INTO v_prev FROM user_rankings WHERE id = p_prev_ranking_id FOR UPDATE;
              SELECT * INTO v_next FROM user_rankings WHERE id = p_next_ranking_id FOR UPDATE;
            END IF;
          END IF;

          v_new_rank :=
            CASE
              WHEN p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL
                   THEN (v_prev.rank_position + v_next.rank_position) / 2.0
              WHEN p_prev_ranking_id IS NOT NULL THEN v_prev.rank_position + 1000.0
              WHEN p_next_ranking_id IS NOT NULL THEN v_next.rank_position - 1000.0
              ELSE 1000.0
            END;

          v_raw_score :=
            CASE
              WHEN p_prev_ranking_id IS NOT NULL AND p_next_ranking_id IS NOT NULL
                   THEN (v_prev.visual_score + v_next.visual_score) / 2.0
              WHEN p_prev_ranking_id IS NOT NULL THEN (v_prev.visual_score + v_min_score) / 2.0
              WHEN p_next_ranking_id IS NOT NULL THEN (v_max_score + v_next.visual_score) / 2.0
              ELSE (v_min_score + v_max_score) / 2.0
            END;

          v_raw_score := LEAST(v_max_score::numeric, GREATEST(v_min_score::numeric, v_raw_score));

          INSERT INTO user_rankings (user_id, media_item_id, tier, rank_position, visual_score)
          VALUES (p_user_id, p_media_item_id, p_tier, v_new_rank, round(v_raw_score, 1))
          RETURNING * INTO v_inserted;

          RETURN v_inserted;
        END;
        $$
    """)


def downgrade() -> None:
    # Drop in reverse dependency order
    op.execute("DROP FUNCTION IF EXISTS insert_ranking_between(uuid, uuid, ranking_tier, uuid, uuid)")
    op.execute("DROP FUNCTION IF EXISTS rebalance_tier_positions(uuid, ranking_tier)")
    op.drop_table("follows")
    op.drop_table("user_rankings")
    op.drop_table("media_items")
    op.drop_table("users")
    op.execute("DROP FUNCTION IF EXISTS set_updated_at()")
    op.execute("DROP TYPE IF EXISTS ranking_tier")
    op.execute("DROP TYPE IF EXISTS media_type")
    op.execute("DROP EXTENSION IF EXISTS pg_trgm")
    op.execute("DROP EXTENSION IF EXISTS citext")
    op.execute("DROP EXTENSION IF EXISTS pgcrypto")
