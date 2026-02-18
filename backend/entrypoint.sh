#!/bin/sh
set -e

if [ "${SKIP_MIGRATIONS}" = "true" ]; then
  echo "SKIP_MIGRATIONS set, skipping alembic."
else
  echo "Running database migrations (60s timeout)..."
  if timeout 60 alembic upgrade head; then
    echo "Migrations applied successfully."
  else
    echo "WARNING: Migrations failed or timed out (check DATABASE_URL). Starting server anyway."
  fi
fi

echo "Starting Marquee API on port ${PORT:-8000}..."
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}"
