#!/bin/sh
# Agent Monitor launcher: make sure a healthy panel server is running, then open it in its own window.
PANEL="$HOME/agent-monitor"
PORT="${AGENT_MONITOR_PORT:-8777}"   # another port: a test instance (Agent Bar passes its own)
URL="http://127.0.0.1:$PORT"

healthy() { curl -s -f -o /dev/null --max-time 3 "$URL/api/live"; }

if ! healthy; then
  # a panel process that holds the port but no longer answers: stop it (only our own panel.py)
  for pid in $(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null); do
    if ps -o command= -p "$pid" | grep -q "agent-monitor/panel.py"; then
      kill "$pid" 2>/dev/null
    fi
  done
  i=0
  while [ $i -lt 20 ] && lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; do sleep 0.25; i=$((i + 1)); done
  nohup "$PANEL/run.sh" >"$PANEL/panel.log" 2>&1 &
  i=0
  while [ $i -lt 60 ] && ! healthy; do sleep 0.25; i=$((i + 1)); done
fi

CHROME="/Applications/Google Chrome.app"
if [ -d "$CHROME" ]; then
  open -na "$CHROME" --args --app="$URL/#live" --window-size=1480,980
else
  open "$URL/#live"
fi
