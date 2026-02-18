"""
Auth request/response schemas.
"""
import re
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr, field_validator


class SignupRequest(BaseModel):
    """Payload for POST /auth/signup."""

    username: str
    email: EmailStr
    password: str

    @field_validator("username")
    @classmethod
    def validate_username(cls, v: str) -> str:
        v = v.strip()
        if len(v) < 3 or len(v) > 32:
            raise ValueError("Username must be between 3 and 32 characters")
        if not re.match(r"^[a-zA-Z0-9_]+$", v):
            raise ValueError("Username may only contain letters, digits, and underscores")
        return v

    @field_validator("password")
    @classmethod
    def validate_password(cls, v: str) -> str:
        if len(v) < 8:
            raise ValueError("Password must be at least 8 characters")
        return v


class TokenResponse(BaseModel):
    """Returned after successful login."""

    access_token: str
    token_type: str = "bearer"


class UserResponse(BaseModel):
    """Public-facing user profile."""

    id: UUID
    username: str
    email: str

    model_config = ConfigDict(from_attributes=True)
