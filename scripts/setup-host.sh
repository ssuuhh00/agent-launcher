#!/usr/bin/env bash
# agent-launcher 호스트(macOS) 설정
#   bash scripts/setup-host.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LABEL="com.agent-launcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TS="$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"

echo '[1/5] 필수 프로그램 확인'
for cmd in node npm claude; do
  command -v "$cmd" >/dev/null || { echo "$cmd 이(가) 설치되어 있지 않습니다. (node: brew install node)"; exit 1; }
done
[ -x "$TS" ] || { echo "Tailscale이 설치되어 있지 않습니다. https://tailscale.com/download"; exit 1; }
TS_IP="$("$TS" ip -4 2>/dev/null | head -1)"
[ -n "$TS_IP" ] || { echo "Tailscale에 로그인되어 있지 않습니다."; exit 1; }

echo '[2/5] 패키지 설치'
npm install --no-fund --no-audit

echo '[3/5] config.json 준비 (서버는 Tailscale 주소에만 연다)'
node scripts/init-config.mjs
node -e '
const fs = require("fs");
const cfg = JSON.parse(fs.readFileSync("config.json", "utf8"));
if (cfg.host === "0.0.0.0") { cfg.host = process.argv[1]; fs.writeFileSync("config.json", JSON.stringify(cfg, null, 2) + "\n"); }
' "$TS_IP"
PORT="$(node -p "require('./config.json').port")"
TOKEN="$(node -p "require('./config.json').token")"

echo '[4/5] 방화벽'
FW=/usr/libexec/ApplicationFirewall/socketfilterfw
# 방화벽은 실제 실행 파일을, LaunchAgent는 brew 업그레이드에도 안 바뀌는 경로를 쓴다
NODE_REAL="$(node -p 'process.execPath')"
NODE_BIN="$(command -v node)"
if "$FW" --getglobalstate | grep -q enabled; then
  echo "  macOS 방화벽이 켜져 있어서 node의 접속 허용을 추가합니다 (관리자 암호 필요)."
  if ! { sudo "$FW" --add "$NODE_REAL" >/dev/null && sudo "$FW" --unblockapp "$NODE_REAL" >/dev/null; }; then
    echo "  추가하지 못했습니다. 터미널에서 직접 실행하세요: sudo $FW --add $NODE_REAL && sudo $FW --unblockapp $NODE_REAL"
  fi
else
  echo '  macOS 방화벽이 꺼져 있습니다. 서버가 Tailscale 주소에만 열려 있어서 외부에서는 닿지 않습니다.'
fi

echo '[5/5] 로그인 시 자동 실행 등록 (LaunchAgent)'
mkdir -p "$HOME/Library/LaunchAgents" logs
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE_BIN</string><string>$ROOT/src/server.js</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <!-- 로그인 직후 Tailscale 주소가 아직 없으면 실패하므로 다시 띄운다 -->
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$ROOT/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$ROOT/logs/launchd.err.log</string>
</dict>
</plist>
EOF
# 이미 등록돼 있으면 내렸다가 다시 올린다. bootout은 비동기라 완전히 내려갈 때까지 기다린다
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 20); do launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ''
echo '설정 완료. 서버가 지금 켜졌고, 로그인할 때마다 자동으로 켜집니다.'
echo "  끄기: launchctl bootout gui/$(id -u)/$LABEL"
echo ''
echo '클라이언트(Windows PC 등)에서 쓸 정보:'
echo "  호스트: $TS_IP  (또는 Tailscale 기기 이름)"
echo "  포트:   $PORT"
echo "  토큰:   $TOKEN"
echo ''
echo 'config.json의 workspaces를 이 맥의 폴더로 고쳐 주세요. 처음 start_agent 때 "node가 터미널을 제어하려고 합니다" 창이 뜨면 허용하세요.'
echo '맥북이 잠자기에 들어가면 요청을 받을 수 없습니다. 전원을 연결해 두고, 필요하면 시스템 설정 > 배터리에서 잠자기를 막으세요.'
