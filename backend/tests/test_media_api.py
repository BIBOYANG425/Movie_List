import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import uuid4

from fastapi.testclient import TestClient

from app.db.session import get_db
from app.deps.auth import get_current_user
from app.main import app


def _fake_media_row(**overrides):
    base = {
        "id": uuid4(),
        "title": "Dune: Part Two",
        "release_year": 2024,
        "media_type": "MOVIE",
        "tmdb_id": 693134,
        "attributes": {"genre": "Science Fiction", "genres": ["Science Fiction"], "source": "tmdb"},
        "is_verified": True,
        "is_user_generated": False,
        "created_by_user_id": None,
        "created_at": datetime.now(timezone.utc),
        "updated_at": datetime.now(timezone.utc),
    }
    base.update(overrides)
    return SimpleNamespace(**base)


class TestMediaApi(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(app)
        app.dependency_overrides[get_db] = lambda: iter([object()])

    def tearDown(self) -> None:
        app.dependency_overrides.clear()

    def test_search_media_returns_envelope(self) -> None:
        row = _fake_media_row()
        with patch(
            "app.api.media.search_media_hybrid",
            new=AsyncMock(return_value=([row], "db_only")),
        ):
            response = self.client.get("/media/search", params={"q": "dune"})

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["meta"]["source"], "db_only")
        self.assertEqual(payload["meta"]["count"], 1)
        self.assertEqual(payload["items"][0]["title"], "Dune: Part Two")

    def test_get_media_item_returns_404(self) -> None:
        with patch("app.api.media.get_media_by_id", return_value=None):
            response = self.client.get(f"/media/{uuid4()}")
        self.assertEqual(response.status_code, 404)

    def test_create_stub_requires_auth(self) -> None:
        response = self.client.post(
            "/media/create_stub",
            json={
                "title": "Hamilton",
                "media_type": "PLAY",
                "release_year": 2015,
                "attributes": {"source": "manual"},
            },
        )
        self.assertEqual(response.status_code, 401)

    def test_create_stub_success(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        row = _fake_media_row(
            title="Hamilton",
            media_type="PLAY",
            tmdb_id=None,
            is_verified=False,
            is_user_generated=True,
            attributes={"genre": "Musical", "genres": ["Musical"], "source": "manual"},
        )

        with patch("app.api.media.create_manual_stub", return_value=row):
            response = self.client.post(
                "/media/create_stub",
                json={
                    "title": "Hamilton",
                    "media_type": "PLAY",
                    "release_year": 2015,
                    "attributes": {"source": "manual"},
                },
            )

        self.assertEqual(response.status_code, 201)
        payload = response.json()
        self.assertEqual(payload["media_type"], "PLAY")
        self.assertEqual(payload["title"], "Hamilton")
