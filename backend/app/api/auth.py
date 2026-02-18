"""
Auth API — /auth
─────────────────
Endpoints:
  POST /auth/signup   — Create account, return user profile (201)
  POST /auth/login    — Authenticate, return JWT
  GET  /auth/me       — Return current user profile (requires bearer token)
"""
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session

from app.db.models import User
from app.db.session import get_db
from app.deps.auth import get_current_user
from app.schemas.auth import SignupRequest, TokenResponse, UserResponse
from app.services.auth_service import (
    DuplicateUserError,
    authenticate_user,
    create_user,
    issue_access_token,
)

router = APIRouter()


# ── Routes ────────────────────────────────────────────────────────────────────


@router.post(
    "/signup",
    response_model=UserResponse,
    status_code=status.HTTP_201_CREATED,
)
def signup(payload: SignupRequest, db: Session = Depends(get_db)) -> UserResponse:
    """
    Create a new user account.

    Returns 201 + user profile on success.
    Returns 409 if the username or email already exists.
    """
    try:
        user = create_user(
            db,
            username=payload.username,
            email=payload.email,
            password=payload.password,
        )
    except DuplicateUserError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "error": {
                    "code": "DUPLICATE_USER",
                    "message": str(exc),
                }
            },
        ) from exc

    return UserResponse.model_validate(user)


@router.post("/login", response_model=TokenResponse)
def login(
    form: OAuth2PasswordRequestForm = Depends(),
    db: Session = Depends(get_db),
) -> TokenResponse:
    """
    Authenticate with username + password, return a JWT.

    Uses OAuth2 password form so the Swagger /docs Authorize button works
    out of the box.
    """
    user = authenticate_user(db, username=form.username, password=form.password)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error": {
                    "code": "INVALID_CREDENTIALS",
                    "message": "Incorrect username or password",
                }
            },
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = issue_access_token(user)
    return TokenResponse(access_token=token)


@router.get("/me", response_model=UserResponse)
def me(current_user: User = Depends(get_current_user)) -> UserResponse:
    """Return the authenticated user's profile."""
    return UserResponse.model_validate(current_user)
