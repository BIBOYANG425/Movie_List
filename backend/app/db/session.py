"""
SQLAlchemy engine + session factory.
Import *get_db* as a FastAPI dependency in route handlers.
"""
from collections.abc import Generator

from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import settings

engine = create_engine(
    settings.DATABASE_URL,
    # Health-check connections before handing them to the app
    pool_pre_ping=True,
    # Keep up to 10 persistent connections per worker process
    pool_size=10,
    # Allow up to 20 extra connections under burst load
    max_overflow=20,
    # Log every SQL statement in dev; silence in production
    echo=settings.is_dev,
)

SessionLocal = sessionmaker(
    bind=engine,
    autocommit=False,
    autoflush=False,
    expire_on_commit=False,  # Avoid lazy-load errors after commit
)


def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency that yields a scoped DB session.

    Usage:
        @router.get("/items")
        def list_items(db: Session = Depends(get_db)):
            ...
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
