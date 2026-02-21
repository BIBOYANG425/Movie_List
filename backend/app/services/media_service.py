"""
Media business logic — local search, TMDB fallback caching, and manual stubs.
"""
import asyncio
import re
from typing import Any
from uuid import UUID

from sqlalchemy import func, or_
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.db.models import MediaItem
from app.schemas.media import CreateMediaStubRequest, MediaItemDetailResponse, MediaTypeEnum
from app.services.tmdb_sync import TMDBConfigError, TMDBService, TMDBUpstreamError

TMDB_FALLBACK_THRESHOLD = 8
TMDB_DETAIL_ENRICH_COUNT = 5


class MediaNotFoundError(Exception):
    """Raised when a media item cannot be found."""


class InvalidMediaPayloadError(Exception):
    """Raised when media payload validation fails at service layer."""


class DuplicateManualMediaError(Exception):
    """Raised when a manual stub conflicts with an existing owner-scoped record."""


def _media_type_value(media_type: Any) -> str:
    """Normalize DB/model enum values to plain strings."""
    return media_type.value if hasattr(media_type, "value") else str(media_type)


def normalize_title(title: str) -> str:
    """Trim and collapse whitespace to keep dedupe/index behavior stable."""
    return re.sub(r"\s+", " ", title.strip())


def _normalize_genre_name(value: str) -> str:
    """Normalize genre names to trimmed title case."""
    return normalize_title(value).title()


def normalize_attributes(attributes: dict[str, Any], media_type: MediaTypeEnum) -> dict[str, Any]:
    """
    Ensure attributes always remain JSON-object filter friendly.

    Guarantees:
    - source present
    - genre present (or None)
    - genres present (list[str], deduped)
    """
    attrs = dict(attributes or {})

    raw_genres = attrs.get("genres", [])
    if isinstance(raw_genres, str):
        raw_genres = [raw_genres]
    if not isinstance(raw_genres, list):
        raw_genres = []

    normalized_genres: list[str] = []
    for genre in raw_genres:
        if not isinstance(genre, str):
            continue
        cleaned = _normalize_genre_name(genre)
        if cleaned and cleaned not in normalized_genres:
            normalized_genres.append(cleaned)

    raw_genre = attrs.get("genre")
    if isinstance(raw_genre, str):
        primary_genre = _normalize_genre_name(raw_genre) or None
    else:
        primary_genre = None

    if primary_genre is None and normalized_genres:
        primary_genre = normalized_genres[0]
    if primary_genre is not None and primary_genre not in normalized_genres:
        normalized_genres.insert(0, primary_genre)

    attrs["genre"] = primary_genre
    attrs["genres"] = normalized_genres

    if media_type == MediaTypeEnum.PLAY:
        attrs["source"] = "manual"
    else:
        attrs["source"] = attrs.get("source") or "manual"

    return attrs


def validate_media_type_payload(payload: CreateMediaStubRequest) -> None:
    """Validate media-type-specific payload rules before writing.

    Note: PLAY/tmdb_id mutual exclusion is enforced at schema level via
    CreateMediaStubRequest.validate_play_constraints(). This function handles
    service-layer rules that require DB context or cannot be expressed in schema.
    """
    source = payload.attributes.get("source")
    if payload.media_type == MediaTypeEnum.PLAY and source not in (None, "manual"):
        raise InvalidMediaPayloadError("PLAY entries must use attributes.source='manual'")


def build_local_search_query(
    db: Session,
    q: str,
    media_type: MediaTypeEnum | None,
):
    """Build a deterministic fuzzy local-search query using pg_trgm similarity."""
    cleaned_query = normalize_title(q)
    lowered = cleaned_query.lower()
    similarity_score = func.similarity(func.lower(MediaItem.title), lowered)
    prefix_match = func.lower(MediaItem.title).like(f"{lowered}%")

    query = (
        db.query(MediaItem)
        .filter(
            or_(
                MediaItem.title.ilike(f"%{cleaned_query}%"),
                similarity_score > 0.20,
            )
        )
    )

    if media_type is not None:
        query = query.filter(MediaItem.media_type == media_type.value)

    return query.order_by(
        prefix_match.desc(),
        similarity_score.desc(),
        MediaItem.title.asc(),
        MediaItem.id.asc(),
    )


