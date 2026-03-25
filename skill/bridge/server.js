import http from "node:http";
import crypto from "node:crypto";
import os from "node:os";
import fs from "node:fs";
import { execSync } from "node:child_process";
import { spawn as childSpawn } from "node:child_process";
import { Bonjour } from "bonjour-service";

// Resolve the full path to the claude binary.
// node-pty uses posix_spawnp which may not inherit the interactive shell PATH.
function findClaudeBinary() {
  // Check common install locations directly — avoids shell session noise
  const candidates = [
    `${os.homedir()}/.local/bin/claude`,
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  // Last resort: try which (without interactive shell flags)
  try {
    return execSync("which claude 2>/dev/null", { encoding: "utf-8" }).trim();
  } catch { /* fall through */ }
  throw new Error(
    "Could not find the 'claude' binary. Ensure Claude Code is installed and on your PATH."
  );
}

const CLAUDE_BIN = findClaudeBinary();

// ---------------------------------------------------------------------------
// Logging
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
// Configuration
// ---------------------------------------------------------------------------

const PORT_RANGE_START = 7860;
const PORT_RANGE_END = 7869;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000; // 5 minutes
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000; // 5 minutes
const RATE_LIMIT_MAX_ATTEMPTS = 5;
const SSE_HEARTBEAT_INTERVAL_MS = 10_000;
const SSE_BUFFER_SIZE = 500;
const PERMISSION_TIMEOUT_MS = 600_000; // 10 minutes
const SESSION_ID = crypto.randomUUID();

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let sessionToken = null;
let pairingCode = null;
let pairingCodeExpiresAt = 0;

// Rate limiting (simple in-memory)
let rateLimitAttempts = 0;
let rateLimitWindowStart = Date.now();

// Session state: "idle" | "running" | "ended" | "connected"
let sessionState = "idle";

// SSE --
let sseEventId = 0;
/** @type {Array<{id: number, event: string, data: string}>} */
const sseBuffer = [];
/** @type {Set<http.ServerResponse>} */
const sseClients = new Set();

// Permission flow --
/** @type {Map<string, {resolve: Function, timer: ReturnType<typeof setTimeout>}>} */
const pendingPermissions = new Map();
/** @type {Map<string, Array>} Stores original permission_suggestions per permissionId */
const pendingPermissionBodies = new Map();

// PTY --
let ptyProcess = null;

// Bonjour --
let bonjourInstance = null;
let bonjourService = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function generatePairingCode() {
  // 6-digit zero-padded random code
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = Date.now() + PAIRING_CODE_TTL_MS;
  log("info", `Pairing code generated: ${code} (expires in 5 minutes)`);
  return code;
}

function generateSessionToken() {
  const token = crypto.randomBytes(32).toString("hex"); // 256-bit
  sessionToken = token;
  return token;
}

function isRateLimited() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    // Reset window
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

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function pushSseEvent(event, data) {
  sseEventId++;
  const entry = { id: sseEventId, event, data: typeof data === "string" ? data : JSON.stringify(data) };

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
  // Multi-line data support
  for (const line of entry.data.split("\n")) {
    msg += `data: ${line}\n`;
  }
  msg += "\n";
  return msg;
}

// ---------------------------------------------------------------------------
// PTY management
// ---------------------------------------------------------------------------

function spawnClaude(cwd) {
  const cols = parseInt(process.env.COLUMNS, 10) || 120;
  const rows = parseInt(process.env.LINES, 10) || 40;

  log("info", `Spawning claude in PTY via script (cwd: ${cwd})`);
  log("info", `Using claude binary: ${CLAUDE_BIN}`);

  // Use macOS `script` command to allocate a PTY, since node-pty's posix_spawnp
  // can be blocked by sandboxed environments. `script -q /dev/null` gives us a
  // real PTY while child_process.spawn handles the process lifecycle.
  ptyProcess = childSpawn("script", ["-q", "/dev/null", CLAUDE_BIN], {
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      COLUMNS: String(cols),
      LINES: String(rows),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });

  sessionState = "running";
  pushSseEvent("session", { state: "running" });

  ptyProcess.stdout.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() });
  });

  ptyProcess.stderr.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() });
  });

  ptyProcess.on("close", (exitCode, signal) => {
    log("info", `PTY exited: code=${exitCode} signal=${signal}`);
    sessionState = "ended";
    pushSseEvent("session", { state: "ended", exitCode, signal });
    ptyProcess = null;
  });

  ptyProcess.on("error", (err) => {
    log("error", `PTY spawn error: ${err.message}`);
    sessionState = "ended";
    pushSseEvent("session", { state: "ended", error: err.message });
    ptyProcess = null;
  });

  log("info", "Claude PTY process started, pid:", ptyProcess.pid);
}

