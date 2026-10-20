// agent-launcher: 원격에서 워크스페이스별 Claude Code(remote-control)를 켜고 끄는 MCP 서버
import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import express from "express";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

const run = promisify(execFile);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONFIG_PATH = path.join(ROOT, "config.json");
const STATE_PATH = path.join(ROOT, "state.json");
const LOG_DIR = path.join(ROOT, "logs");

// 메모장 등에서 BOM이 붙어 저장돼도 읽히도록 제거
const readJson = (p) => JSON.parse(readFileSync(p, "utf8").replace(/^﻿/, ""));
const loadConfig = () => readJson(CONFIG_PATH);
if (!existsSync(CONFIG_PATH)) {
  console.error("config.json이 없습니다. 먼저 scripts/setup-host.ps1 (macOS는 scripts/setup-host.sh, 또는 node scripts/init-config.mjs)를 실행하세요.");
  process.exit(1);
}
const config = loadConfig();
if (!config.token) {
  console.error("config.json에 token이 비어 있습니다. 토큰 없이 서버를 열 수 없습니다.");
  process.exit(1);
}

// Claude Code 세션 안에서 서버를 띄우면 그 세션 전용 환경변수(NO_COLOR, CLAUDE_CODE_SESSION_ID 등)가 따라온다.
// 그대로 넘기면 켜진 에이전트가 흑백이 되거나 부모 세션의 일부처럼 동작하므로 지운다
const INHERITED_SESSION_ENV = [
  "NO_COLOR",
  "CLAUDECODE",
  "CLAUDE_PID",
  "CLAUDE_CODE_ENTRYPOINT",
  "CLAUDE_CODE_SESSION_ID",
  "CLAUDE_CODE_CHILD_SESSION",
  "CLAUDE_CODE_SESSION_ATTENDED",
  "CLAUDE_CODE_BRIDGE_SESSION_ID",
  "CLAUDE_CODE_MESSAGING_SOCKET",
  "CLAUDE_CODE_MESSAGING_TOKEN",
  "WT_SESSION",
  "WT_PROFILE_ID",
];
for (const key of INHERITED_SESSION_ENV) delete process.env[key];

// 서버가 재시작돼도 어떤 에이전트를 켰는지 기억하도록 PID를 파일에 저장
const loadState = () => (existsSync(STATE_PATH) ? readJson(STATE_PATH) : {});
const saveState = (state) => writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

mkdirSync(LOG_DIR, { recursive: true });
function log(...args) {
  const line = [new Date().toISOString(), ...args.map((a) => (a instanceof Error ? a.stack : String(a)))].join(" ");
  console.log(line);
  appendFileSync(path.join(LOG_DIR, "server.log"), line + "\n");
}

// 호스트는 Windows와 macOS를 지원한다. 켜기·확인·끄기만 OS별로 다르다
const IS_MAC = process.platform === "darwin";

// macOS: 실행 중인 프로세스의 PID와 명령줄
async function listProcesses() {
  const { stdout } = await run("ps", ["-axo", "pid=,command="]);
  return stdout
    .split("\n")
    .map((line) => line.trim().match(/^(\d+)\s+(.*)$/))
    .filter(Boolean)
    .map(([, pid, command]) => ({ pid: Number(pid), command }));
}

// PID가 살아 있고, 그게 정말 claude인지 확인 (PID 재사용 대비)
async function isClaudeAlive(pid) {
  if (!pid) return false;
  try {
    if (IS_MAC) {
      const { stdout } = await run("ps", ["-p", String(pid), "-o", "command="]);
      return path.basename(stdout.trim().split(/\s+/)[0]) === "claude";
    }
    const { stdout } = await run("tasklist", ["/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"]);
    return stdout.toLowerCase().includes("claude.exe");
  } catch {
    return false;
  }
}

async function workspaceStatus(name) {
  const entry = loadState()[name];
  const running = await isClaudeAlive(entry?.pid);
  return { running, pid: running ? entry.pid : null, startedAt: running ? entry.startedAt : null };
}

