"""
Discovery service — friend-based recommendations, trending, and genre analysis.

All queries work against existing tables:
  - user_rankings
  - friend_follows (follower_id, following_id)
  - watchlist_items
  - profiles
"""
from collections import Counter, defaultdict
from uuid import UUID

from sqlalchemy import func, text
from sqlalchemy.orm import Session

from app.db.models import Follow, MediaItem, User, UserRanking

# ── Tier numeric mapping ─────────────────────────────────────────────────────

TIER_NUMERIC = {"S": 5, "A": 4, "B": 3, "C": 2, "D": 1}
NUMERIC_TIER = {5: "S", 4: "A", 3: "B", 2: "C", 1: "D"}


def _tier_label(numeric: float) -> str:
    """Map a numeric average back to the nearest tier label."""
    rounded = round(numeric)
    return NUMERIC_TIER.get(max(1, min(5, rounded)), "C")


def _get_following_ids(db: Session, user_id: UUID) -> list[UUID]:
    """Get UUIDs of everyone this user follows."""
    rows = (
        db.query(Follow.following_id)
        .filter(Follow.follower_id == user_id)
        .all()
    )
    return [r[0] for r in rows]


# ── 2.1  Friend Recommendations ──────────────────────────────────────────────


def get_friend_recommendations(
    db: Session,
    user_id: UUID,
    limit: int = 20,
) -> list[dict]:
    """
    Movies friends ranked S or A that this user hasn't ranked or watchlisted.

    Algorithm:
      1. Get all following IDs.
      2. Query their S/A-tier rankings.
      3. Exclude movies the user already ranked or has on their watchlist.
      4. Aggregate by movie: count friends, avg tier, collect avatars.
      5. Sort by friend_count DESC, avg_tier DESC.
    """
    friend_ids = _get_following_ids(db, user_id)
    if not friend_ids:
        return []

    # User's own ranked + watchlisted tmdb_ids (using raw SQL for watchlist
    # since we don't have an ORM model for watchlist_items)
    user_ranked_ids = set(
        r[0]
        for r in db.query(UserRanking.media_item_id)
        .filter(UserRanking.user_id == user_id)
        .all()
    )

    # Also exclude watchlisted items via raw query
    wl_result = db.execute(
        text("SELECT tmdb_id FROM watchlist_items WHERE user_id = :uid"),
        {"uid": str(user_id)},
    )
    user_watchlist_ids = {str(r[0]) for r in wl_result}

    # Friends' S/A tier rankings
    friend_rankings = (
        db.query(UserRanking)
        .filter(
            UserRanking.user_id.in_(friend_ids),
            UserRanking.tier.in_(["S", "A"]),
        )
        .all()
    )

    # Aggregate by media_item_id
    movie_data: dict[str, dict] = defaultdict(lambda: {
        "tiers": [],
        "user_ids": [],
    })

    for ranking in friend_rankings:
        mid = str(ranking.media_item_id)
        # Skip if user already ranked or watchlisted
        if ranking.media_item_id in user_ranked_ids:
            continue
        # For Supabase-style rankings that use tmdb_id directly
        movie_data[mid]["tiers"].append(TIER_NUMERIC.get(ranking.tier, 3))
        movie_data[mid]["user_ids"].append(ranking.user_id)
        if "title" not in movie_data[mid]:
            # Try to get media info
            media = db.query(MediaItem).filter(MediaItem.id == ranking.media_item_id).first()
            if media:
                movie_data[mid]["title"] = media.title
                movie_data[mid]["poster_url"] = (media.attributes or {}).get("poster_url")
                movie_data[mid]["year"] = str(media.release_year) if media.release_year else None
                movie_data[mid]["genres"] = (media.attributes or {}).get("genres", [])

    # Build results
    results = []
    for mid, data in movie_data.items():
        if not data.get("title"):
            continue
        if len(data["tiers"]) == 0:
            continue

        avg_numeric = sum(data["tiers"]) / len(data["tiers"])

        # Get friend profiles
        unique_friends = list(set(data["user_ids"]))[:5]
        profiles = (
            db.query(User)
            .filter(User.id.in_(unique_friends))
            .all()
        )
        avatars = [p.avatar_url or "" for p in profiles if p.avatar_url]
        usernames = [p.username for p in profiles]

        results.append({
            "media_item_id": mid,
            "title": data["title"],
            "poster_url": data.get("poster_url"),
            "year": data.get("year"),
            "genres": data.get("genres", []),
            "avg_tier": _tier_label(avg_numeric),
            "avg_tier_numeric": round(avg_numeric, 1),
            "friend_count": len(set(data["user_ids"])),
            "friend_avatars": avatars,
            "friend_usernames": usernames,
            "top_tier": NUMERIC_TIER.get(max(data["tiers"]), "C"),
        })

    # Sort: most friends first, then highest avg tier
    results.sort(key=lambda r: (-r["friend_count"], -r["avg_tier_numeric"]))
    return results[:limit]


# ── 2.2  Trending Among Friends ──────────────────────────────────────────────


