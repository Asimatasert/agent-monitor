#!/bin/sh
# Agent Monitor MCP server (stdio) on the same Python runtime Hermes uses (it ships the mcp package).
PY=$("$HOME/.hermes/hermes-agent/.hermes/bin/hermes" --print-runtime-command | sed -E 's/^\["([^"]+)".*/\1/')
exec "$PY" -I "$(cd "$(dirname "$0")" && pwd)/mcp_server.py"
