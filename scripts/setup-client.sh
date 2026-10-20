#!/usr/bin/env bash
# agent-launcher 클라이언트(맥북 등) 설정: 호스트 PC의 MCP 서버를 Claude Code에 등록한다
#   bash scripts/setup-client.sh [호스트] [토큰] [포트]
set -euo pipefail
NAME="agent-launcher"

command -v claude >/dev/null || { echo "claude(Claude Code)가 설치되어 있지 않습니다."; exit 1; }

HOST="${1:-}"; TOKEN="${2:-}"; PORT="${3:-8765}"
[ -n "$HOST" ] || read -rp "호스트 PC 주소 (Tailscale 기기 이름 또는 100.x.x.x IP): " HOST
[ -n "$TOKEN" ] || { read -rsp "토큰 (호스트 config.json의 token): " TOKEN; echo; }
URL="http://${HOST}:${PORT}/mcp"

echo "연결 확인: $URL"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' || true)

case "$STATUS" in
  200) echo "연결 성공" ;;
  401) echo "토큰이 틀렸습니다."; exit 1 ;;
  000) echo "서버에 닿지 않습니다. 호스트 PC가 켜져 있는지, 양쪽 Tailscale이 연결돼 있는지 확인하세요."; exit 1 ;;
  *)   echo "예상치 못한 응답(HTTP $STATUS)"; exit 1 ;;
esac

claude mcp remove "$NAME" -s user >/dev/null 2>&1 || true
claude mcp add --transport http --scope user "$NAME" "$URL" --header "Authorization: Bearer $TOKEN"
echo "등록 완료. 새 claude 세션을 열고 /mcp 로 확인하세요."
