import http from "node:http";
import crypto from "node:crypto";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { spawn as childSpawn } from "node:child_process";
import { Bonjour } from "bonjour-service";

// ---------------------------------------------------------------------------
// Logging (must be defined before use)
// ---------------------------------------------------------------------------

function log(level, msg, ...args) {
  const ts = new Date().toISOString();
  const prefix = `[${ts}] [${level.toUpperCase()}]`;
  if (args.length) {
    console.log(prefix, msg, ...args);
  } else {
    console.log(prefix, msg);
  }
}

// ---------------------------------------------------------------------------
// Binary discovery
// ---------------------------------------------------------------------------

function findBinary(name, candidates) {
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  try {
    return execSync(`which ${name} 2>/dev/null`, { encoding: "utf-8" }).trim();
  } catch { /* fall through */ }
  return null;
}

const CLAUDE_BIN = findBinary("claude", [
  `${os.homedir()}/.local/bin/claude`,
  "/usr/local/bin/claude",
  "/opt/homebrew/bin/claude",
]);

const CODEX_BIN = findBinary("codex", [
  `${os.homedir()}/.local/bin/codex`,
  "/usr/local/bin/codex",
  "/opt/homebrew/bin/codex",
]);

if (!CLAUDE_BIN) {
  log("warn", "Could not find 'claude' binary — Claude sessions will not be available.");
}
if (CODEX_BIN) {
  log("info", `Codex binary found: ${CODEX_BIN}`);
} else {
  log("info", "Codex not found — Codex sessions will not be available.");
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT_RANGE_START = 7860;
const PORT_RANGE_END = 7869;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const RATE_LIMIT_MAX_ATTEMPTS = 5;
const SSE_HEARTBEAT_INTERVAL_MS = 10_000;
const SSE_BUFFER_SIZE = 500;
const PERMISSION_TIMEOUT_MS = 600_000; // 10 minutes
const CODEX_SESSION_SCAN_INTERVAL_MS = 1_500;
const CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS = 30 * 60 * 1000;
const CODEX_SESSION_SCAN_LIMIT = 25;
const CODEX_SESSION_ROOT = path.join(os.homedir(), ".codex", "sessions");
const CODEX_LOG_FILE = path.join(os.homedir(), ".codex", "log", "codex-tui.log");
const BRIDGE_ID = crypto.randomUUID();

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let sessionToken = null;
let pairingCode = null;
let pairingCodeExpiresAt = 0;

// Rate limiting
let rateLimitAttempts = 0;
let rateLimitWindowStart = Date.now();

// Bridge-level state: "idle" | "connected"
let bridgeState = "idle";

// Multi-session: each entry is a session slot
// { id, agent, cwd, folderName, ptyProcess, state, createdAt }
/** @type {Map<string, {id: string, agent: string, cwd: string, folderName: string, ptyProcess: import("child_process").ChildProcess | null, state: string, createdAt: number}>} */
const sessions = new Map();

// SSE
let sseEventId = 0;
/** @type {Array<{id: number, event: string, data: string}>} */
const sseBuffer = [];
/** @type {Set<http.ServerResponse>} */
const sseClients = new Set();

// Permission flow
/** @type {Map<string, {resolve: Function, timer: ReturnType<typeof setTimeout>, sessionId: string | null}>} */
const pendingPermissions = new Map();
/** @type {Map<string, Array>} */
const pendingPermissionBodies = new Map();
/** @type {Map<string, {offset: number, remainder: string, sessionId: string | null, cwd?: string, createdAt?: number, initialized: boolean}>} */
const codexSessionFiles = new Map();
/** @type {Map<string, {sessionId: string, name: string, args: Record<string, any>}>} */
const codexPendingToolCalls = new Map();
/** @type {Map<string, {command: string, justification: string, workdir: string, prefixRule: string[], createdAt: number}>} */
const codexExecApprovalCandidates = new Map();
/** @type {Map<string, {sessionId: string, optionCount: number, payload: Record<string, any>}>} */
const codexSyntheticPermissions = new Map();
/** @type {Map<string, string>} */
const codexSyntheticPermissionBySession = new Map();
const codexLogState = { offset: 0, remainder: "", initialized: false };
let codexMonitorInterval = null;

// Bonjour
let bonjourInstance = null;
let bonjourService = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function generatePairingCode() {
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = Date.now() + PAIRING_CODE_TTL_MS;
  log("info", `Pairing code generated: ${code} (expires in 5 minutes)`);
  return code;
}

function generateSessionToken() {
  const token = crypto.randomBytes(32).toString("hex");
  sessionToken = token;
  return token;
}

function isRateLimited() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  return rateLimitAttempts >= RATE_LIMIT_MAX_ATTEMPTS;
}

function recordRateLimitAttempt() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  rateLimitAttempts++;
}

function requireAuth(req) {
  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7);
  return token === sessionToken && sessionToken !== null;
}