// claude 실행 파일의 전체 경로 (터미널에 넘길 때 PATH 해석에 기대지 않도록)
// macOS는 launchd로 뜨면 PATH가 짧아서 흔한 설치 위치를 먼저 본다
async function resolveClaude() {
  if (config.claudePath) return config.claudePath;
  if (IS_MAC) {
    const candidates = [path.join(os.homedir(), ".local/bin/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"];
    const found = candidates.find((p) => existsSync(p));
    if (found) return found;
    const { stdout } = await run("which", ["claude"]);
    return stdout.trim();
  }
  const { stdout } = await run("where.exe", ["claude.exe"]);
  return stdout.split(/\r?\n/)[0].trim();
}

// 명령줄에서 이 워크스페이스 이름으로 켠 claude인지 (ai / ai_seminar처럼 겹치는 이름 대비)
const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const launchedAs = (title) => new RegExp(`(--remote-control|--name) "?${escapeRegex(title)}"?(\\s|$)`);

// sh에 넘길 인자를 작은따옴표로 감싼다
const shQuote = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

// macOS 터미널별 AppleScript. argv: 1 = 실행할 셸 명령, 2 = 창 제목
const MAC_TERMINALS = {
  terminal: ['tell application "Terminal"', "set t to do script (item 1 of argv)", "set custom title of t to (item 2 of argv)", "end tell"],
  iterm: [
    'tell application "iTerm"',
    "set w to (create window with default profile)",
    "tell current session of w",
    "set name to (item 2 of argv)",
    "write text (item 1 of argv)",
    "end tell",
    "end tell",
  ],
};

// macOS: 터미널 앱(config.terminal: terminal 기본, iterm) 새 창에서 claude를 띄우고, 새로 생긴 claude의 PID를 찾는다
// 처음 한 번은 "node가 터미널을 제어하려고 합니다" 권한 창이 뜬다
async function launchClaudeMac(cwd, args, title) {
  const before = new Set((await listProcesses()).map((p) => p.pid));
  const command = `cd ${shQuote(cwd)} && exec ${[await resolveClaude(), ...args].map(shQuote).join(" ")}`;
  const terminal = loadConfig().terminal || "terminal";
  if (!MAC_TERMINALS[terminal]) throw new Error(`macOS에서 쓸 수 없는 terminal 값입니다: ${terminal} (terminal 또는 iterm)`);
  const script = ["on run argv", ...MAC_TERMINALS[terminal], "end run"];
  await run("osascript", [...script.flatMap((line) => ["-e", line]), command, title]);
  const pattern = launchedAs(title);
  for (let i = 0; i < 60; i++) {
    await sleep(250);
    const found = (await listProcesses()).find(
      (p) => !before.has(p.pid) && path.basename(p.command.split(/\s+/)[0]) === "claude" && pattern.test(p.command),
    );
    if (found) return found.pid;
  }
  throw new Error("터미널에서 claude 프로세스를 찾지 못했습니다.");
}

// 새 터미널에서 claude를 띄우고 실제 claude.exe PID를 받는다 (scripts/launch-agent.ps1).
// 경로·인자는 환경변수로 넘겨서 PowerShell 따옴표 문제를 피함
async function launchClaude(cwd, args, title) {
  if (IS_MAC) return launchClaudeMac(cwd, args, title);
  const helper = path.join(ROOT, "scripts", "launch-agent.ps1");
  const { stdout } = await run("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper], {
    env: {
      ...process.env,
      AL_EXE: await resolveClaude(),
      AL_ARGS: JSON.stringify(args),
      AL_CWD: cwd,
      AL_TITLE: title,
      AL_TERMINAL: config.terminal || "wt",
    },
  });
  const pid = Number.parseInt(stdout.trim(), 10);
  if (!Number.isFinite(pid)) throw new Error(`PID를 얻지 못했습니다: ${stdout}`);
  return pid;
}

