# agent-launcher

> 다른 기기에서 한 마디로, 집 PC의 작업별 Claude Code 에이전트를 깨우는 MCP 서버

작업마다 워크스페이스(졸업논문, 채용 준비 등)를 따로 두고, 각 폴더에서 Claude Code 에이전트가 그 작업의 메모리와 파일을 들고 일하게 쓰고 있다.
문제는 이 에이전트들이 **집 PC에만** 있다는 것.

- 밖에서 맥북으로 일하다 보면 집 PC에만 있는 파일과 컨텍스트가 필요하다.
- SSH로 들어가는 건 번거롭고, 워크스페이스마다 에이전트를 항상 켜 두는 건 낭비다.

그래서 집 PC에는 **가벼운 MCP 서버 하나만** 켜 두고, 필요할 때 원격에서 해당 워크스페이스의 에이전트를 **Remote Control 모드로** 켜도록 만들었다.
켜진 에이전트는 claude.ai/code 와 Claude 모바일 앱에서 바로 이어서 쓸 수 있다.

## 구조

```
 맥북 (클라이언트)                              집 PC (호스트, Windows)
┌──────────────────┐   Tailscale 사설망     ┌────────────────────────────────┐
│ Claude Code      │ ── HTTP + Bearer ────▶ │ agent-launcher (MCP 서버, 상시) │
│  "졸업논문 에이전트 │      토큰               │   start_agent("thesis")         │
│   켜줘"           │                        │        │                        │
└──────────────────┘                        │        ▼ 새 터미널 창             │
                                            │  claude remote-control          │
 폰 / 브라우저                                │   (cwd = 워크스페이스 폴더)       │
┌──────────────────┐   claude.ai 경유        │        │                        │
│ Claude 앱,        │ ◀───────────────────── │  세션이 계정에 등록됨             │
│ claude.ai/code   │                        └────────────────────────────────┘
└──────────────────┘
```

이 레포 하나를 **양쪽 기기에서 모두 clone**해서 쓴다. 호스트는 서버를 돌리고, 클라이언트는 등록 스크립트만 실행한다.

## 제공하는 도구 (MCP tools)

| 도구 | 설명 |
|---|---|
| `list_workspaces` | 등록된 워크스페이스와 각 에이전트의 실행 여부 |
| `start_agent(workspace, resume?)` | 해당 폴더에서 `claude --remote-control <workspace>` 실행. `resume: true`면 그 폴더의 가장 최근 대화를 이어서 연다 |
| `stop_agent(workspace)` | 켠 에이전트를 종료 |

## 동작 방식

- **전송 방식**: MCP의 Streamable HTTP를 **stateless**로 쓴다. 요청마다 서버와 트랜스포트 객체를 새로 만들기 때문에 세션 상태를 관리할 필요가 없다.
- **에이전트 실행**: Windows Terminal의 `agent-launcher` 창에 워크스페이스마다 탭을 열고, 그 안에서 대화형 claude를 Remote Control이 켜진 상태로 띄운다. 맥북이나 폰에서 하던 대화가 PC 터미널에도 그대로 보여서, PC 앞에 오면 그 창에 바로 이어서 입력하면 된다. 실행된 claude.exe의 **실제 PID**는 `state.json`에 저장한다. 서버가 재시작돼도 무엇을 켰는지 기억한다.
- **정상 종료**: 끌 때는 해당 콘솔에 Ctrl+C를 보내서 claude가 스스로 정리하고 끝나게 한다. 10초 안에 안 꺼지면 그때 강제 종료한다.
- **환경 정리**: Claude Code 세션 안에서 서버를 띄우면 `NO_COLOR`, `CLAUDE_CODE_SESSION_ID` 같은 그 세션 전용 변수가 따라온다. 서버가 시작할 때 이런 변수를 지워서, 켜진 에이전트가 깨끗한 환경에서 뜨게 한다.
- **살아 있는지 확인**: PID가 존재하는지에 더해 프로세스 이름이 `claude.exe`인지도 확인한다. Windows는 PID를 재사용하기 때문이다.
- **macOS 호스트**: 터미널 앱 새 창(창 제목 = 워크스페이스 이름)에서 띄우고, `ps`로 새로 생긴 claude의 PID를 찾는다. 끌 때는 SIGINT를 두 번 보내고(Ctrl+C 두 번과 같음), 10초 안에 안 꺼지면 SIGKILL.
- **실패 감지**: 실행하고 4초 뒤에도 살아 있는지 확인한다. 재접속할 세션이 없거나 로그인이 만료된 경우를 잡아서 이유를 돌려준다.
- **허용 목록**: `config.json`에 등록한 폴더만 켤 수 있다. 원격에서 임의의 경로나 명령을 넘길 수 없다.
- **인자 전달**: 경로와 인자는 환경변수로 PowerShell에 넘긴다. 따옴표나 한글 경로 때문에 생기는 문제와 명령 주입을 피하기 위해서다.

