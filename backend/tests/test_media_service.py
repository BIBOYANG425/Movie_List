import unittest
from types import SimpleNamespace
from uuid import uuid4

from app.schemas.media import CreateMediaStubRequest, MediaTypeEnum
from app.services.media_service import (
    InvalidMediaPayloadError,
    merge_dedup_results,
    normalize_attributes,
    normalize_title,
    validate_media_type_payload,
)


class TestMediaServiceHelpers(unittest.TestCase):
    def test_normalize_title_collapses_spaces(self) -> None:
        self.assertEqual(normalize_title("  Dune   Part   Two "), "Dune Part Two")

    def test_normalize_attributes_sets_required_keys_for_play(self) -> None:
        attrs = normalize_attributes(
            {"genres": [" historical drama ", "Historical Drama"]},
            MediaTypeEnum.PLAY,
        )
        self.assertEqual(attrs["source"], "manual")
        self.assertEqual(attrs["genre"], "Historical Drama")
        self.assertEqual(attrs["genres"], ["Historical Drama"])

    def test_validate_media_type_payload_rejects_play_tmdb_id(self) -> None:
        payload = CreateMediaStubRequest(
            title="Hamilton",
            media_type=MediaTypeEnum.PLAY,
            release_year=2015,
            tmdb_id=123,
            attributes={},
        )
        with self.assertRaises(InvalidMediaPayloadError):
            validate_media_type_payload(payload)

    def test_merge_dedup_results_uses_id_and_tmdb(self) -> None:
        shared_tmdb = 693134
        row_a = SimpleNamespace(id=uuid4(), tmdb_id=shared_tmdb)
        row_b = SimpleNamespace(id=uuid4(), tmdb_id=shared_tmdb)
        row_c = SimpleNamespace(id=uuid4(), tmdb_id=None)

        merged = merge_dedup_results([row_a], [row_b, row_c])
        self.assertEqual(len(merged), 2)
        self.assertIs(merged[0], row_a)
        self.assertIs(merged[1], row_c)
