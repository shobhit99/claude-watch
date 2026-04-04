import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { once } from "node:events";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const BRIDGE_DIR = path.resolve(__dirname, "..");

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function stopProcess(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
  try {
    await Promise.race([
      once(child, "exit"),
      sleep(2_000).then(() => {
        if (child.exitCode === null) child.kill("SIGKILL");
      }),
    ]);
  } catch {
    // no-op
  }
}

async function startBridgeServer(envOverrides = {}) {
  const child = spawn(process.execPath, ["server.js"], {
    cwd: BRIDGE_DIR,
    env: {
      ...process.env,
      ...envOverrides,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let logs = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { logs += chunk; });
  child.stderr.on("data", (chunk) => { logs += chunk; });

  const deadline = Date.now() + 20_000;
  let port = null;
  let pairingCode = null;

  while (Date.now() < deadline) {
    const portMatches = logs.match(/Bridge server listening on 0\.0\.0\.0:(\d+)/g);
    if (portMatches && portMatches.length > 0) {
      const last = portMatches[portMatches.length - 1];
      port = Number(last.split(":").at(-1));
    }

    const codeMatches = logs.match(/Pairing code generated: (\d{6})/g);
    if (codeMatches && codeMatches.length > 0) {
      const last = codeMatches[codeMatches.length - 1];
      pairingCode = last.match(/(\d{6})/)?.[1] ?? null;
    }

    if (port && pairingCode) {
      return {
        child,
        logsRef: () => logs,
        port,
        pairingCode,
        baseURL: `http://127.0.0.1:${port}`,
      };
    }

    if (child.exitCode !== null) {
      throw new Error(`Bridge exited before ready. Logs:\n${logs}`);
    }

    await sleep(50);
  }

  await stopProcess(child);
  throw new Error(`Bridge start timed out. Logs:\n${logs}`);
}

async function requestBridge(baseURL, pathname, options = {}) {
  const {
    method = "GET",
    token = null,
    json = undefined,
    rawBody = undefined,
    headers: extraHeaders = {},
  } = options;
  const headers = {};
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  Object.assign(headers, extraHeaders);
  if (json !== undefined && headers["Content-Type"] === undefined) {
    headers["Content-Type"] = "application/json";
  }

  const res = await fetch(`${baseURL}${pathname}`, {
    method,
    headers,
    body: json !== undefined ? JSON.stringify(json) : rawBody,
  });

  const text = await res.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }

  return { res, text, body };
}

test("GET /status without Authorization returns nginx-style 404", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const { res, text } = await requestBridge(bridge.baseURL, "/status");
  assert.equal(res.status, 404);
  assert.equal(res.headers.get("server"), "nginx");
  assert.match(text, /404 Not Found/);
});

test("valid ingress token can read /status", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const { res, body } = await requestBridge(bridge.baseURL, "/status", {
    token: "test_ingress_token",
  });
  assert.equal(res.status, 200);
  assert.equal(body?.ingressAuthRequired, true);
});

test("pairing requires ingress token and returns session token on success", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const badPair = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "wrong_token",
    json: { code: bridge.pairingCode },
  });
  assert.equal(badPair.res.status, 404);

  const okPair = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "test_ingress_token",
    json: { code: bridge.pairingCode },
  });
  assert.equal(okPair.res.status, 200);
  assert.equal(typeof okPair.body?.token, "string");
  assert.equal(okPair.body.token.length, 64);

  const statusWithSession = await requestBridge(bridge.baseURL, "/status", {
    token: okPair.body.token,
  });
  assert.equal(statusWithSession.res.status, 200);
});

test("fail2ban blocks correct ingress token after repeated bad bearer attempts", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "3",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_WINDOW_MS: "600000",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_BAN_MS: "600000",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  for (let i = 0; i < 3; i++) {
    const bad = await requestBridge(bridge.baseURL, "/status", {
      token: `wrong_token_${i}`,
    });
    assert.equal(bad.res.status, 404);
  }

  const blocked = await requestBridge(bridge.baseURL, "/status", {
    token: "test_ingress_token",
  });
  assert.equal(blocked.res.status, 404);
  assert.match(bridge.logsRef(), /Ingress fail2ban blocked client/);
});

