import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from fastapi.testclient import TestClient

from app.db.session import get_db
from app.deps.auth import get_current_user
from app.main import app
from app.services.social_service import AlreadyFollowingError, SelfFollowError, UserNotFoundError


class TestSocialApi(unittest.TestCase):
    def setUp(self) -> None:
        self.client = TestClient(app)
        app.dependency_overrides[get_db] = lambda: iter([object()])

    def tearDown(self) -> None:
        app.dependency_overrides.clear()

    def test_follow_requires_auth(self) -> None:
        response = self.client.post(f"/social/follow/{uuid4()}")
        self.assertEqual(response.status_code, 401)

    def test_follow_success(self) -> None:
        follower_id = uuid4()
        following_id = uuid4()
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=follower_id)

        with patch(
            "app.api.social.create_follow",
            return_value={
                "follower_id": follower_id,
                "following_id": following_id,
                "following_username": "cinephile",
                "created_at": datetime.now(timezone.utc),
            },
        ):
            response = self.client.post(f"/social/follow/{following_id}")

        self.assertEqual(response.status_code, 201)
        payload = response.json()
        self.assertEqual(payload["following_username"], "cinephile")

    def test_follow_maps_duplicate_error(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch(
            "app.api.social.create_follow",
            side_effect=AlreadyFollowingError("already"),
        ):
            response = self.client.post(f"/social/follow/{uuid4()}")

        self.assertEqual(response.status_code, 409)

    def test_follow_maps_not_found_error(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch(
            "app.api.social.create_follow",
            side_effect=UserNotFoundError("missing"),
        ):
            response = self.client.post(f"/social/follow/{uuid4()}")

        self.assertEqual(response.status_code, 404)

    def test_follow_maps_self_follow_error(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch(
            "app.api.social.create_follow",
            side_effect=SelfFollowError("no self follow"),
        ):
            response = self.client.post(f"/social/follow/{uuid4()}")

        self.assertEqual(response.status_code, 400)

    def test_unfollow_204(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch("app.api.social.delete_follow", return_value=True):
            response = self.client.delete(f"/social/follow/{uuid4()}")

        self.assertEqual(response.status_code, 204)

    def test_unfollow_404_when_missing(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch("app.api.social.delete_follow", return_value=False):
            response = self.client.delete(f"/social/follow/{uuid4()}")

        self.assertEqual(response.status_code, 404)

    def test_feed_response_shape(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        now = datetime.now(timezone.utc)
        with patch(
            "app.api.social.get_feed",
            return_value=[
                {
                    "ranking_id": uuid4(),
                    "user_id": uuid4(),
                    "username": "alex",
                    "media_item_id": uuid4(),
                    "media_title": "Dune: Part Two",
                    "tier": "S",
                    "visual_score": 9.5,
                    "ranked_at": now,
                }
            ],
        ):
            response = self.client.get("/social/feed")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(len(payload), 1)
        self.assertEqual(payload[0]["username"], "alex")

    def test_users_search_response_shape(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch(
            "app.api.social.search_users",
            return_value=[
                {
                    "id": uuid4(),
                    "username": "drew",
                    "is_following": True,
                }
            ],
        ):
            response = self.client.get("/social/users", params={"q": "dr"})

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload[0]["is_following"])
        self.assertIn("avatar_url", payload[0])

    def test_leaderboard_response_shape(self) -> None:
        with patch(
            "app.api.social.get_leaderboard",
            return_value=[
                {
                    "media_item_id": uuid4(),
                    "media_title": "The Godfather",
                    "s_tier_count": 12,
                    "avg_visual_score": 9.7,
                }
            ],
        ):
            response = self.client.get("/social/leaderboard")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload[0]["s_tier_count"], 12)

    def test_get_my_profile_shape(self) -> None:
        me_id = uuid4()
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=me_id)
        with patch(
            "app.api.social.get_my_profile",
            return_value={
                "user_id": me_id,
                "username": "sam",
                "email": "sam@example.com",
                "display_name": "Sam",
                "bio": "Movie nerd",
                "avatar_url": "https://example.com/avatar.png",
                "avatar_path": "abc/avatar.jpg",
                "onboarding_completed": True,
            },
        ):
            response = self.client.get("/social/me/profile")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["username"], "sam")
        self.assertTrue(payload["onboarding_completed"])

    def test_patch_my_profile_shape(self) -> None:
        me_id = uuid4()
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=me_id)
        with patch(
            "app.api.social.update_my_profile",
            return_value={
                "user_id": me_id,
                "username": "sam",
                "email": "sam@example.com",
                "display_name": "Sam Updated",
                "bio": "Updated bio",
                "avatar_url": "https://example.com/avatar-2.png",
                "avatar_path": "abc/avatar-2.png",
                "onboarding_completed": True,
            },
        ):
            response = self.client.patch(
                "/social/me/profile",
                json={
                    "display_name": "Sam Updated",
                    "bio": "Updated bio",
                    "onboarding_completed": True,
                },
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["display_name"], "Sam Updated")
        self.assertEqual(payload["bio"], "Updated bio")

    def test_profile_summary_shape(self) -> None:
        viewer_id = uuid4()
        target_id = uuid4()
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=viewer_id)
        with patch(
            "app.api.social.get_profile_summary",
            return_value={
                "user_id": target_id,
                "username": "sam",
                "avatar_url": "https://example.com/avatar.png",
                "followers_count": 8,
                "following_count": 11,
                "is_self": False,
                "is_following": True,
                "is_followed_by": True,
                "is_mutual": True,
            },
        ):
            response = self.client.get(f"/social/profile/{target_id}")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["followers_count"], 8)
        self.assertTrue(payload["is_mutual"])

    def test_profile_followers_shape(self) -> None:
        app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(id=uuid4())
        with patch("app.api.social.get_profile_summary", return_value={"user_id": uuid4()}), patch(
            "app.api.social.list_followers",
            return_value=[
                {
                    "user_id": uuid4(),
                    "username": "jules",
                    "avatar_url": "https://example.com/a.png",
                    "followed_at": datetime.now(timezone.utc),
                }
            ],
        ):
            response = self.client.get(f"/social/profile/{uuid4()}/followers")

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload[0]["username"], "jules")
