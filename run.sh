#!/bin/sh
# Start Agent Monitor on the same Python runtime Hermes uses (path changes across updates).
PY=$("$HOME/.hermes/hermes-agent/.hermes/bin/hermes" --print-runtime-command | sed -E 's/^\["([^"]+)".*/\1/')
exec "$PY" -I "$(cd "$(dirname "$0")" && pwd)/panel.py"
