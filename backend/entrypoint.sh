#!/bin/sh
set -e

echo "Running database migrations..."
if alembic upgrade head; then
  echo "Migrations applied successfully."
else
  echo "WARNING: Migrations failed (check DATABASE_URL). Starting server anyway."
fi

echo "Starting Marquee API on port ${PORT:-8000}..."
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
