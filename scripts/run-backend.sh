#!/usr/bin/env bash
# Runs the Go backend from source. Loads backend/.env automatically (via
# config.go's loadEnvFile) if present; copy backend/.env.example to
# backend/.env and fill in your API keys first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/backend"

if [[ ! -f .env ]]; then
  echo "warning: backend/.env not found — copy backend/.env.example to backend/.env and add your API keys." >&2
fi

exec go run .
