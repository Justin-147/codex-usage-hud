const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const rootDir = __dirname;
const statusPath = process.argv[2] || path.join(rootDir, "status.json");
const pollMs = Number(process.env.CODEX_HUD_POLL_MS || 15000);

let requestId = 1;
let child = null;
let stdoutBuffer = "";
let reconnectTimer = null;
const pending = new Map();

const state = {
  connected: false,
  updatedAt: null,
  appServer: null,
  account: null,
  rateLimits: null,
  tokenUsage: null,
  threads: null,
  threadTokenUsage: null,
  errors: [],
  source: {
    account: "Codex app-server account/read",
    rateLimits: "Codex app-server account/rateLimits/read",
    tokenUsage: "Codex app-server account/usage/read",
    threadTokenUsage: "Codex app-server thread/tokenUsage/updated",
  },
};

function getCodexDesktopLogRoot() {
  const localAppData = process.env.LOCALAPPDATA || "";
  const packageRoot = path.join(localAppData, "Packages");
  try {
    const packageDir = fs
      .readdirSync(packageRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && /^OpenAI\.Codex_/i.test(entry.name))
      .map((entry) => path.join(packageRoot, entry.name, "LocalCache", "Local", "Codex", "Logs"))
      .find((candidate) => fs.existsSync(candidate));
    if (packageDir) return packageDir;
  } catch {
    // Fall through to the common install path.
  }
  return path.join(localAppData, "Packages", "OpenAI.Codex_2p2nqsd0c76g0", "LocalCache", "Local", "Codex", "Logs");
}

function findCodexExe() {
  if (process.env.CODEX_EXE && fs.existsSync(process.env.CODEX_EXE)) {
    return process.env.CODEX_EXE;
  }

  const localRoot = path.join(process.env.LOCALAPPDATA || "", "OpenAI", "Codex", "bin");
  try {
    const candidates = fs
      .readdirSync(localRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(localRoot, entry.name, "codex.exe"))
      .filter((candidate) => fs.existsSync(candidate))
      .map((candidate) => ({ candidate, mtimeMs: fs.statSync(candidate).mtimeMs }))
      .sort((a, b) => b.mtimeMs - a.mtimeMs);
    if (candidates[0]) return candidates[0].candidate;
  } catch {
    // Fall through to PATH.
  }

  return "codex.exe";
}

function rememberError(error) {
  const message = String(error && error.message ? error.message : error);
  state.errors.unshift({ at: new Date().toISOString(), message });
  state.errors = state.errors.slice(0, 5);
  writeStatus();
}

function writeStatus() {
  state.updatedAt = new Date().toISOString();
  const tmpPath = `${statusPath}.tmp`;
  fs.mkdirSync(path.dirname(statusPath), { recursive: true });
  fs.writeFileSync(tmpPath, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmpPath, statusPath);
}

function send(method, params = null, timeoutMs = 20000) {
  if (!child || child.killed || !child.stdin.writable) {
    return Promise.reject(new Error("app-server is not running"));
  }

  const id = requestId++;
  const payload = JSON.stringify({ method, id, params });
  child.stdin.write(`${payload}\n`);

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error(`${method} timed out`));
      }
    }, timeoutMs);
    pending.set(id, { method, resolve, reject, timeout });
  });
}

function notify(method, params = null) {
  if (!child || child.killed || !child.stdin.writable) return;
  child.stdin.write(`${JSON.stringify({ method, params })}\n`);
}

function settle(id, fn, value) {
  const request = pending.get(id);
  if (!request) return;
  pending.delete(id);
  clearTimeout(request.timeout);
  fn.call(request, value);
}

function handleMessage(message) {
  if (Object.prototype.hasOwnProperty.call(message, "id")) {
    if (message.error) {
      settle(
        message.id,
        function rejectCurrent() {
          this.reject(new Error(`${this.method}: ${JSON.stringify(message.error)}`));
        },
        message.error,
      );
    } else {
      settle(
        message.id,
        function resolveCurrent() {
          this.resolve(message.result);
        },
        message.result,
      );
    }
    return;
  }

  if (message.method === "account/rateLimits/updated") {
    if (!state.rateLimits) state.rateLimits = {};
    state.rateLimits.rateLimits = message.params.rateLimits;
    writeStatus();
    return;
  }

  if (message.method === "thread/tokenUsage/updated") {
    state.threadTokenUsage = {
      threadId: message.params.threadId,
      turnId: message.params.turnId,
      tokenUsage: message.params.tokenUsage,
      updatedAt: new Date().toISOString(),
    };
    writeStatus();
    return;
  }

  if (message.method === "account/updated") {
    state.accountNotification = message.params;
    writeStatus();
  }
}

