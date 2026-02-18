"""
Auth dependency — shared across all protected endpoints.

Usage in any route:
    from app.deps.auth import get_current_user
    from app.db.models import User

    @router.get("/protected")
    def protected(user: User = Depends(get_current_user)):
        ...
"""
from uuid import UUID

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.core.security import decode_access_token
from app.db.models import User
from app.db.session import get_db

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")


def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    """
    Decode the bearer JWT and return the corresponding active User.

    Raises 401 on any failure (missing/invalid token, unknown user, inactive).
    """
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired token",
        headers={"WWW-Authenticate": "Bearer"},
    )

    sub = decode_access_token(token)
    if sub is None:
        raise credentials_exception

    # Validate sub is a proper UUID string
    try:
        user_id = UUID(sub)
    except (ValueError, AttributeError):
        raise credentials_exception

    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise credentials_exception

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Account is deactivated",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return user