## 설치

### 호스트 (명령을 받아 에이전트를 켜는 Windows PC)

준비물: Node.js 18+, [Claude Code](https://claude.com/claude-code) (로그인 완료), [Tailscale](https://tailscale.com/download)

```powershell
git clone https://github.com/ssuuhh00/agent-launcher.git
cd agent-launcher
powershell -ExecutionPolicy Bypass -File scripts\setup-host.ps1
```

스크립트가 하는 일:
1. `npm install`
2. `config.json` 생성 (랜덤 토큰 포함)
3. Windows 방화벽에 **Tailscale 대역(100.64.0.0/10)에서만** 8765 포트 허용
4. 시작프로그램에 등록해서 로그인하면 서버가 최소화 창으로 자동 실행

그다음 `config.json`의 `workspaces`를 내 폴더에 맞게 고친다.

```json
"workspaces": {
  "thesis": { "path": "C:/Users/me/Desktop/thesis", "description": "졸업논문" }
}
```

고를 수 있는 옵션 (전체 또는 워크스페이스별):

| 키 | 값 | 설명 |
|---|---|---|
| `mode` | `interactive`(기본) / `server` | `server`는 `claude remote-control` 서버 모드. 폰에서 세션을 여러 개 만들 수 있지만 터미널에는 QR만 보인다 |
| `terminal` | `wt`(기본) / `console` | Windows Terminal 탭으로 열지, 기본 콘솔 창으로 열지 |
| `permissionMode` | `auto`, `acceptEdits` 등 | 켜지는 세션의 권한 모드 |

`workspaces`는 서버를 재시작하지 않아도 바로 반영된다. 각 폴더는 미리 한 번 `claude`로 열어서 폴더 신뢰(trust)를 승인해 둬야 한다.

### 호스트 (macOS)

맥도 호스트가 될 수 있다. Windows PC에서 맥의 에이전트를 켜는 반대 방향이다.
준비물: Node.js 18+ (`brew install node`), Claude Code (로그인 완료), Tailscale

```bash
git clone https://github.com/ssuuhh00/agent-launcher.git
cd agent-launcher
bash scripts/setup-host.sh
```

스크립트가 하는 일:
1. `npm install`, `config.json` 생성 (랜덤 토큰 포함)
2. 서버를 `0.0.0.0` 대신 **맥의 Tailscale 주소에만** 연다 (`host` 값)
3. macOS 방화벽이 켜져 있으면 node의 접속을 허용한다 (관리자 암호)
4. LaunchAgent(`~/Library/LaunchAgents/com.agent-launcher.plist`)로 등록해서 로그인하면 자동 실행

그다음 `config.json`의 `workspaces`를 맥 폴더로 고친다. 처음 `start_agent` 때 "node가 터미널을 제어하려고 합니다" 창이 뜨면 허용한다.
맥북은 뚜껑을 닫거나 잠자기에 들어가면 요청을 받을 수 없다.

### 클라이언트 (맥북 등 요청을 보내는 기기)

준비물: Claude Code, Tailscale (호스트와 같은 계정으로 로그인)

```bash
git clone https://github.com/ssuuhh00/agent-launcher.git
cd agent-launcher
bash scripts/setup-client.sh
```

호스트 주소(Tailscale 기기 이름)와 토큰을 입력하면, 연결을 확인한 뒤 `claude mcp add`로 등록한다.

Windows PC가 클라이언트일 때(맥 호스트에 붙을 때)는 PowerShell 스크립트를 쓴다. 기본 등록 이름은 `agent-launcher-mac`이라 PC 자신의 런처와 겹치지 않는다.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup-client.ps1 -HostName <맥 Tailscale 주소>
```
그다음 Claude Code에서 이렇게 말하면 된다.

> 집 PC 졸업논문 에이전트 켜줘

## 보안

- 서버는 **Bearer 토큰** 없이는 응답하지 않는다. 토큰 비교는 `timingSafeEqual`로 한다.
- Windows는 방화벽에서 Tailscale 대역에서 오는 접속만 허용하고, macOS는 서버를 Tailscale 주소에만 연다. 공용 인터넷에 포트를 열지 않는다.
- 원격에서 할 수 있는 일은 **등록된 폴더에서 Claude Code를 켜고 끄는 것뿐**이다. 실제 작업은 Claude 계정 인증을 거친 Remote Control 세션 안에서 이뤄진다.
- `config.json`(토큰)과 `state.json`은 `.gitignore`에 들어 있다.

## 한계

- 호스트는 Windows와 macOS만 지원한다. Linux 호스트는 아직 없다.
- 호스트가 꺼져 있거나 절전 중이면 동작하지 않는다.
- 클라이언트 등록 스크립트는 macOS/Linux(`setup-client.sh`)와 Windows(`setup-client.ps1`)용이 있다. 다른 환경은 `claude mcp add` 명령을 직접 실행하면 된다.

## License

MIT