function writeToPty(text) {
  if (!ptyProcess) {
    // Auto-spawn Claude when the first command arrives
    const cwd = process.argv[2] || process.env.HOME || process.cwd();
    spawnClaude(cwd);
    // Wait briefly for the PTY to initialize
    setTimeout(() => {
      if (ptyProcess) {
        ptyProcess.stdin.write(text);
      }
    }, 500);
    return;
  }
  ptyProcess.stdin.write(text);
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
    // Regenerate an expired code
    generatePairingCode();
    return jsonResponse(res, 401, { error: "Pairing code expired. A new code has been generated." });
  }

  if (code !== pairingCode) {
    return jsonResponse(res, 401, { error: "Invalid pairing code" });
  }

  // Success — generate token, invalidate code
  const token = generateSessionToken();
  pairingCode = null;
  pairingCodeExpiresAt = 0;
  sessionState = "connected";
  pushSseEvent("session", { state: "connected" });

  log("info", "Watch paired successfully");
  return jsonResponse(res, 200, { token, sessionId: SESSION_ID });
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

  const { command, permissionId, decision, allowAll } = body;

  // Handle permission response from watch/phone
  if (permissionId && decision) {
    // If "allow all" was chosen, attach the permission_suggestions from the
    // original request so Claude Code can auto-add the permission rule.
    if (allowAll && decision.behavior === "allow") {
      // Store the original body's permission_suggestions alongside the decision
      decision.updatedPermissions = pendingPermissionBodies.get(permissionId) || [];
    }
    pendingPermissionBodies.delete(permissionId);

    const resolved = resolvePermission(permissionId, decision);
    if (!resolved) {
      return jsonResponse(res, 404, { error: "No pending permission with that ID" });
    }
    log("info", `Permission ${permissionId} resolved: ${decision.behavior}${allowAll ? " (allow all)" : ""}`);
    return jsonResponse(res, 200, { ok: true });
  }

  // Handle PTY command injection
  if (command !== undefined) {
    if (!ptyProcess) {
      return jsonResponse(res, 409, { error: "No active PTY session" });
    }
    try {
      writeToPty(command);
      log("info", `Command injected into PTY (${command.length} chars)`);
      return jsonResponse(res, 200, { ok: true });
    } catch (err) {
      return jsonResponse(res, 500, { error: err.message });
    }
  }

  return jsonResponse(res, 400, { error: "Missing 'command' or 'permissionId'+'decision'" });
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

  // Register client
  sseClients.add(res);
  log("info", `SSE client connected (total: ${sseClients.size})`);

  // Heartbeat
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

async function handleHookToolOutput(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  log("info", "Hook: PostToolUse received", body.tool_name || "");
  pushSseEvent("tool-output", body);
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

  const permissionId = crypto.randomUUID();
  log("info", `Hook: PermissionRequest received (id: ${permissionId})`, body.tool_name || "");
  log("info", `Hook: PermissionRequest full body:`, JSON.stringify(body, null, 2));

  // Store permission_suggestions for "allow all" flow
  if (body.permission_suggestions) {
    pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  }

  // Push to SSE so watch/phone can see and respond
  pushSseEvent("permission-request", { permissionId, ...body });

  // Block until watch responds or timeout
  const decision = await waitForPermission(permissionId);

  log("info", `Hook: PermissionRequest resolved (id: ${permissionId}): ${decision.behavior}`);

  const hookResponse = {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: decision.behavior },
    },
  };

  // If "allow all", include updatedPermissions so Claude adds the rule
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

  log("info", "Hook: Stop received");
  pushSseEvent("stop", body);
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

  log("info", "Hook: TaskCompleted received");
  pushSseEvent("task-complete", body);
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

  log("info", "Hook: Error received", body.error || "");
  pushSseEvent("error", body);
  return jsonResponse(res, 200, { ok: true });
}

function handleStatus(_req, res) {
  return jsonResponse(res, 200, {
    state: sessionState,
    sessionId: SESSION_ID,
    hasPty: ptyProcess !== null,
    sseClients: sseClients.size,
    pendingPermissions: pendingPermissions.size,
    eventBufferSize: sseBuffer.length,
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
// Server startup — find available port
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

  // Generate initial pairing code
  const code = generatePairingCode();

  // Advertise via Bonjour/mDNS
  bonjourInstance = new Bonjour();
  bonjourService = bonjourInstance.publish({
    name: `Claude Watch Bridge (${os.hostname()})`,
    type: "claude-watch",
    protocol: "tcp",
    port: boundPort,
    txt: {
      version: "1",
      sessionId: SESSION_ID,
      machineName: os.hostname(),
    },
  });

  log("info", `Bonjour advertising _claude-watch._tcp on port ${boundPort}`);

  // PTY is spawned on-demand when the first command arrives, not on startup.
  // This allows the bridge to start independently of any Claude session.
  log("info", "Bridge ready. PTY will spawn when first command is received.");

  // Print pairing info prominently
  console.log("");
  console.log("╔═══════════════════════════════════════╗");
  console.log("║        CLAUDE WATCH BRIDGE            ║");
  console.log("╠═══════════════════════════════════════╣");
  console.log(`║  Pairing Code:  ${code}                ║`);
  console.log(`║  Port:          ${String(boundPort).padEnd(20)}║`);
  console.log(`║  Session:       ${SESSION_ID.slice(0, 20)}… ║`);
  console.log("╚═══════════════════════════════════════╝");
  console.log("");

  // ---------------------------------------------------------------------------
  // Graceful shutdown
  // ---------------------------------------------------------------------------

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", `Received ${signal}, shutting down gracefully...`);

    // Close SSE clients
    for (const client of sseClients) {
      try {
        client.end();
      } catch { /* ignore */ }
    }
    sseClients.clear();

    // Kill PTY
    if (ptyProcess) {
      try {
        ptyProcess.kill();
      } catch { /* ignore */ }
    }

    // Unpublish Bonjour
    if (bonjourService) {
      try {
        bonjourInstance.unpublishAll();
      } catch { /* ignore */ }
    }
    if (bonjourInstance) {
      try {
        bonjourInstance.destroy();
      } catch { /* ignore */ }
    }

    // Resolve any pending permissions with deny
    for (const [id, pending] of pendingPermissions) {
      clearTimeout(pending.timer);
      pending.resolve({ behavior: "deny", reason: "Server shutting down" });
    }
    pendingPermissions.clear();

    // Close HTTP server
    server.close(() => {
      log("info", "Server closed");
      process.exit(0);
    });

    // Force exit after 5 seconds
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
