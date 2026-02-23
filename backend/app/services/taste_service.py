"""
Taste compatibility computation service.

Computes how similar two users' movie tastes are based on:
1. Shared movies (both ranked the same movie)
2. Tier agreement: same tier = 100%, ±1 tier = 50%, ±2+ = 0%
3. Overall score = weighted average of individual match scores
"""
from uuid import UUID

from sqlalchemy import case, func
from sqlalchemy.orm import Session

from app.db.models import Follow, MediaItem, User, UserRanking, TierEnum


# Tier numeric values for computing distance
TIER_VALUES = {
    TierEnum.S: 5,
    TierEnum.A: 4,
    TierEnum.B: 3,
    TierEnum.C: 2,
    TierEnum.D: 1,
    # Handle string values too
    "S": 5,
    "A": 4,
    "B": 3,
    "C": 2,
    "D": 1,
}


def _tier_value(tier) -> int:
    if hasattr(tier, "value"):
        return TIER_VALUES.get(tier.value, 3)
    return TIER_VALUES.get(str(tier), 3)


def _tier_str(tier) -> str:
    if hasattr(tier, "value"):
        return tier.value
    return str(tier)


def _avatar_url(user: User) -> str:
    from app.services.social_service import _avatar_from_user
    return _avatar_from_user(user)


def compute_taste_compatibility(
    db: Session,
    viewer_id: UUID,
    target_id: UUID,
) -> dict:
    """
    Compute a 0-100 taste compatibility score between two users.

    Algorithm:
    - Find all movies both users have ranked
    - For each shared movie, compute tier distance (0=same, 1=adjacent, 2+=divergent)
    - Score per movie: same tier = 100, ±1 = 60, ±2 = 20, ±3+ = 0
    - Overall score = average of per-movie scores
    """
    from app.services.social_service import _active_user_or_raise

    target = _active_user_or_raise(db, target_id)

    # Get both users' rankings joined by media_item_id
    viewer_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == viewer_id).all()
    }
    target_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == target_id).all()
    }

    # Find shared media
    shared_ids = set(viewer_rankings.keys()) & set(target_rankings.keys())

    if not shared_ids:
        return {
            "target_user_id": target.id,
            "target_username": target.username,
            "score": 0,
            "shared_count": 0,
            "agreements": 0,
            "near_agreements": 0,
            "disagreements": 0,
            "top_shared": [],
            "biggest_divergences": [],
        }

    # Fetch media info for shared items
    media_map = {
        m.id: m
        for m in db.query(MediaItem).filter(MediaItem.id.in_(shared_ids)).all()
    }

    agreements = 0
    near_agreements = 0
    disagreements = 0
    scores = []
    shared_items = []

    for mid in shared_ids:
        vr = viewer_rankings[mid]
        tr = target_rankings[mid]
        media = media_map.get(mid)
        if not media:
            continue

        v_tier = _tier_value(vr.tier)
        t_tier = _tier_value(tr.tier)
        distance = abs(v_tier - t_tier)

        if distance == 0:
            agreements += 1
            item_score = 100
        elif distance == 1:
            near_agreements += 1
            item_score = 60
        elif distance == 2:
            disagreements += 1
            item_score = 20
        else:
            disagreements += 1
            item_score = 0

        scores.append(item_score)

        poster_url = None
        attrs = media.attributes or {}
        if isinstance(attrs, dict):
            poster_url = attrs.get("poster_url") or attrs.get("poster_path")
        if not poster_url and media.tmdb_id:
            poster_url = f"https://image.tmdb.org/t/p/w500/{media.tmdb_id}"

        shared_items.append({
            "media_item_id": media.id,
            "media_title": media.title,
            "poster_url": poster_url,
            "viewer_tier": _tier_str(vr.tier),
            "viewer_score": float(vr.visual_score),
            "target_tier": _tier_str(tr.tier),
            "target_score": float(tr.visual_score),
            "tier_difference": v_tier - t_tier,
            "_distance": distance,
        })

    overall_score = round(sum(scores) / len(scores)) if scores else 0

    # Sort for top shared (both rated highly, same tier)
    top_shared = sorted(
        [s for s in shared_items if s["_distance"] == 0],
        key=lambda x: -TIER_VALUES.get(x["viewer_tier"], 0),
    )[:5]

    # Sort for biggest divergences
    biggest_divergences = sorted(
        shared_items,
        key=lambda x: -x["_distance"],
    )[:5]

    # Clean up internal fields
    for item in top_shared + biggest_divergences:
        item.pop("_distance", None)

    return {
        "target_user_id": target.id,
        "target_username": target.username,
        "score": overall_score,
        "shared_count": len(shared_ids),
        "agreements": agreements,
        "near_agreements": near_agreements,
        "disagreements": disagreements,
        "top_shared": top_shared,
        "biggest_divergences": biggest_divergences,
    }