// 폴더 신뢰(trust) 여부. 상위 폴더가 신뢰돼 있으면 하위도 신뢰된다.
// 신뢰 안 된 폴더에서 켜면 확인 창에서 멈춘 채 살아 있어서 started로 잘못 보이므로 미리 막는다
function isTrusted(dir) {
  let projects;
  try {
    projects = readJson(path.join(os.homedir(), ".claude.json")).projects || {};
  } catch {
    return true; // 확인할 수 없으면 막지 않는다
  }
  const norm = (p) => path.resolve(p).replace(/\\/g, "/").toLowerCase();
  const trusted = new Set(Object.entries(projects).filter(([, v]) => v.hasTrustDialogAccepted).map(([k]) => norm(k)));
  for (let d = path.resolve(dir); ; d = path.dirname(d)) {
    if (trusted.has(norm(d))) return true;
    if (path.dirname(d) === d) return false;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 먼저 Ctrl+C로 정상 종료시킨다. 그래야 claude.ai 세션 목록에서도 정리된다.
// taskkill /F로 바로 죽이면 세션이 목록에 idle로 남는다. 10초 안에 안 꺼지면 그때 강제 종료
// macOS는 SIGINT를 두 번 보낸다 (Ctrl+C 두 번과 같음)
async function stopClaude(pid) {
  if (IS_MAC) {
    const interrupt = () => {
      try {
        process.kill(pid, "SIGINT");
      } catch {}
    };
    interrupt();
    await sleep(500);
    interrupt();
  } else {
    const helper = path.join(ROOT, "scripts", "send-ctrl-c.ps1");
    await run("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", helper, String(pid)]).catch(
      () => {},
    );
  }
  for (let i = 0; i < 20; i++) {
    if (!(await isClaudeAlive(pid))) return "graceful";
    await sleep(500);
  }
  if (IS_MAC) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
  } else {
    await run("taskkill", ["/PID", String(pid), "/T", "/F"]).catch(() => {});
  }
  return "forced";
}

const text = (obj) => ({ content: [{ type: "text", text: typeof obj === "string" ? obj : JSON.stringify(obj, null, 2) }] });