function onStdout(chunk) {
  stdoutBuffer += chunk.toString("utf8");
  const lines = stdoutBuffer.split(/\r?\n/);
  stdoutBuffer = lines.pop() || "";
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      handleMessage(JSON.parse(line));
    } catch (error) {
      rememberError(`failed to parse app-server line: ${line.slice(0, 200)}`);
    }
  }
}

function summarizeUsage(usage) {
  const buckets = Array.isArray(usage.dailyUsageBuckets) ? usage.dailyUsageBuckets : [];
  const latest = buckets.length ? buckets[buckets.length - 1] : null;
  return {
    summary: usage.summary || null,
    dailyUsageBuckets: buckets,
    latestDailyBucket: latest,
  };
}

function toBreakdown(value) {
  if (!value) return null;
  return {
    totalTokens: Number(value.total_tokens || 0),
    inputTokens: Number(value.input_tokens || 0),
    cachedInputTokens: Number(value.cached_input_tokens || 0),
    outputTokens: Number(value.output_tokens || 0),
    reasoningOutputTokens: Number(value.reasoning_output_tokens || 0),
  };
}

function readTail(filePath, maxBytes = 4 * 1024 * 1024) {
  const stat = fs.statSync(filePath);
  const length = Math.min(stat.size, maxBytes);
  const start = Math.max(0, stat.size - length);
  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, start);
    return buffer.toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

function getRecentFiles(rootPath, maxFiles = 24) {
  const files = [];
  const stack = [rootPath];
  while (stack.length) {
    const current = stack.pop();
    let entries = [];
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (entry.isFile() && entry.name.endsWith(".log")) {
        try {
          files.push({ path: fullPath, mtimeMs: fs.statSync(fullPath).mtimeMs });
        } catch {
          // Ignore files that changed between listing and stat.
        }
      }
    }
  }
  return files.sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, maxFiles).map((item) => item.path);
}

function getFocusedThreadIdFromDesktopLogs() {
  const rootPath = getCodexDesktopLogRoot();
  if (!fs.existsSync(rootPath)) return null;

  let best = null;
  for (const filePath of getRecentFiles(rootPath)) {
    let text = "";
    try {
      text = readTail(filePath, 1024 * 1024);
    } catch {
      continue;
    }

    const lines = text.split(/\r?\n/);
    for (const line of lines) {
      if (!line.includes("conversationId=") && !line.includes("ownerRoutePath=/local/")) continue;
      const activeMatch = line.match(
        /^(\d{4}-\d{2}-\d{2}T[^\s]+).*thread_stream_view_activity_changed active=true conversationId=([0-9a-f-]{36}).*rendererWindowVisible=true/,
      );
      const ownerMatch = line.match(
        /^(\d{4}-\d{2}-\d{2}T[^\s]+).*IAB_LIFECYCLE received browser sidebar owner sync .*ownerRoutePath=\/local\/([0-9a-f-]{36})/,
      );
      const match = activeMatch || ownerMatch;
      if (!match) continue;

      const timestamp = Date.parse(match[1]);
      if (!Number.isFinite(timestamp)) continue;
      if (!best || timestamp > best.timestamp) {
        best = {
          timestamp,
          threadId: match[2],
          source: activeMatch ? "Codex desktop active thread log" : "Codex desktop owner route log",
        };
      }
    }
  }

  return best;
}

