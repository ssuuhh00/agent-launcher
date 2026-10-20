// agent-launcher: 원격에서 워크스페이스별 Claude Code(remote-control)를 켜고 끄는 MCP 서버
import { readFileSync, writeFileSync, existsSync, appendFileSync, mkdirSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
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
  console.error("config.json이 없습니다. 먼저 scripts/setup-host.ps1 (또는 node scripts/init-config.mjs)를 실행하세요.");
  process.exit(1);
}
const config = loadConfig();
if (!config.token) {
  console.error("config.json에 token이 비어 있습니다. 토큰 없이 서버를 열 수 없습니다.");
  process.exit(1);
}

// 서버가 재시작돼도 어떤 에이전트를 켰는지 기억하도록 PID를 파일에 저장
const loadState = () => (existsSync(STATE_PATH) ? readJson(STATE_PATH) : {});
const saveState = (state) => writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

mkdirSync(LOG_DIR, { recursive: true });
function log(...args) {
  const line = [new Date().toISOString(), ...args.map((a) => (a instanceof Error ? a.stack : String(a)))].join(" ");
  console.log(line);
  appendFileSync(path.join(LOG_DIR, "server.log"), line + "\n");
}

// PID가 살아 있고, 그게 정말 claude.exe인지 확인 (PID 재사용 대비)
async function isClaudeAlive(pid) {
  if (!pid) return false;
  try {
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

const quote = (s) => `"${String(s).replace(/"/g, '\\"')}"`;

// 새 콘솔 창에서 claude remote-control 실행. Start-Process -PassThru로 실제 claude.exe PID를 받는다.
// 경로·인자는 환경변수로 넘겨서 PowerShell 따옴표 문제를 피함
async function launchClaude(cwd, args) {
  const script =
    "$p = Start-Process -FilePath $env:AL_EXE -ArgumentList $env:AL_ARGS " +
    "-WorkingDirectory $env:AL_CWD -PassThru; $p.Id";
  const { stdout } = await run("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
    env: {
      ...process.env,
      AL_EXE: config.claudePath || "claude.exe",
      AL_ARGS: args.map(quote).join(" "),
      AL_CWD: cwd,
    },
  });
  const pid = Number.parseInt(stdout.trim(), 10);
  if (!Number.isFinite(pid)) throw new Error(`PID를 얻지 못했습니다: ${stdout}`);
  return pid;
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
          .describe("true면 이 폴더에서 최근(약 4시간 이내) 쓰던 세션에 다시 붙습니다. 기본은 새 세션"),
      },
    },
    async ({ workspace, resume }) => {
      const ws = workspaces()[workspace];
      if (!ws) return text(`'${workspace}' 워크스페이스가 없습니다. 가능한 이름: ${Object.keys(workspaces()).join(", ")}`);
      if (!existsSync(ws.path)) return text(`폴더가 없습니다: ${ws.path}`);

      const status = await workspaceStatus(workspace);
      if (status.running) return text({ result: "already_running", workspace, ...status });

      // spawn 모드를 명시하지 않으면 처음 실행 때 [1/2] 선택 질문에서 멈춰 버린다
      const args = ["remote-control", "--name", workspace, "--spawn", ws.spawn || config.spawn || "same-dir"];
      const permissionMode = ws.permissionMode || config.permissionMode;
      if (permissionMode) args.push("--permission-mode", permissionMode);
      if (resume) args.push("--continue");

      const pid = await launchClaude(ws.path, args);
      log(`start ${workspace} pid=${pid} args=${args.join(" ")}`);

      // 바로 죽는 경우(재접속할 세션 없음, 로그인 만료 등)를 잡기 위해 잠깐 기다렸다 확인
      await new Promise((r) => setTimeout(r, 4000));
      if (!(await isClaudeAlive(pid))) {
        return text({
          result: "exited",
          workspace,
          hint: resume
            ? "재접속할 최근 세션이 없었을 수 있습니다. resume 없이 다시 시도해 보세요."
            : "claude가 바로 종료됐습니다. PC에서 해당 폴더로 `claude remote-control`을 직접 실행해 오류를 확인하세요.",
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
      await run("taskkill", ["/PID", String(status.pid), "/T", "/F"]).catch(() => {});
      delete state[workspace];
      saveState(state);
      log(`stop ${workspace} pid=${status.pid}`);
      return text({ result: "stopped", workspace });
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
