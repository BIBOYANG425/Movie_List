"""
Shared watchlist business logic.
"""
from uuid import UUID

from sqlalchemy import func
from sqlalchemy.orm import Session

from app.db.models import (
    Follow,
    MediaItem,
    SharedWatchlist,
    SharedWatchlistItem,
    SharedWatchlistMember,
    SharedWatchlistVote,
    User,
)


class WatchlistNotFoundError(Exception):
    pass


class NotWatchlistMemberError(Exception):
    pass


class NotWatchlistOwnerError(Exception):
    pass


class AlreadyMemberError(Exception):
    pass


class ItemAlreadyExistsError(Exception):
    pass


def _avatar_url(user: User) -> str:
    from app.services.social_service import _avatar_from_user
    return _avatar_from_user(user)


def _get_watchlist_or_raise(db: Session, watchlist_id: UUID) -> SharedWatchlist:
    wl = db.query(SharedWatchlist).filter(SharedWatchlist.id == watchlist_id).first()
    if not wl:
        raise WatchlistNotFoundError(f"Watchlist {watchlist_id} not found")
    return wl


def _assert_member(db: Session, watchlist_id: UUID, user_id: UUID) -> None:
    member = (
        db.query(SharedWatchlistMember)
        .filter(
            SharedWatchlistMember.watchlist_id == watchlist_id,
            SharedWatchlistMember.user_id == user_id,
        )
        .first()
    )
    if not member:
        raise NotWatchlistMemberError("You are not a member of this watchlist")


def create_shared_watchlist(
    db: Session,
    user_id: UUID,
    name: str = "Movie Night",
) -> dict:
    """Create a shared watchlist and add creator as first member."""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise ValueError("User not found")

    wl = SharedWatchlist(name=name, created_by=user_id)
    db.add(wl)
    db.flush()

    # Add creator as member
    member = SharedWatchlistMember(watchlist_id=wl.id, user_id=user_id)
    db.add(member)
    db.commit()
    db.refresh(wl)

    return {
        "id": wl.id,
        "name": wl.name,
        "created_by": wl.created_by,
        "creator_username": user.username,
        "member_count": 1,
        "item_count": 0,
        "created_at": wl.created_at,
    }


def list_my_shared_watchlists(
    db: Session,
    user_id: UUID,
) -> list[dict]:
    """List all shared watchlists the user belongs to."""
    memberships = (
        db.query(SharedWatchlistMember.watchlist_id)
        .filter(SharedWatchlistMember.user_id == user_id)
        .all()
    )
    wl_ids = [m.watchlist_id for m in memberships]
    if not wl_ids:
        return []

    watchlists = (
        db.query(SharedWatchlist, User)
        .join(User, SharedWatchlist.created_by == User.id)
        .filter(SharedWatchlist.id.in_(wl_ids))
        .order_by(SharedWatchlist.created_at.desc())
        .all()
    )

    results = []
    for wl, creator in watchlists:
        member_count = (
            db.query(func.count(SharedWatchlistMember.user_id))
            .filter(SharedWatchlistMember.watchlist_id == wl.id)
            .scalar()
        )
        item_count = (
            db.query(func.count(SharedWatchlistItem.id))
            .filter(SharedWatchlistItem.watchlist_id == wl.id)
            .scalar()
        )
        results.append({
            "id": wl.id,
            "name": wl.name,
            "created_by": wl.created_by,
            "creator_username": creator.username,
            "member_count": member_count,
            "item_count": item_count,
            "created_at": wl.created_at,
        })

    return results


def get_shared_watchlist_detail(
    db: Session,
    watchlist_id: UUID,
    viewer_id: UUID,
) -> dict:
    """Get full watchlist detail with members and items."""
    wl = _get_watchlist_or_raise(db, watchlist_id)
    _assert_member(db, watchlist_id, viewer_id)

    creator = db.query(User).filter(User.id == wl.created_by).first()

    # Members
    member_rows = (
        db.query(SharedWatchlistMember, User)
        .join(User, SharedWatchlistMember.user_id == User.id)
        .filter(SharedWatchlistMember.watchlist_id == watchlist_id)
        .order_by(SharedWatchlistMember.joined_at.asc())
        .all()
    )
    members = [
        {
            "user_id": user.id,
            "username": user.username,
            "display_name": user.display_name,
            "avatar_url": _avatar_url(user),
            "joined_at": mem.joined_at,
        }
        for mem, user in member_rows
    ]

    # Items with vote info
    item_rows = (
        db.query(SharedWatchlistItem, MediaItem, User)
        .join(MediaItem, SharedWatchlistItem.media_item_id == MediaItem.id)
        .join(User, SharedWatchlistItem.added_by == User.id)
        .filter(SharedWatchlistItem.watchlist_id == watchlist_id)
        .order_by(SharedWatchlistItem.vote_count.desc(), SharedWatchlistItem.added_at.desc())
        .all()
    )

    # Get viewer's votes
    viewer_votes = {
        v.item_id
        for v in db.query(SharedWatchlistVote.item_id)
        .filter(SharedWatchlistVote.user_id == viewer_id)
        .all()
    }

    items = []
    for item, media, added_by_user in item_rows:
        poster_url = None
        attrs = media.attributes or {}
        if isinstance(attrs, dict):
            poster_url = attrs.get("poster_url")

        items.append({
            "id": item.id,
            "media_item_id": media.id,
            "media_title": media.title,
            "poster_url": poster_url,
            "release_year": media.release_year,
            "added_by_username": added_by_user.username,
            "vote_count": item.vote_count,
            "viewer_has_voted": item.id in viewer_votes,
            "added_at": item.added_at,
        })

    return {
        "id": wl.id,
        "name": wl.name,
        "created_by": wl.created_by,
        "creator_username": creator.username if creator else "unknown",
        "member_count": len(members),
        "item_count": len(items),
        "created_at": wl.created_at,
        "members": members,
        "items": items,
    }