function readLatestRolloutTokenUsage(thread) {
  if (!thread || !thread.path || !fs.existsSync(thread.path)) return null;

  const text = readTail(thread.path);
  const lines = text.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].trim();
    if (!line || !line.includes('"token_count"')) continue;
    try {
      const event = JSON.parse(line);
      if (event.type !== "event_msg" || !event.payload || event.payload.type !== "token_count") {
        continue;
      }
      const info = event.payload.info || {};
      const total = toBreakdown(info.total_token_usage);
      const last = toBreakdown(info.last_token_usage);
      if (!total || !last) continue;
      return {
        threadId: thread.id,
        turnId: null,
        tokenUsage: {
          total,
          last,
          modelContextWindow: Number(info.model_context_window || 0) || null,
        },
        updatedAt: event.timestamp || new Date().toISOString(),
        source: "Codex local session token_count",
      };
    } catch {
      // Keep scanning older lines.
    }
  }

  return null;
}

async function pollOnce() {
  const [account, rateLimits, tokenUsage, threads, loadedThreads] = await Promise.all([
    send("account/read", { refreshToken: false }),
    send("account/rateLimits/read"),
    send("account/usage/read"),
    send("thread/list", {
      limit: 5,
      sortKey: "updated_at",
      sortDirection: "desc",
      useStateDbOnly: true,
    }).catch((error) => ({ error: String(error.message || error) })),
    send("thread/loaded/list", { limit: 20 }).catch((error) => ({ error: String(error.message || error) })),
  ]);

  state.connected = true;
  state.account = account;
  state.rateLimits = rateLimits;
  state.tokenUsage = summarizeUsage(tokenUsage);
  const focused = getFocusedThreadIdFromDesktopLogs();
  let selectedThread = null;
  let selectionSource = "thread/list updated_at";
  if (threads && Array.isArray(threads.data)) {
    if (focused && focused.threadId) {
      selectedThread = threads.data.find((thread) => thread.id === focused.threadId) || null;
      selectionSource = focused.source;
      if (!selectedThread) {
        const read = await send("thread/read", { threadId: focused.threadId, includeTurns: false }).catch(() => null);
        selectedThread = read && read.thread ? read.thread : null;
      }
    }
    if (!selectedThread) {
      selectedThread = threads.data[0] || null;
      selectionSource = "thread/list updated_at";
    }
  }
  state.threads = {
    recent: threads,
    loaded: loadedThreads,
    selected: selectedThread,
    focusedThreadId: focused ? focused.threadId : null,
    selectionSource,
  };
  if (selectedThread) {
    const rolloutTokenUsage = readLatestRolloutTokenUsage(selectedThread);
    if (rolloutTokenUsage) {
      rolloutTokenUsage.selectionSource = selectionSource;
      state.threadTokenUsage = rolloutTokenUsage;
    } else {
      state.threadTokenUsage = {
        threadId: selectedThread.id,
        turnId: null,
        tokenUsage: null,
        updatedAt: new Date().toISOString(),
        source: "Codex selected thread without token_count",
        selectionSource,
      };
    }
  }
  writeStatus();
}

async function start() {
  const codexExe = findCodexExe();
  state.codexExe = codexExe;
  writeStatus();

  child = spawn(codexExe, ["app-server", "--stdio"], {
    cwd: rootDir,
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });

  child.stdout.on("data", onStdout);
  child.stderr.on("data", (chunk) => {
    const text = chunk.toString("utf8").trim();
    if (text) {
      state.lastStderr = text.slice(-2000);
      writeStatus();
    }
  });
  child.on("exit", (code, signal) => {
    state.connected = false;
    rememberError(`app-server exited: code=${code ?? "null"} signal=${signal ?? "null"}`);
    for (const [id, request] of pending.entries()) {
      pending.delete(id);
      clearTimeout(request.timeout);
      request.reject(new Error("app-server exited"));
    }
    scheduleReconnect();
  });

  const init = await send("initialize", {
    clientInfo: { name: "codex-usage-hud", title: "Codex Usage HUD", version: "0.1.0" },
    capabilities: { experimentalApi: true, requestAttestation: false },
  });
  notify("initialized");
  state.appServer = init;

  await pollOnce();
  setInterval(() => pollOnce().catch(rememberError), pollMs);
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    start().catch((error) => {
      rememberError(error);
      scheduleReconnect();
    });
  }, 5000);
}

start().catch((error) => {
  state.connected = false;
  rememberError(error);
  scheduleReconnect();
});
