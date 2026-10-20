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
| `start_agent(workspace, resume?)` | 해당 폴더에서 `claude remote-control --name <workspace>` 실행. `resume: true`면 최근(약 4시간 이내) 세션에 다시 붙는다 |
| `stop_agent(workspace)` | 켠 에이전트를 종료 |

## 동작 방식

- **전송 방식**: MCP의 Streamable HTTP를 **stateless**로 쓴다. 요청마다 서버와 트랜스포트 객체를 새로 만들기 때문에 세션 상태를 관리할 필요가 없다.
- **에이전트 실행**: `Start-Process -PassThru`로 새 콘솔 창에서 `claude.exe`를 띄우고, **실제 PID**를 받아 `state.json`에 저장한다. 서버가 재시작돼도 무엇을 켰는지 기억한다.
- **살아 있는지 확인**: PID가 존재하는지에 더해 프로세스 이름이 `claude.exe`인지도 확인한다. Windows는 PID를 재사용하기 때문이다.
- **실패 감지**: 실행하고 4초 뒤에도 살아 있는지 확인한다. 재접속할 세션이 없거나 로그인이 만료된 경우를 잡아서 이유를 돌려준다.
- **허용 목록**: `config.json`에 등록한 폴더만 켤 수 있다. 원격에서 임의의 경로나 명령을 넘길 수 없다.
- **인자 전달**: 경로와 인자는 환경변수로 PowerShell에 넘긴다. 따옴표나 한글 경로 때문에 생기는 문제와 명령 주입을 피하기 위해서다.

## 설치

### 호스트 (명령을 받아 에이전트를 켜는 Windows PC)

준비물: Node.js 18+, [Claude Code](https://claude.com/claude-code) (로그인 완료), [Tailscale](https://tailscale.com/download)

```powershell
git clone https://github.com/<you>/agent-launcher.git
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

`workspaces`는 서버를 재시작하지 않아도 바로 반영된다. 각 폴더는 미리 한 번 `claude`로 열어서 폴더 신뢰(trust)를 승인해 둬야 한다.

### 클라이언트 (맥북 등 요청을 보내는 기기)

준비물: Claude Code, Tailscale (호스트와 같은 계정으로 로그인)

```bash
git clone https://github.com/<you>/agent-launcher.git
cd agent-launcher
bash scripts/setup-client.sh
```

호스트 주소(Tailscale 기기 이름)와 토큰을 입력하면, 연결을 확인한 뒤 `claude mcp add`로 등록한다.
그다음 Claude Code에서 이렇게 말하면 된다.

> 집 PC 졸업논문 에이전트 켜줘

## 보안

- 서버는 **Bearer 토큰** 없이는 응답하지 않는다. 토큰 비교는 `timingSafeEqual`로 한다.
- 방화벽은 Tailscale 대역에서 오는 접속만 허용한다. 공용 인터넷에 포트를 열지 않는다.
- 원격에서 할 수 있는 일은 **등록된 폴더에서 Claude Code를 켜고 끄는 것뿐**이다. 실제 작업은 Claude 계정 인증을 거친 Remote Control 세션 안에서 이뤄진다.
- `config.json`(토큰)과 `state.json`은 `.gitignore`에 들어 있다.

## 한계

- 호스트는 Windows 전용이다 (`Start-Process`, `tasklist`, `taskkill` 사용).
- 호스트 PC가 꺼져 있거나 절전 중이면 동작하지 않는다.
- 맥북을 뺀 다른 클라이언트 OS의 등록 스크립트는 아직 없다. `claude mcp add` 명령을 직접 실행하면 된다.

## License

MIT
