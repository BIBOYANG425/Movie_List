"""
Auth business logic — signup, login, token issuance.

All DB writes go through this layer (not directly in routes).
"""
from uuid import UUID

from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.security import create_access_token, hash_password, verify_password
from app.db.models import User


# ── Custom exceptions ────────────────────────────────────────────────────────


class DuplicateUserError(Exception):
    """Raised when signup conflicts with an existing username or email."""

    def __init__(self, field: str) -> None:
        self.field = field
        super().__init__(f"A user with that {field} already exists")


# ── Service functions ────────────────────────────────────────────────────────


def create_user(
    db: Session,
    username: str,
    email: str,
    password: str,
) -> User:
    """
    Register a new user.

    - Normalises username (lowercase strip) and email (lowercase strip).
    - Hashes the password with bcrypt.
    - Inserts into DB; raises DuplicateUserError on unique-constraint violation.
    """
    normalised_username = username.strip().lower()
    normalised_email = email.strip().lower()

    user = User(
        username=normalised_username,
        email=normalised_email,
        display_name=normalised_username,
        password_hash=hash_password(password),
    )

    db.add(user)

    try:
        db.flush()  # trigger INSERT; raises on duplicate
    except IntegrityError as exc:
        db.rollback()
        error_str = str(exc.orig).lower()
        if "username" in error_str:
            raise DuplicateUserError("username") from exc
        if "email" in error_str:
            raise DuplicateUserError("email") from exc
        raise DuplicateUserError("username or email") from exc

    db.commit()
    db.refresh(user)
    return user


def authenticate_user(
    db: Session,
    username: str,
    password: str,
) -> User | None:
    """
    Verify credentials and return the User, or None on failure.

    Lookup is case-insensitive (username column is citext in Postgres).
    """
    user = (
        db.query(User)
        .filter(User.username == username.strip().lower())
        .first()
    )
    if user is None:
        return None

    if not verify_password(password, user.password_hash):
        return None

    return user


def issue_access_token(user: User) -> str:
    """Create a signed JWT with the user's ID as the subject claim."""
    return create_access_token(subject=str(user.id))


def get_user_by_id(db: Session, user_id: UUID) -> User | None:
    """Fetch a single user by primary key."""
    return db.query(User).filter(User.id == user_id).first()