def search_local_media(
    db: Session,
    q: str,
    media_type: MediaTypeEnum | None,
    limit: int,
    offset: int,
) -> list[MediaItem]:
    """Run local fuzzy search with stable ordering and pagination."""
    return build_local_search_query(db, q, media_type).limit(limit).offset(offset).all()


async def fetch_tmdb_candidates(query: str, page: int = 1) -> list[dict[str, Any]]:
    """Fetch initial movie candidates from TMDB search."""
    service = TMDBService()
    return await service.search_movies(query=query, page=page)


async def enrich_tmdb_candidates(
    candidates: list[dict[str, Any]],
    *,
    max_count: int = TMDB_DETAIL_ENRICH_COUNT,
) -> list[dict[str, Any]]:
    """Hydrate top candidates with richer details for director/runtime/cast."""
    if not candidates:
        return []

    service = TMDBService()
    top_candidates = candidates[:max_count]
    detail_tasks = [service.get_movie_details(item["tmdb_id"]) for item in top_candidates]
    detail_results = await asyncio.gather(*detail_tasks, return_exceptions=True)

    by_tmdb_id: dict[int, dict[str, Any]] = {}
    for detail in detail_results:
        if isinstance(detail, Exception) or detail is None:
            continue
        by_tmdb_id[detail["tmdb_id"]] = detail

    enriched: list[dict[str, Any]] = []
    for candidate in candidates:
        merged = dict(candidate)
        detail = by_tmdb_id.get(candidate["tmdb_id"])
        if detail is not None:
            merged["title"] = detail.get("title") or merged.get("title")
            merged["release_year"] = detail.get("release_year") or merged.get("release_year")
            merged["poster_url"] = detail.get("poster_url") or merged.get("poster_url")
            attrs = dict(candidate.get("attributes", {}))
            attrs.update(detail.get("attributes", {}))
            merged["attributes"] = attrs
        enriched.append(merged)
    return enriched


def upsert_tmdb_media(db: Session, candidates: list[dict[str, Any]]) -> list[MediaItem]:
    """Upsert TMDB candidates into local media_items cache."""
    persisted_rows: list[MediaItem] = []
    for candidate in candidates:
        tmdb_id = candidate.get("tmdb_id")
        title = candidate.get("title")
        if not tmdb_id or not title:
            continue

        attributes = normalize_attributes(
            candidate.get("attributes", {}),
            MediaTypeEnum.MOVIE,
        )

        insert_stmt = (
            pg_insert(MediaItem)
            .values(
                media_type=MediaTypeEnum.MOVIE.value,
                title=normalize_title(title),
                release_year=candidate.get("release_year"),
                tmdb_id=tmdb_id,
                attributes=attributes,
                is_verified=True,
                is_user_generated=False,
            )
            .on_conflict_do_update(
                index_elements=[MediaItem.tmdb_id],
                index_where=(MediaItem.media_type == MediaTypeEnum.MOVIE.value),
                set_={
                    "title": normalize_title(title),
                    "release_year": candidate.get("release_year"),
                    "attributes": attributes,
                    "is_verified": True,
                    "is_user_generated": False,
                },
            )
            .returning(MediaItem.id)
        )

        media_id = db.execute(insert_stmt).scalar_one()
        row = db.query(MediaItem).filter(MediaItem.id == media_id).first()
        if row is not None:
            persisted_rows.append(row)

    db.flush()
    return persisted_rows