function jsonResponse(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf-8");
        resolve(raw.length ? JSON.parse(raw) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function availableAgentsList() {
  const agents = [];
  if (CLAUDE_BIN) agents.push("claude");
  if (CODEX_BIN) agents.push("codex");
  return agents;
}

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function pushSseEvent(event, data, sessionId = null) {
  sseEventId++;

  // Inject sessionId into the data payload
  let payload;
  if (typeof data === "string") {
    try {
      payload = JSON.parse(data);
    } catch {
      payload = { raw: data };
    }
  } else {
    payload = { ...data };
  }
  if (sessionId !== null) {
    payload.sessionId = sessionId;
  }

  const entry = { id: sseEventId, event, data: JSON.stringify(payload) };

  // Ring buffer
  if (sseBuffer.length >= SSE_BUFFER_SIZE) {
    sseBuffer.shift();
  }
  sseBuffer.push(entry);

  // Broadcast to connected clients
  const formatted = formatSseMessage(entry);
  for (const client of sseClients) {
    try {
      client.write(formatted);
    } catch {
      sseClients.delete(client);
    }
  }
}

function formatSseMessage(entry) {
  let msg = `id: ${entry.id}\n`;
  msg += `event: ${entry.event}\n`;
  for (const line of entry.data.split("\n")) {
    msg += `data: ${line}\n`;
  }
  msg += "\n";
  return msg;
}

// ---------------------------------------------------------------------------
// Multi-session PTY management
// ---------------------------------------------------------------------------

function spawnInteractiveProcess(agent, cwd, args = []) {
  const bin = agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
  if (!bin) {
    return null;
  }
  const cols = parseInt(process.env.COLUMNS, 10) || 120;
  const rows = parseInt(process.env.LINES, 10) || 40;

  return childSpawn("script", ["-q", "/dev/null", bin, ...args], {
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      COLUMNS: String(cols),
      LINES: String(rows),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function bindPtyProcess(slot, proc) {
  const sessionId = slot.id;
  slot.ptyProcess = proc;

  proc.stdout.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.stderr.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.on("close", (exitCode, signal) => {
    log("info", `Session ${sessionId} (${slot.agent}) PTY exited: code=${exitCode} signal=${signal}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-closed");
    pushSseEvent("session", { state: "ended", exitCode, signal, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });

  proc.on("error", (err) => {
    log("error", `Session ${sessionId} PTY spawn error: ${err.message}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-error");
    pushSseEvent("session", { state: "ended", error: err.message, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });
}

function spawnSession(agent, cwd) {
  const sessionId = crypto.randomUUID();
  const folderName = path.basename(cwd) || cwd;

  log("info", `Spawning ${agent} session ${sessionId} in PTY (cwd: ${cwd})`);

  const proc = spawnInteractiveProcess(agent, cwd);
  if (!proc) {
    const msg = `Cannot spawn ${agent}: binary not found`;
    log("error", msg);
    pushSseEvent("error", { error: msg });
    return null;
  }

  log("info", `Using binary: ${agent === "codex" ? CODEX_BIN : CLAUDE_BIN}`);

  const slot = {
    id: sessionId,
    agent,
    cwd,
    folderName,
    ptyProcess: proc,
    state: "running",
    createdAt: Date.now(),
  };
  sessions.set(sessionId, slot);
  bindPtyProcess(slot, proc);

  pushSseEvent("session", { state: "running", agent, cwd, folderName }, sessionId);

  log("info", `${agent} session ${sessionId} started (${folderName}), pid: ${proc.pid}`);
  return sessionId;
}

function attachPtyToSession(slot) {
  if (slot.ptyProcess) return slot.ptyProcess;

  const args = slot.agent === "codex"
    ? ["resume", slot.id, "--no-alt-screen"]
    : [];

  const proc = spawnInteractiveProcess(slot.agent, slot.cwd, args);
  if (!proc) return null;

  bindPtyProcess(slot, proc);
  log("info", `Attached PTY to session ${slot.id} (${slot.agent}), pid: ${proc.pid}`);
  return proc;
}

function killSession(sessionId) {
  const slot = sessions.get(sessionId);
  if (!slot) return false;
  if (slot.ptyProcess) {
    try { slot.ptyProcess.kill(); } catch { /* ignore */ }
  }
  slot.state = "ended";
  slot.ptyProcess = null;
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, killed: true }, sessionId);
  log("info", `Session ${sessionId} killed`);
  return true;
}

function findSessionByCwd(cwd) {
  if (!cwd) return null;
  for (const [, slot] of sessions) {
    if (slot.cwd === cwd && slot.state === "running") return slot;
  }
  return null;
}

function findMostRecentActiveSession() {
  let best = null;
  for (const [, slot] of sessions) {
    if (slot.state === "running" && slot.ptyProcess) {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function findMostRecentRunningSession() {
  let best = null;
  for (const [, slot] of sessions) {
    if (slot.state === "running") {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function getSessionsSnapshot() {
  return Array.from(sessions.values()).map((s) => ({
    id: s.id,
    agent: s.agent,
    cwd: s.cwd,
    folderName: s.folderName,
    state: s.state,
    createdAt: s.createdAt,
  }));
}

function safeStat(targetPath) {
  try {
    return fs.statSync(targetPath);
  } catch {
    return null;
  }
}

function listRecentCodexSessionFiles(rootDir) {
  const results = [];
  const stack = [rootDir];

  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      const stat = safeStat(fullPath);
      if (!stat) continue;
      results.push({ filePath: fullPath, mtimeMs: stat.mtimeMs, size: stat.size });
    }
  }

  results.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return results.slice(0, CODEX_SESSION_SCAN_LIMIT);
}

function readFileSlice(filePath, start, length) {
  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fs.readSync(fd, buffer, 0, length, start);
    return buffer.subarray(0, bytesRead).toString("utf-8");
  } finally {
    fs.closeSync(fd);
  }
}

function touchExternalSession(sessionId, cwd, createdAt) {
  const resolvedCwd = cwd || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const existing = sessions.get(sessionId);

  if (existing) {
    const wasEnded = existing.state !== "running";
    existing.agent = "codex";
    existing.cwd = resolvedCwd;
    existing.folderName = folderName;
    existing.state = "running";
    existing.createdAt = createdAt || existing.createdAt || Date.now();
    if (wasEnded) {
      pushSseEvent("session", { state: "running", agent: "codex", cwd: resolvedCwd, folderName }, sessionId);
      log("info", `Revived Codex session ${sessionId} (${folderName}) from local session data`);
    }
    return existing;
  }

  const slot = {
    id: sessionId,
    agent: "codex",
    cwd: resolvedCwd,
    folderName,
    ptyProcess: null,
    state: "running",
    createdAt: createdAt || Date.now(),
  };
  sessions.set(sessionId, slot);
  pushSseEvent("session", { state: "running", agent: "codex", cwd: resolvedCwd, folderName }, sessionId);
  log("info", `Detected Codex session ${sessionId} (${folderName}) from local session data`);
  return slot;
}

function endExternalSession(sessionId, reason = "codex-exit") {
  const slot = sessions.get(sessionId);
  if (!slot || slot.state === "ended") return;
  slot.state = "ended";
  slot.ptyProcess = null;
  clearCodexSyntheticPermissionForSession(sessionId, reason);
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, reason }, sessionId);
  log("info", `Marked external session ${sessionId} as ended (${reason})`);
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function parseFunctionCallArgs(rawArgs) {
  if (typeof rawArgs !== "string") return {};
  try {
    const parsed = JSON.parse(rawArgs);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function extractPatchPaths(rawPatch) {
  if (typeof rawPatch !== "string" || rawPatch.length === 0) return [];
  const paths = [];
  for (const line of rawPatch.split("\n")) {
    const match = line.match(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/);
    if (match) paths.push(match[1]);
  }
  return [...new Set(paths)];
}

function emitCodexToolEvent(sessionId, toolName, toolInput = {}, toolOutput = null) {
  pushSseEvent("tool-output", {
    source: "codex",
    tool_name: toolName,
    tool_input: toolInput,
    tool_output: toolOutput,
  }, sessionId);
}

function emitCodexToolResult(sessionId, pendingCall, output) {
  if (!pendingCall || !sessionId) return;

  switch (pendingCall.name) {
    case "exec_command":
      emitCodexToolEvent(sessionId, "Bash", { command: pendingCall.args.cmd || "" }, output);
      break;
    case "apply_patch": {
      const patchPaths = extractPatchPaths(pendingCall.args.patch);
      if (patchPaths.length === 0) {
        emitCodexToolEvent(sessionId, "Edit", {}, output);
        break;
      }
      for (const filePath of patchPaths) {
        emitCodexToolEvent(sessionId, "Edit", { file_path: filePath }, output);
      }
      break;
    }
    default:
      emitCodexToolEvent(sessionId, pendingCall.name, pendingCall.args, output);
      break;
  }
}

function truncateText(value, maxLength = 80) {
  if (typeof value !== "string") return "";
  return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

function buildCodexApprovalOptions(prefixRule = []) {
  const options = [
    {
      label: "Yes, proceed",
      description: "Run this command once",
    },
  ];

  if (Array.isArray(prefixRule) && prefixRule.length > 0) {
    options.push({
      label: "Yes, don't ask again",
      description: `Trust ${prefixRule.join(" ")} in future`,
    });
  }

  options.push({
    label: "No",
    description: "Deny this command and return to Codex",
  });

  return options;
}

function recordCodexExecApprovalCandidate(line) {
  const match = line.match(/ToolCall: exec_command (\{.*\}) thread_id=([0-9a-f-]+)/i);
  if (!match) return;

  let args;
  try {
    args = JSON.parse(match[1]);
  } catch {
    return;
  }

  if (args?.sandbox_permissions !== "require_escalated") return;

  codexExecApprovalCandidates.set(match[2], {
    command: args.cmd || "",
    justification: args.justification || "Would you like to run this command?",
    workdir: args.workdir || "",
    prefixRule: Array.isArray(args.prefix_rule) ? args.prefix_rule : [],
    createdAt: Date.now(),
  });
}

function surfaceCodexExecApproval(sessionId) {
  const slot = sessions.get(sessionId);
  const candidate = codexExecApprovalCandidates.get(sessionId);
  if (!slot || !candidate) return;

  const existingId = codexSyntheticPermissionBySession.get(sessionId);
  if (existingId) return;

  const permissionId = crypto.randomUUID();
  const options = buildCodexApprovalOptions(candidate.prefixRule);
  const payload = {
    permissionId,
    source: "codex",
    tool_name: "ExecApproval",
    tool_input: {
      command: candidate.command,
      workdir: candidate.workdir,
      questions: [
        {
          header: truncateText(`Run: ${candidate.command}`, 72),
          question: candidate.justification || "Would you like to run this command?",
          options,
        },
      ],
    },
  };
  codexSyntheticPermissions.set(permissionId, { sessionId, optionCount: options.length, payload });
  codexSyntheticPermissionBySession.set(sessionId, permissionId);

  pushSseEvent("permission-request", payload, sessionId);

  log("info", `Surfaced Codex approval ${permissionId} for session ${sessionId}`);
}

function clearCodexSyntheticPermissionForSession(sessionId, reason = "cleared") {
  const permissionId = codexSyntheticPermissionBySession.get(sessionId);
  if (!permissionId) return false;

  codexSyntheticPermissionBySession.delete(sessionId);
  codexSyntheticPermissions.delete(permissionId);
  codexExecApprovalCandidates.delete(sessionId);
  pushSseEvent("permission-cleared", { permissionId, reason }, sessionId);
  return true;
}

function resolveCodexSyntheticPermission(permissionId, selectedOption, optionIndex) {
  const synthetic = codexSyntheticPermissions.get(permissionId);
  if (!synthetic) return false;

  const slot = sessions.get(synthetic.sessionId);
  if (!slot) return false;

  const proc = slot.ptyProcess || attachPtyToSession(slot);
  if (!proc || !proc.stdin) return false;

  let input = "\u001b";
  const normalizedIndex = Number.isInteger(optionIndex) ? optionIndex : -1;

  if (normalizedIndex === 0 || /^yes,?\s*proceed/i.test(String(selectedOption || ""))) {
    input = "y";
  } else if (
    synthetic.optionCount === 3
    && (normalizedIndex === 1 || /^yes,?\s*don't ask again/i.test(String(selectedOption || "")))
  ) {
    input = "2\n";
  }

  proc.stdin.write(input);
  clearCodexSyntheticPermissionForSession(synthetic.sessionId, "resolved");
  log("info", `Resolved Codex approval ${permissionId} for session ${synthetic.sessionId}`);
  return true;
}

function handleCodexJsonlLine(line, fileState, options = {}) {
  const parsed = parseJsonLine(line);
  if (!parsed) return;

  const bootstrap = options.bootstrap === true;

  if (parsed.type === "session_meta") {
    const sessionId = parsed.payload?.id;
    if (!sessionId) return;

    fileState.sessionId = sessionId;
    fileState.cwd = parsed.payload?.cwd || fileState.cwd;
    fileState.createdAt = Date.parse(parsed.payload?.timestamp || parsed.timestamp || "") || fileState.createdAt || Date.now();

    if (bootstrap && options.allowBootstrap !== true) return;

    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
    return;
  }

  const sessionId = fileState.sessionId;
  if (!sessionId || bootstrap) return;
  if (!sessions.has(sessionId) || sessions.get(sessionId)?.state !== "running") {
    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call") {
    const callId = parsed.payload.call_id;
    if (!callId) return;
    codexPendingToolCalls.set(callId, {
      sessionId,
      name: parsed.payload.name,
      args: parseFunctionCallArgs(parsed.payload.arguments),
    });
    return;
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call_output") {
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    emitCodexToolResult(sessionId, pendingCall, parsed.payload.output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }

  if (parsed.type !== "event_msg") return;

  const payloadType = parsed.payload?.type;
  if (payloadType === "task_started") {
    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
    return;
  }
  if (payloadType === "agent_message" && parsed.payload?.message) {
    emitCodexToolEvent(sessionId, "CodexMessage", {}, parsed.payload.message);
    return;
  }
  if (payloadType === "exec_command_end") {
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    const command = pendingCall?.args?.cmd
      || (Array.isArray(parsed.payload.command) ? parsed.payload.command.join(" ") : "");
    emitCodexToolEvent(sessionId, "Bash", { command }, parsed.payload.aggregated_output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }
  if (payloadType === "task_complete") {
    pushSseEvent("task-complete", { source: "codex" }, sessionId);
  }
}

function initializeCodexSessionFile(filePath, stat, fileState) {
  const headerSize = Math.min(stat.size, 64 * 1024);
  const header = headerSize > 0 ? readFileSlice(filePath, 0, headerSize) : "";
  const allowBootstrap = Date.now() - stat.mtimeMs <= CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS;

  for (const line of header.split("\n")) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState, { bootstrap: true, allowBootstrap });
    if (fileState.sessionId) break;
  }

  fileState.offset = stat.size;
  fileState.remainder = "";
  fileState.initialized = true;
}

function readCodexSessionFileDelta(filePath, stat, fileState) {
  if (stat.size < fileState.offset) {
    fileState.offset = 0;
    fileState.remainder = "";
  }
  if (stat.size === fileState.offset) return;

  const delta = readFileSlice(filePath, fileState.offset, stat.size - fileState.offset);
  fileState.offset = stat.size;

  let chunk = fileState.remainder + delta;
  const lines = chunk.split("\n");
  fileState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState);
  }
}

function scanCodexSessionFiles() {
  const statRoot = safeStat(CODEX_SESSION_ROOT);
  if (!statRoot || !statRoot.isDirectory()) return;

  const seen = new Set();
  for (const entry of listRecentCodexSessionFiles(CODEX_SESSION_ROOT)) {
    seen.add(entry.filePath);
    const fileState = codexSessionFiles.get(entry.filePath) || {
      offset: 0,
      remainder: "",
      sessionId: null,
      cwd: undefined,
      createdAt: undefined,
      initialized: false,
    };

    if (!fileState.initialized) {
      initializeCodexSessionFile(entry.filePath, entry, fileState);
      codexSessionFiles.set(entry.filePath, fileState);
      continue;
    }

    readCodexSessionFileDelta(entry.filePath, entry, fileState);
    codexSessionFiles.set(entry.filePath, fileState);
  }

  for (const filePath of codexSessionFiles.keys()) {
    if (!seen.has(filePath)) {
      codexSessionFiles.delete(filePath);
    }
  }
}

function consumeCodexLogChunk(text) {
  const combined = codexLogState.remainder + text;
  const lines = combined.split("\n");
  codexLogState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    recordCodexExecApprovalCandidate(line);

    const approvalMatch = line.match(/thread_id=([0-9a-f-]+).*codex\.op="exec_approval".*codex_core::codex: (new|close)/i);
    if (approvalMatch) {
      const [, sessionId, state] = approvalMatch;
      if (state === "new") {
        surfaceCodexExecApproval(sessionId);
      } else {
        clearCodexSyntheticPermissionForSession(sessionId, "closed");
      }
    }

    if (line.includes("Shutting down Codex instance")) {
      const match = line.match(/thread_id=([0-9a-f-]+)/i);
      if (match) {
        clearCodexSyntheticPermissionForSession(match[1], "codex-shutdown");
        endExternalSession(match[1], "codex-shutdown");
      }
    }
  }
}

function scanCodexLog() {
  const stat = safeStat(CODEX_LOG_FILE);
  if (!stat || !stat.isFile()) return;

  if (!codexLogState.initialized) {
    const lookbackSize = Math.min(stat.size, 128 * 1024);
    const startOffset = Math.max(0, stat.size - lookbackSize);
    const bootstrapText = lookbackSize > 0 ? readFileSlice(CODEX_LOG_FILE, startOffset, lookbackSize) : "";
    codexLogState.offset = stat.size;
    codexLogState.remainder = "";
    codexLogState.initialized = true;
    if (bootstrapText) {
      consumeCodexLogChunk(bootstrapText);
    }
    return;
  }

  if (stat.size < codexLogState.offset) {
    codexLogState.offset = 0;
    codexLogState.remainder = "";
  }
  if (stat.size === codexLogState.offset) return;

  const text = readFileSlice(CODEX_LOG_FILE, codexLogState.offset, stat.size - codexLogState.offset);
  codexLogState.offset = stat.size;
  consumeCodexLogChunk(text);
}

function startCodexMonitor() {
  if (codexMonitorInterval) return;

  scanCodexSessionFiles();
  scanCodexLog();

  codexMonitorInterval = setInterval(() => {
    try {
      scanCodexSessionFiles();
      scanCodexLog();
    } catch (err) {
      log("warn", `Codex monitor scan failed: ${err.message}`);
    }
  }, CODEX_SESSION_SCAN_INTERVAL_MS);
}

function stopCodexMonitor() {
  if (codexMonitorInterval) {
    clearInterval(codexMonitorInterval);
    codexMonitorInterval = null;
  }
}

// ---------------------------------------------------------------------------
// Permission flow
// ---------------------------------------------------------------------------

function waitForPermission(permissionId) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingPermissions.delete(permissionId);
      log("warn", `Permission ${permissionId} timed out after ${PERMISSION_TIMEOUT_MS / 1000}s, auto-denying`);
      resolve({ behavior: "deny", reason: "Timed out waiting for watch response" });
    }, PERMISSION_TIMEOUT_MS);

    pendingPermissions.set(permissionId, { resolve, timer });
  });
}

function resolvePermission(permissionId, decision) {
  const pending = pendingPermissions.get(permissionId);
  if (!pending) return false;
  clearTimeout(pending.timer);
  pendingPermissions.delete(permissionId);
  pending.resolve(decision);
  return true;
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

async function handlePair(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }

  if (isRateLimited()) {
    return jsonResponse(res, 429, { error: "Too many pairing attempts. Try again later." });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  recordRateLimitAttempt();

  const { code } = body;
  if (!code || typeof code !== "string") {
    return jsonResponse(res, 400, { error: "Missing 'code' field" });
  }

  if (Date.now() > pairingCodeExpiresAt) {
    generatePairingCode();
    return jsonResponse(res, 401, { error: "Pairing code expired. A new code has been generated." });
  }

  if (code !== pairingCode) {
    return jsonResponse(res, 401, { error: "Invalid pairing code" });
  }

  // Success
  const token = generateSessionToken();
  pairingCode = null;
  pairingCodeExpiresAt = 0;
  bridgeState = "connected";
  pushSseEvent("session", { state: "connected" });

  log("info", "Watch paired successfully");
  return jsonResponse(res, 200, {
    token,
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot(),
  });
}

async function handleCommand(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const {
    command,
    permissionId,
    decision,
    allowAll,
    agent,
    sessionId,
    spawn: spawnRequest,
    kill: killRequest,
    selectedOption,
    optionIndex,
  } = body;

  // --- Spawn a new session ---
  if (spawnRequest) {
    const validAgents = ["claude", "codex"];
    if (!validAgents.includes(spawnRequest)) {
      return jsonResponse(res, 400, { error: `Invalid agent: ${spawnRequest}. Use: ${validAgents.join(", ")}` });
    }
    const cwd = body.cwd || process.argv[2] || process.env.HOME || process.cwd();
    const newId = spawnSession(spawnRequest, cwd);
    if (!newId) {
      return jsonResponse(res, 500, { error: `Failed to spawn ${spawnRequest}` });
    }
    return jsonResponse(res, 200, { ok: true, sessionId: newId, agent: spawnRequest });
  }

  // --- Kill a session ---
  if (killRequest && sessionId) {
    const killed = killSession(sessionId);
    if (!killed) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }
    return jsonResponse(res, 200, { ok: true });
  }

  // --- Permission response ---
  if (permissionId && (decision || selectedOption !== undefined || Number.isInteger(optionIndex))) {
    if (decision) {
      if (allowAll && decision.behavior === "allow") {
        decision.updatedPermissions = pendingPermissionBodies.get(permissionId) || [];
      }
      pendingPermissionBodies.delete(permissionId);

      const resolved = resolvePermission(permissionId, decision);
      if (resolved) {
        log("info", `Permission ${permissionId} resolved: ${decision.behavior}${allowAll ? " (allow all)" : ""}`);
        return jsonResponse(res, 200, { ok: true });
      }
    }

    const resolvedSynthetic = resolveCodexSyntheticPermission(permissionId, selectedOption, optionIndex);
    if (resolvedSynthetic) {
      return jsonResponse(res, 200, { ok: true });
    }

    return jsonResponse(res, 404, { error: "No pending permission with that ID" });
  }

  // --- PTY command injection ---
  if (command !== undefined) {
    // Find the target session
    let targetSession = null;

    if (sessionId) {
      targetSession = sessions.get(sessionId);
      if (targetSession && !targetSession.ptyProcess) {
        // Session exists but has no PTY (external hook-created session).
        // Attach to the existing session so the watch can interact with the live thread.
        log("info", `Session ${sessionId} has no PTY — attaching to ${targetSession.agent} in ${targetSession.cwd}`);
        const proc = attachPtyToSession(targetSession);
        if (!proc) {
          return jsonResponse(res, 500, { error: `No binary found for ${targetSession.agent}` });
        }
        setTimeout(() => {
          if (targetSession.ptyProcess) {
            targetSession.ptyProcess.stdin.write(command);
            log("info", `Command injected into session ${sessionId} (${command.length} chars)`);
          }
        }, 500);
        return jsonResponse(res, 200, { ok: true, sessionId, agent: targetSession.agent, spawned: true });
      }
      if (!targetSession) {
        return jsonResponse(res, 404, { error: "No session with that ID" });
      }
    } else {
      // Backward compat: route to the most recent active session
      targetSession = findMostRecentActiveSession() || findMostRecentRunningSession();
    }

    if (!targetSession) {
      // Auto-spawn a new session
      const requestedAgent = agent || "claude";
      const cwd = body.cwd || process.argv[2] || process.env.HOME || process.cwd();
      const newId = spawnSession(requestedAgent, cwd);
      if (!newId) {
        return jsonResponse(res, 500, { error: `Failed to spawn ${requestedAgent}` });
      }
      const slot = sessions.get(newId);
      setTimeout(() => {
        if (slot && slot.ptyProcess) {
          slot.ptyProcess.stdin.write(command);
          log("info", `Command injected into new ${requestedAgent} session ${newId} (${command.length} chars)`);
        }
      }, 500);
      return jsonResponse(res, 200, { ok: true, sessionId: newId, agent: requestedAgent, spawned: true });
    }

    try {
      targetSession.ptyProcess.stdin.write(command);
      log("info", `Command injected into session ${targetSession.id} (${command.length} chars)`);
      return jsonResponse(res, 200, { ok: true, sessionId: targetSession.id, agent: targetSession.agent });
    } catch (err) {
      return jsonResponse(res, 500, { error: err.message });
    }
  }

  return jsonResponse(res, 400, { error: "Missing 'command', 'spawn', 'kill', or 'permissionId'+'decision'" });
}

function handleEvents(req, res) {
  if (req.method !== "GET") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });

  // Replay from Last-Event-ID if provided
  const lastIdHeader = req.headers["last-event-id"];
  if (lastIdHeader) {
    const lastId = parseInt(lastIdHeader, 10);
    if (!isNaN(lastId)) {
      for (const entry of sseBuffer) {
        if (entry.id > lastId) {
          res.write(formatSseMessage(entry));
        }
      }
    }
  }

  sseClients.add(res);
  log("info", `SSE client connected (total: ${sseClients.size})`);

  // Send current sessions state so late-connecting clients see existing sessions
  for (const [sid, slot] of sessions) {
    if (slot.state === "running") {
      const syncEntry = formatSseMessage({
        id: sseEventId++,
        event: "session",
        data: JSON.stringify({
          state: "running",
          agent: slot.agent,
          cwd: slot.cwd,
          folderName: slot.folderName,
          sessionId: sid,
        }),
      });
      try { res.write(syncEntry); } catch { /* ignore */ }
    }
  }

  for (const [permissionId, synthetic] of codexSyntheticPermissions) {
    const syncEntry = formatSseMessage({
      id: sseEventId++,
      event: "permission-request",
      data: JSON.stringify({
        ...synthetic.payload,
        permissionId,
        sessionId: synthetic.sessionId,
      }),
    });
    try { res.write(syncEntry); } catch { /* ignore */ }
  }

  const heartbeat = setInterval(() => {
    try {
      res.write(":heartbeat\n\n");
    } catch {
      clearInterval(heartbeat);
      sseClients.delete(res);
    }
  }, SSE_HEARTBEAT_INTERVAL_MS);

  req.on("close", () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
    log("info", `SSE client disconnected (total: ${sseClients.size})`);
  });
}

// --- Hook handlers ---
// Hooks come from Claude Code instances. We match by cwd to find the session.

function resolveHookSession(body) {
  const cwd = body.session_cwd || body.cwd || null;
  const source = body.source || "claude";

  // Try exact cwd match first
  const match = findSessionByCwd(cwd);
  if (match) return match.id;

  // Fallback: if exactly one running session, use it
  const active = findMostRecentActiveSession();
  if (active) return active.id;

  // No session exists — auto-create one for this external Claude/Codex instance
  const agent = source === "codex" ? "codex" : "claude";
  const resolvedCwd = cwd || process.argv[2] || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const sessionId = crypto.randomUUID();

  const slot = {
    id: sessionId,
    agent,
    cwd: resolvedCwd,
    folderName,
    ptyProcess: null, // External process — no PTY owned by bridge
    state: "running",
    createdAt: Date.now(),
  };
  sessions.set(sessionId, slot);

  log("info", `Auto-created session ${sessionId} for external ${agent} (${folderName})`);
  pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, sessionId);

  return sessionId;
}