def get_shared_movies(
    db: Session,
    viewer_id: UUID,
    target_id: UUID,
    limit: int = 50,
    offset: int = 0,
) -> dict:
    """Return paginated list of movies both users have ranked."""
    viewer_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == viewer_id).all()
    }
    target_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == target_id).all()
    }

    shared_ids = sorted(set(viewer_rankings.keys()) & set(target_rankings.keys()))
    total = len(shared_ids)

    page_ids = shared_ids[offset : offset + limit]
    if not page_ids:
        return {"movies": [], "total": total}

    media_map = {
        m.id: m
        for m in db.query(MediaItem).filter(MediaItem.id.in_(page_ids)).all()
    }

    movies = []
    for mid in page_ids:
        vr = viewer_rankings[mid]
        tr = target_rankings[mid]
        media = media_map.get(mid)
        if not media:
            continue

        poster_url = None
        attrs = media.attributes or {}
        if isinstance(attrs, dict):
            poster_url = attrs.get("poster_url")

        movies.append({
            "media_item_id": media.id,
            "media_title": media.title,
            "poster_url": poster_url,
            "viewer_tier": _tier_str(vr.tier),
            "viewer_score": float(vr.visual_score),
            "target_tier": _tier_str(tr.tier),
            "target_score": float(tr.visual_score),
            "tier_difference": _tier_value(vr.tier) - _tier_value(tr.tier),
        })

    return {"movies": movies, "total": total}


def get_ranking_comparison(
    db: Session,
    viewer_id: UUID,
    target_id: UUID,
) -> dict:
    """Return full ranking comparison — all items from both users."""
    from app.services.social_service import _active_user_or_raise

    target = _active_user_or_raise(db, target_id)

    viewer_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == viewer_id).all()
    }
    target_rankings = {
        r.media_item_id: r
        for r in db.query(UserRanking).filter(UserRanking.user_id == target_id).all()
    }

    all_ids = set(viewer_rankings.keys()) | set(target_rankings.keys())
    shared_ids = set(viewer_rankings.keys()) & set(target_rankings.keys())

    if not all_ids:
        return {
            "target_user_id": target.id,
            "target_username": target.username,
            "viewer_total": 0,
            "target_total": 0,
            "shared_count": 0,
            "items": [],
        }

    media_map = {
        m.id: m
        for m in db.query(MediaItem).filter(MediaItem.id.in_(all_ids)).all()
    }

    items = []
    for mid in all_ids:
        media = media_map.get(mid)
        if not media:
            continue

        vr = viewer_rankings.get(mid)
        tr = target_rankings.get(mid)

        poster_url = None
        attrs = media.attributes or {}
        if isinstance(attrs, dict):
            poster_url = attrs.get("poster_url")

        items.append({
            "media_item_id": media.id,
            "media_title": media.title,
            "poster_url": poster_url,
            "viewer_tier": _tier_str(vr.tier) if vr else None,
            "viewer_score": float(vr.visual_score) if vr else None,
            "viewer_rank_position": float(vr.rank_position) if vr else None,
            "target_tier": _tier_str(tr.tier) if tr else None,
            "target_score": float(tr.visual_score) if tr else None,
            "target_rank_position": float(tr.rank_position) if tr else None,
            "is_shared": mid in shared_ids,
        })

    # Sort: shared first, then by viewer tier (S first), then by title
    tier_order = {"S": 0, "A": 1, "B": 2, "C": 3, "D": 4, None: 5}
    items.sort(key=lambda x: (
        not x["is_shared"],
        tier_order.get(x["viewer_tier"], 5),
        tier_order.get(x["target_tier"], 5),
        x["media_title"],
    ))

    return {
        "target_user_id": target.id,
        "target_username": target.username,
        "viewer_total": len(viewer_rankings),
        "target_total": len(target_rankings),
        "shared_count": len(shared_ids),
        "items": items,
    }