def merge_dedup_results(local_rows: list[MediaItem], cached_rows: list[MediaItem]) -> list[MediaItem]:
    """Merge local + cached rows while preserving order and removing duplicates."""
    merged: list[MediaItem] = []
    seen_ids: set[UUID] = set()
    seen_tmdb_ids: set[int] = set()

    for row in [*local_rows, *cached_rows]:
        if row.id in seen_ids:
            continue
        if row.tmdb_id is not None and row.tmdb_id in seen_tmdb_ids:
            continue

        merged.append(row)
        seen_ids.add(row.id)
        if row.tmdb_id is not None:
            seen_tmdb_ids.add(row.tmdb_id)

    return merged


async def search_media_hybrid(
    db: Session,
    q: str,
    media_type: MediaTypeEnum | None,
    limit: int,
    offset: int,
) -> tuple[list[MediaItem], str]:
    """
    Search local first, fallback to TMDB + cache upsert when local recall is low.

    Returns:
      (media_rows, source_tag)
    """
    preload_limit = max(limit + offset, TMDB_FALLBACK_THRESHOLD)
    local_rows = search_local_media(db, q, media_type, preload_limit, 0)

    # PLAY cannot be enriched from TMDB movie endpoints.
    if media_type == MediaTypeEnum.PLAY:
        return local_rows[offset:offset + limit], "db_only"

    if len(local_rows) >= TMDB_FALLBACK_THRESHOLD:
        return local_rows[offset:offset + limit], "db_only"

    try:
        candidates = await fetch_tmdb_candidates(q)
        if not candidates:
            return local_rows[offset:offset + limit], "db_only"

        enriched = await enrich_tmdb_candidates(candidates)
        cached_rows = upsert_tmdb_media(db, enriched)
        db.commit()
    except TMDBConfigError:
        db.rollback()
        return local_rows[offset:offset + limit], "db_only"
    except TMDBUpstreamError:
        db.rollback()
        return local_rows[offset:offset + limit], "db_only"
    except IntegrityError as exc:
        db.rollback()
        raise InvalidMediaPayloadError("TMDB cache upsert failed") from exc

    merged_rows = merge_dedup_results(local_rows, cached_rows)
    source = "tmdb_only" if not local_rows and merged_rows else "db_plus_tmdb"
    return merged_rows[offset:offset + limit], source


def get_media_by_id(db: Session, media_id: UUID) -> MediaItem | None:
    """Fetch one media item by UUID."""
    return db.query(MediaItem).filter(MediaItem.id == media_id).first()


def create_manual_stub(
    db: Session,
    user_id: UUID,
    payload: CreateMediaStubRequest,
) -> MediaItem:
    """Create a manual media entry owned by the authenticated user."""
    validate_media_type_payload(payload)

    normalized_title = normalize_title(payload.title)
    normalized_attrs = normalize_attributes(payload.attributes, payload.media_type)
    tmdb_id = payload.tmdb_id if payload.media_type == MediaTypeEnum.MOVIE else None

    row = MediaItem(
        title=normalized_title,
        release_year=payload.release_year,
        media_type=payload.media_type.value,
        tmdb_id=tmdb_id,
        attributes=normalized_attrs,
        is_verified=False,
        is_user_generated=True,
        created_by_user_id=user_id,
    )
    db.add(row)

    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        error_text = str(exc.orig).lower()
        if "uq_media_items_manual_owner_title_year" in error_text or "duplicate key" in error_text:
            raise DuplicateManualMediaError(
                "A similar media item already exists for this user"
            ) from exc
        raise InvalidMediaPayloadError("Manual media creation failed") from exc

    db.commit()
    db.refresh(row)
    return row


def map_media_response(row: MediaItem) -> MediaItemDetailResponse:
    """Serialize ORM media row to a typed API response model."""
    return MediaItemDetailResponse(
        id=row.id,
        title=row.title,
        release_year=row.release_year,
        media_type=_media_type_value(row.media_type),
        tmdb_id=row.tmdb_id,
        attributes=row.attributes or {},
        is_verified=bool(row.is_verified),
        is_user_generated=bool(row.is_user_generated),
        created_by_user_id=row.created_by_user_id,
        created_at=row.created_at,
        updated_at=row.updated_at,
    )