def add_member(
    db: Session,
    watchlist_id: UUID,
    requester_id: UUID,
    target_user_id: UUID,
) -> dict:
    """Add a member to a shared watchlist. Only existing members can invite."""
    _get_watchlist_or_raise(db, watchlist_id)
    _assert_member(db, watchlist_id, requester_id)

    target = db.query(User).filter(User.id == target_user_id, User.is_active.is_(True)).first()
    if not target:
        raise ValueError("User not found")

    existing = (
        db.query(SharedWatchlistMember)
        .filter(
            SharedWatchlistMember.watchlist_id == watchlist_id,
            SharedWatchlistMember.user_id == target_user_id,
        )
        .first()
    )
    if existing:
        raise AlreadyMemberError("User is already a member")

    member = SharedWatchlistMember(watchlist_id=watchlist_id, user_id=target_user_id)
    db.add(member)
    db.commit()
    db.refresh(member)

    return {
        "user_id": target.id,
        "username": target.username,
        "display_name": target.display_name,
        "avatar_url": _avatar_url(target),
        "joined_at": member.joined_at,
    }


def add_item(
    db: Session,
    watchlist_id: UUID,
    user_id: UUID,
    media_item_id: UUID,
) -> dict:
    """Add a movie to the shared watchlist."""
    _get_watchlist_or_raise(db, watchlist_id)
    _assert_member(db, watchlist_id, user_id)

    media = db.query(MediaItem).filter(MediaItem.id == media_item_id).first()
    if not media:
        raise ValueError("Movie not found")

    existing = (
        db.query(SharedWatchlistItem)
        .filter(
            SharedWatchlistItem.watchlist_id == watchlist_id,
            SharedWatchlistItem.media_item_id == media_item_id,
        )
        .first()
    )
    if existing:
        raise ItemAlreadyExistsError("Movie already in this watchlist")

    user = db.query(User).filter(User.id == user_id).first()

    item = SharedWatchlistItem(
        watchlist_id=watchlist_id,
        media_item_id=media_item_id,
        added_by=user_id,
    )
    db.add(item)
    db.commit()
    db.refresh(item)

    poster_url = None
    attrs = media.attributes or {}
    if isinstance(attrs, dict):
        poster_url = attrs.get("poster_url")

    return {
        "id": item.id,
        "media_item_id": media.id,
        "media_title": media.title,
        "poster_url": poster_url,
        "release_year": media.release_year,
        "added_by_username": user.username if user else "unknown",
        "vote_count": 0,
        "viewer_has_voted": False,
        "added_at": item.added_at,
    }


def toggle_vote(
    db: Session,
    watchlist_id: UUID,
    item_id: UUID,
    user_id: UUID,
) -> dict:
    """Vote or unvote for an item in a shared watchlist."""
    _get_watchlist_or_raise(db, watchlist_id)
    _assert_member(db, watchlist_id, user_id)

    item = db.query(SharedWatchlistItem).filter(SharedWatchlistItem.id == item_id).first()
    if not item or item.watchlist_id != watchlist_id:
        raise ValueError("Item not found in this watchlist")

    existing = (
        db.query(SharedWatchlistVote)
        .filter(SharedWatchlistVote.item_id == item_id, SharedWatchlistVote.user_id == user_id)
        .first()
    )

    if existing:
        db.delete(existing)
        item.vote_count = max(0, item.vote_count - 1)
        has_voted = False
    else:
        vote = SharedWatchlistVote(item_id=item_id, user_id=user_id)
        db.add(vote)
        item.vote_count += 1
        has_voted = True

    db.add(item)
    db.commit()
    db.refresh(item)

    return {
        "item_id": item_id,
        "vote_count": item.vote_count,
        "viewer_has_voted": has_voted,
    }


def delete_shared_watchlist(
    db: Session,
    watchlist_id: UUID,
    user_id: UUID,
) -> bool:
    """Delete a shared watchlist. Only the creator can delete."""
    wl = _get_watchlist_or_raise(db, watchlist_id)
    if wl.created_by != user_id:
        raise NotWatchlistOwnerError("Only the creator can delete this watchlist")

    db.delete(wl)
    db.commit()
    return True