test("successful ingress request clears failure counter before threshold", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "2",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_WINDOW_MS: "600000",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_BAN_MS: "600000",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const firstBad = await requestBridge(bridge.baseURL, "/status", {
    token: "wrong_token_1",
  });
  assert.equal(firstBad.res.status, 404);

  const good = await requestBridge(bridge.baseURL, "/status", {
    token: "test_ingress_token",
  });
  assert.equal(good.res.status, 200);

  const secondBad = await requestBridge(bridge.baseURL, "/status", {
    token: "wrong_token_2",
  });
  assert.equal(secondBad.res.status, 404);

  const stillGood = await requestBridge(bridge.baseURL, "/status", {
  token: "test_ingress_token",
  });
  assert.equal(stillGood.res.status, 200);
});

test("pairing endpoint returns 400 for malformed JSON", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const badJson = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "test_ingress_token",
    rawBody: "{invalid json",
    headers: { "Content-Type": "application/json" },
  });
  assert.equal(badJson.res.status, 400);
  assert.equal(badJson.body?.error, "Invalid JSON");
});

test("pairing endpoint returns 400 when code field is missing", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const missingCode = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "test_ingress_token",
    json: {},
  });
  assert.equal(missingCode.res.status, 400);
  assert.equal(missingCode.body?.error, "Missing 'code' field");
});

test("command endpoint only accepts session token, not ingress token", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const ingressCommand = await requestBridge(bridge.baseURL, "/command", {
    method: "POST",
    token: "test_ingress_token",
    json: {},
  });
  assert.equal(ingressCommand.res.status, 401);

  const pair = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "test_ingress_token",
    json: { code: bridge.pairingCode },
  });
  assert.equal(pair.res.status, 200);
  const sessionToken = pair.body?.token;
  assert.equal(typeof sessionToken, "string");

  const sessionCommand = await requestBridge(bridge.baseURL, "/command", {
    method: "POST",
    token: sessionToken,
    json: {},
  });
  assert.equal(sessionCommand.res.status, 400);
  assert.match(sessionCommand.body?.error ?? "", /Missing 'command'/);
});

test("events endpoint requires session token and responds as SSE", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const ingressEvents = await requestBridge(bridge.baseURL, "/events", {
    token: "test_ingress_token",
  });
  assert.equal(ingressEvents.res.status, 401);

  const pair = await requestBridge(bridge.baseURL, "/pair", {
    method: "POST",
    token: "test_ingress_token",
    json: { code: bridge.pairingCode },
  });
  assert.equal(pair.res.status, 200);
  const sessionToken = pair.body?.token;
  assert.equal(typeof sessionToken, "string");

  const sseRes = await fetch(`${bridge.baseURL}/events`, {
    method: "GET",
    headers: { Authorization: `Bearer ${sessionToken}` },
  });
  assert.equal(sseRes.status, 200);
  assert.match(sseRes.headers.get("content-type") ?? "", /text\/event-stream/);
  await sseRes.body?.cancel();
});

test("non-/pair auth brute force on /command triggers in-memory IP ban", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_MAX_ATTEMPTS: "3",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_WINDOW_MS: "600000",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_BAN_MS: "600000",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  for (let i = 0; i < 3; i++) {
    const unauthorized = await requestBridge(bridge.baseURL, "/command", {
      method: "POST",
      token: `invalid_session_${i}`,
      json: { command: "echo test" },
    });
    assert.equal(unauthorized.res.status, 401);
  }

  const blockedStatus = await requestBridge(bridge.baseURL, "/status", {
    token: "test_ingress_token",
  });
  assert.equal(blockedStatus.res.status, 404);
  assert.match(bridge.logsRef(), /Non-pair fail2ban blocked client/);
});

test("unknown-route probing also contributes to non-/pair IP ban", async (t) => {
  const bridge = await startBridgeServer({
    CLAUDE_WATCH_INGRESS_TOKEN: "test_ingress_token",
    CLAUDE_WATCH_INGRESS_FAIL2BAN_MAX_ATTEMPTS: "20",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_MAX_ATTEMPTS: "2",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_WINDOW_MS: "600000",
    CLAUDE_WATCH_NON_PAIR_FAIL2BAN_BAN_MS: "600000",
  });
  t.after(async () => {
    await stopProcess(bridge.child);
  });

  const probe1 = await requestBridge(bridge.baseURL, "/wp-admin");
  assert.equal(probe1.res.status, 404);

  const probe2 = await requestBridge(bridge.baseURL, "/.env");
  assert.equal(probe2.res.status, 404);

  const blockedStatus = await requestBridge(bridge.baseURL, "/status", {
    token: "test_ingress_token",
  });
  assert.equal(blockedStatus.res.status, 404);
});