function buildServer() {
  const server = new McpServer({ name: "agent-launcher", version: "0.1.0" });
  const workspaces = () => loadConfig().workspaces;

  server.registerTool(
    "list_workspaces",
    {
      title: "워크스페이스 목록",
      description: "이 PC에 등록된 워크스페이스(작업별 에이전트)와 각 에이전트의 실행 여부를 보여줍니다.",
      inputSchema: {},
    },
    async () => {
      const list = [];
      for (const [name, ws] of Object.entries(workspaces())) {
        list.push({ name, description: ws.description, path: ws.path, ...(await workspaceStatus(name)) });
      }
      return text(list);
    },
  );

  server.registerTool(
    "start_agent",
    {
      title: "에이전트 켜기",
      description:
        "지정한 워크스페이스에서 Claude Code를 Remote Control 모드로 켭니다. " +
        "켜진 세션은 claude.ai/code 와 Claude 모바일 앱의 세션 목록에 워크스페이스 이름으로 나타납니다.",
      inputSchema: {
        workspace: z.string().describe("list_workspaces에 나오는 워크스페이스 이름"),
        resume: z
          .boolean()
          .optional()
          .describe("true면 이 폴더에서 가장 최근 대화를 이어서 엽니다. 기본은 새 대화"),
      },
    },
    async ({ workspace, resume }) => {
      const ws = workspaces()[workspace];
      if (!ws) return text(`'${workspace}' 워크스페이스가 없습니다. 가능한 이름: ${Object.keys(workspaces()).join(", ")}`);
      if (!existsSync(ws.path)) return text(`폴더가 없습니다: ${ws.path}`);
      if (!isTrusted(ws.path)) {
        return text({
          result: "needs_trust",
          workspace,
          hint: `이 폴더는 아직 신뢰되지 않았습니다. PC에서 '${ws.path}'로 이동해 claude를 한 번 실행하고 신뢰를 승인하세요.`,
        });
      }

      const status = await workspaceStatus(workspace);
      if (status.running) return text({ result: "already_running", workspace, ...status });

      // interactive(기본): 평소 쓰는 대화형 claude에 Remote Control을 켠다. PC 터미널에서도 같은 대화가 보인다
      // server: claude remote-control 서버 모드. 폰/웹에서 세션을 여러 개 만들 수 있지만 터미널엔 QR만 보인다
      const mode = ws.mode || config.mode || "interactive";
      const args =
        mode === "server"
          ? // spawn 모드를 명시하지 않으면 처음 실행 때 [1/2] 선택 질문에서 멈춰 버린다
            ["remote-control", "--name", workspace, "--spawn", ws.spawn || config.spawn || "same-dir"]
          : ["--remote-control", workspace];
      const permissionMode = ws.permissionMode || config.permissionMode;
      if (permissionMode) args.push("--permission-mode", permissionMode);
      if (resume) args.push("--continue");

      const pid = await launchClaude(ws.path, args, workspace);
      log(`start ${workspace} pid=${pid} args=${args.join(" ")}`);

      // 바로 죽는 경우(재접속할 세션 없음, 로그인 만료 등)를 잡기 위해 잠깐 기다렸다 확인
      await sleep(4000);
      if (!(await isClaudeAlive(pid))) {
        return text({
          result: "exited",
          workspace,
          hint: resume
            ? "이어갈 최근 대화가 없었을 수 있습니다. resume 없이 다시 시도해 보세요."
            : `claude가 바로 종료됐습니다. PC에서 해당 폴더로 \`claude ${args.join(" ")}\`를 직접 실행해 오류를 확인하세요.`,
        });
      }

      const state = loadState();
      state[workspace] = { pid, startedAt: new Date().toISOString() };
      saveState(state);
      return text({
        result: "started",
        workspace,
        pid,
        next: `claude.ai/code 또는 Claude 앱의 세션 목록에서 '${workspace}'를 찾아 접속하세요.`,
      });
    },
  );

  server.registerTool(
    "stop_agent",
    {
      title: "에이전트 끄기",
      description: "start_agent로 켠 워크스페이스 에이전트를 종료합니다.",
      inputSchema: { workspace: z.string().describe("종료할 워크스페이스 이름") },
    },
    async ({ workspace }) => {
      const status = await workspaceStatus(workspace);
      const state = loadState();
      if (!status.running) {
        delete state[workspace];
        saveState(state);
        return text({ result: "not_running", workspace });
      }
      const how = await stopClaude(status.pid);
      delete state[workspace];
      saveState(state);
      log(`stop ${workspace} pid=${status.pid} (${how})`);
      return text({ result: "stopped", workspace, how });
    },
  );

  return server;
}

// Bearer 토큰 인증
const expected = Buffer.from(`Bearer ${config.token}`);
function auth(req, res, next) {
  const got = Buffer.from(req.headers.authorization || "");
  if (got.length === expected.length && timingSafeEqual(got, expected)) return next();
  log(`unauthorized request from ${req.ip}`);
  res.status(401).json({ error: "unauthorized" });
}

const app = express();
app.use(express.json());

// 상태 없는(stateless) Streamable HTTP: 요청마다 서버/트랜스포트를 새로 만든다
app.post("/mcp", auth, async (req, res) => {
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (err) {
    log("error", err);
    if (!res.headersSent) {
      res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal server error" }, id: null });
    }
  }
});

const methodNotAllowed = (req, res) =>
  res.status(405).json({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null });
app.get("/mcp", methodNotAllowed);
app.delete("/mcp", methodNotAllowed);

app.listen(config.port, config.host, () => log(`agent-launcher listening on http://${config.host}:${config.port}/mcp`));