async function handleHookToolOutput(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  const source = body.source || "claude";
  log("info", `Hook: ${source === "codex" ? "Codex" : "PostToolUse"} received [${source}]${sid ? ` session=${sid}` : ""}`, body.tool_name || "");
  pushSseEvent("tool-output", { ...body, source }, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookPermission(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  const permissionId = crypto.randomUUID();
  log("info", `Hook: PermissionRequest received (id: ${permissionId})${sid ? ` session=${sid}` : ""}`, body.tool_name || "");

  if (body.permission_suggestions) {
    pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  }

  pushSseEvent("permission-request", { permissionId, ...body }, sid);

  const decision = await waitForPermission(permissionId);

  log("info", `Hook: PermissionRequest resolved (id: ${permissionId}): ${decision.behavior}`);

  const hookResponse = {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: decision.behavior },
    },
  };

  if (decision.updatedPermissions && decision.updatedPermissions.length > 0) {
    hookResponse.hookSpecificOutput.decision.updatedPermissions = decision.updatedPermissions;
  }

  if (decision.behavior === "deny" && decision.message) {
    hookResponse.hookSpecificOutput.decision.message = decision.message;
  }

  return jsonResponse(res, 200, hookResponse);
}

async function handleHookStop(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Stop received${sid ? ` session=${sid}` : ""}`);
  pushSseEvent("stop", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookTaskComplete(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: TaskCompleted received${sid ? ` session=${sid}` : ""}`);
  pushSseEvent("task-complete", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookError(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Error received${sid ? ` session=${sid}` : ""}`, body.error || "");
  pushSseEvent("error", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

function handleStatus(_req, res) {
  const mostRecentRunningSession = findMostRecentRunningSession();
  return jsonResponse(res, 200, {
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    state: bridgeState,
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot(),
    sseClients: sseClients.size,
    pendingPermissions: pendingPermissions.size + codexSyntheticPermissions.size,
    eventBufferSize: sseBuffer.length,
    // Backward compat: expose the most recent active session's info
    hasPty: findMostRecentActiveSession() !== null,
    activeAgent: mostRecentRunningSession?.agent || null,
  });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

const routes = {
  "POST /pair": handlePair,
  "POST /command": handleCommand,
  "GET /events": handleEvents,
  "POST /hooks/tool-output": handleHookToolOutput,
  "POST /hooks/permission": handleHookPermission,
  "POST /hooks/stop": handleHookStop,
  "POST /hooks/task-complete": handleHookTaskComplete,
  "POST /hooks/error": handleHookError,
  "GET /status": handleStatus,
};

async function onRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const routeKey = `${req.method} ${url.pathname}`;

  const handler = routes[routeKey];
  if (handler) {
    try {
      await handler(req, res);
    } catch (err) {
      log("error", `Unhandled error in ${routeKey}:`, err.message);
      if (!res.headersSent) {
        jsonResponse(res, 500, { error: "Internal server error" });
      }
    }
  } else {
    jsonResponse(res, 404, { error: "Not found" });
  }
}

// ---------------------------------------------------------------------------
// Server startup
// ---------------------------------------------------------------------------

function tryListen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "0.0.0.0", () => {
      server.removeListener("error", reject);
      resolve(port);
    });
  });
}

async function startServer() {
  const server = http.createServer(onRequest);

  let boundPort = null;
  for (let port = PORT_RANGE_START; port <= PORT_RANGE_END; port++) {
    try {
      boundPort = await tryListen(server, port);
      break;
    } catch (err) {
      if (err.code === "EADDRINUSE") {
        log("warn", `Port ${port} in use, trying next...`);
        continue;
      }
      throw err;
    }
  }

  if (boundPort === null) {
    log("error", `No available port in range ${PORT_RANGE_START}-${PORT_RANGE_END}`);
    process.exit(1);
  }

  log("info", `Bridge server listening on 0.0.0.0:${boundPort}`);

  const code = generatePairingCode();

  // Bonjour
  bonjourInstance = new Bonjour();
  bonjourService = bonjourInstance.publish({
    name: `Claude Watch Bridge (${os.hostname()})`,
    type: "claude-watch",
    protocol: "tcp",
    port: boundPort,
    txt: {
      version: "2",
      bridgeId: BRIDGE_ID,
      sessionId: BRIDGE_ID, // backward compat
      machineName: os.hostname(),
    },
  });

  log("info", `Bonjour advertising _claude-watch._tcp on port ${boundPort}`);
  startCodexMonitor();

  const agents = [];
  if (CLAUDE_BIN) agents.push("Claude");
  if (CODEX_BIN) agents.push("Codex");
  log("info", `Bridge ready. Available agents: ${agents.join(", ") || "none"}. Sessions spawn on demand.`);

  // Get LAN IP
  const interfaces = os.networkInterfaces();
  let lanIP = "127.0.0.1";
  for (const [, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === "IPv4" && !addr.internal) {
        lanIP = addr.address;
        break;
      }
    }
    if (lanIP !== "127.0.0.1") break;
  }

  const agentLine = agents.length ? agents.join(" + ") : "none";
  console.log("");
  console.log("╔═══════════════════════════════════════╗");
  console.log("║        CLAUDE WATCH BRIDGE            ║");
  console.log("╠═══════════════════════════════════════╣");
  console.log(`║  Pairing Code:  ${code}                ║`);
  console.log(`║  IP Address:    ${lanIP.padEnd(20)}║`);
  console.log(`║  Port:          ${String(boundPort).padEnd(20)}║`);
  console.log(`║  Agents:        ${agentLine.padEnd(20)}║`);
  console.log("╚═══════════════════════════════════════╝");
  console.log("");

  // --- Graceful shutdown ---

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", `Received ${signal}, shutting down gracefully...`);

    for (const client of sseClients) {
      try { client.end(); } catch { /* ignore */ }
    }
    sseClients.clear();

    // Kill all session PTYs
    for (const [id, slot] of sessions) {
      if (slot.ptyProcess) {
        try { slot.ptyProcess.kill(); } catch { /* ignore */ }
        log("info", `Killed session ${id} (${slot.agent})`);
      }
    }
    sessions.clear();
    stopCodexMonitor();

    if (bonjourService) {
      try { bonjourInstance.unpublishAll(); } catch { /* ignore */ }
    }
    if (bonjourInstance) {
      try { bonjourInstance.destroy(); } catch { /* ignore */ }
    }

    for (const [id, pending] of pendingPermissions) {
      clearTimeout(pending.timer);
      pending.resolve({ behavior: "deny", reason: "Server shutting down" });
    }
    pendingPermissions.clear();

    server.close(() => {
      log("info", "Server closed");
      process.exit(0);
    });

    setTimeout(() => {
      log("warn", "Forced exit after timeout");
      process.exit(1);
    }, 5000);
  }

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  return { server, port: boundPort };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

startServer().catch((err) => {
  log("error", "Failed to start server:", err.message);
  process.exit(1);
});