def get_trending_among_friends(
    db: Session,
    user_id: UUID,
    limit: int = 15,
    days: int = 30,
) -> list[dict]:
    """
    Most frequently ranked movies across the user's network in the last N days.

    Groups by movie, counts rankers, computes average tier.
    """
    friend_ids = _get_following_ids(db, user_id)
    if not friend_ids:
        return []

    # Recent rankings from friends
    from datetime import datetime, timedelta, timezone
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)

    recent = (
        db.query(UserRanking)
        .filter(
            UserRanking.user_id.in_(friend_ids),
            UserRanking.updated_at >= cutoff,
        )
        .all()
    )

    # Aggregate by media_item_id
    movie_agg: dict[UUID, dict] = defaultdict(lambda: {
        "tiers": [],
        "ranker_ids": [],
    })

    for ranking in recent:
        mid = ranking.media_item_id
        movie_agg[mid]["tiers"].append(TIER_NUMERIC.get(ranking.tier, 3))
        movie_agg[mid]["ranker_ids"].append(ranking.user_id)

    # Fetch media details and user profiles
    results = []
    for mid, data in movie_agg.items():
        if len(set(data["ranker_ids"])) < 2:
            continue  # Need at least 2 friends

        media = db.query(MediaItem).filter(MediaItem.id == mid).first()
        if not media:
            continue

        avg_numeric = sum(data["tiers"]) / len(data["tiers"])
        unique_rankers = list(set(data["ranker_ids"]))[:5]
        profiles = db.query(User).filter(User.id.in_(unique_rankers)).all()
        ranker_usernames = [p.username for p in profiles]

        results.append({
            "media_item_id": str(mid),
            "title": media.title,
            "poster_url": (media.attributes or {}).get("poster_url"),
            "year": str(media.release_year) if media.release_year else None,
            "genres": (media.attributes or {}).get("genres", []),
            "ranker_count": len(set(data["ranker_ids"])),
            "avg_tier": _tier_label(avg_numeric),
            "avg_tier_numeric": round(avg_numeric, 1),
            "recent_rankers": ranker_usernames,
        })

    results.sort(key=lambda r: (-r["ranker_count"], -r["avg_tier_numeric"]))
    return results[:limit]


# ── 2.3  Genre Taste Profile ─────────────────────────────────────────────────


def get_genre_profile(
    db: Session,
    user_id: UUID,
) -> dict:
    """
    Analyze genre distribution across a user's rankings.

    Returns structured profile with counts, percentages, and avg tier per genre.
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        return {"user_id": str(user_id), "username": "unknown", "total_ranked": 0, "genres": []}

    rankings = (
        db.query(UserRanking)
        .filter(UserRanking.user_id == user_id)
        .all()
    )

    if not rankings:
        return {
            "user_id": str(user_id),
            "username": user.username,
            "total_ranked": 0,
            "genres": [],
        }

    # Collect media items for genre info
    media_ids = [r.media_item_id for r in rankings]
    media_map = {}
    for media in db.query(MediaItem).filter(MediaItem.id.in_(media_ids)).all():
        media_map[media.id] = media

    # Aggregate genres
    genre_tiers: dict[str, list[int]] = defaultdict(list)
    total = len(rankings)

    for ranking in rankings:
        media = media_map.get(ranking.media_item_id)
        if not media:
            continue
        genres = (media.attributes or {}).get("genres", [])
        tier_val = TIER_NUMERIC.get(ranking.tier, 3)
        for genre in genres:
            if genre and isinstance(genre, str):
                genre_tiers[genre.strip()].append(tier_val)

    # Build profile items
    genre_items = []
    for genre, tiers in genre_tiers.items():
        count = len(tiers)
        avg = sum(tiers) / count
        genre_items.append({
            "genre": genre,
            "count": count,
            "percentage": round(count / total * 100, 1) if total > 0 else 0,
            "avg_tier": _tier_label(avg),
            "avg_tier_numeric": round(avg, 1),
        })

    # Sort by count descending
    genre_items.sort(key=lambda g: -g["count"])

    return {
        "user_id": str(user_id),
        "username": user.username,
        "total_ranked": total,
        "genres": genre_items,
    }


def get_genre_comparison(
    db: Session,
    viewer_id: UUID,
    target_id: UUID,
) -> dict:
    """
    Side-by-side genre comparison between viewer and target user.
    """
    viewer_profile = get_genre_profile(db, viewer_id)
    target_profile = get_genre_profile(db, target_id)

    # Find shared top genres (top 5 for each, intersection)
    viewer_top = {g["genre"] for g in viewer_profile["genres"][:5]}
    target_top = {g["genre"] for g in target_profile["genres"][:5]}
    shared = sorted(viewer_top & target_top)

    return {
        "viewer_id": str(viewer_id),
        "viewer_username": viewer_profile["username"],
        "target_id": str(target_id),
        "target_username": target_profile["username"],
        "viewer_genres": viewer_profile["genres"],
        "target_genres": target_profile["genres"],
        "shared_top_genres": shared,
    }
