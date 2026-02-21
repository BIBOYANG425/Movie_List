import inspect
import unittest
from pathlib import Path

from app.services import ranking_service


class TestPhase2Contracts(unittest.TestCase):
    def test_media_type_filter_contract_in_rankings(self) -> None:
        source = inspect.getsource(ranking_service.list_rankings)
        self.assertIn("media_type.upper()", source)
        self.assertIn("MediaItem.media_type", source)

    def test_migration_0002_contains_play_support_statements(self) -> None:
        migration_path = Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0002_add_play_support.py"
        content = migration_path.read_text(encoding="utf-8")
        self.assertIn("ALTER TYPE media_type ADD VALUE IF NOT EXISTS 'PLAY'", content)
        self.assertIn("chk_play_tmdb_null", content)
        self.assertIn("uq_media_items_manual_owner_title_year", content)
