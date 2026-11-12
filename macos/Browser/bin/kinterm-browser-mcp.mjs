#!/usr/bin/env node
// MCP server for KinTerm's browser, run by `kinterm-browser mcp`.
//
// It's Chrome DevTools MCP (pages, clicks, typing, console, network,
// performance traces, screenshots…) pointed at the browser inside KinTerm
// instead of a Chrome of its own. This passes messages through, and on the
// first tool call asks KinTerm to open its browser, so an agent that never
// uses it never starts it.
//
// Each agent gets its own tab's browser and nothing else. KinTerm opens the
// browser in the tab the agent runs in (KINTERM_SURFACE_ID says which
// terminal that is), and Chrome DevTools MCP reaches Chromium through a
// small proxy here that shows it that one page: other tabs' pages, and
// KinTerm's own DevTools pages, aren't there for it. The proxy also moves
// the agent's cursor on the page as the agent moves the mouse.
//
// No dependencies besides Node 20+ and npx.

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import http from "node:http";
import net from "node:net";
import readline from "node:readline";

const CHROME_DEVTOOLS_MCP = "chrome-devtools-mcp@1.13.0";
const socketPath = process.env.KINTERM_BROWSER_SOCKET;
const surface = process.env.KINTERM_SURFACE_ID || undefined;

/** Ask KinTerm something over its socket, as this agent's terminal. */
function ask(request) {
  return new Promise((resolve, reject) => {
    if (!socketPath) return reject(new Error("KINTERM_BROWSER_SOCKET isn't set"));
    const socket = net.createConnection(socketPath);
    let data = "";
    socket.setTimeout(15000, () => socket.destroy(new Error("KinTerm didn't answer")));
    socket.on("connect", () => socket.write(JSON.stringify({ ...request, surface }) + "\n"));
    socket.on("data", (chunk) => (data += chunk));
    socket.on("end", () => {
      try {
        resolve(JSON.parse(data));
      } catch {
        reject(new Error("KinTerm sent an unreadable reply"));
      }
    });
    socket.on("error", (error) =>
      reject(
        error.code === "ENOENT" || error.code === "ECONNREFUSED"
          ? new Error("KinTerm isn't running. Open KinTerm and try again.")
          : error,
      ),
    );
  });
}

const debug = process.env.KINTERM_BROWSER_DEBUG ? (...args) => process.stderr.write(args.join(" ") + "\n") : () => {};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait until the browser's DevTools endpoint answers. */
async function waitForBrowser(port) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) return;
    } catch {
      // Not up yet.
    }
    await sleep(150);
  }
  throw new Error("KinTerm's browser didn't start in time.");
}

// MARK: The browser this agent may use

/** Chromium's DevTools port, and the one page (target id) this agent gets. */
const browser = { port: null, target: null };

// MARK: WebSocket frames
//
// Just enough of RFC 6455 for DevTools traffic on 127.0.0.1: text frames,
// fragments, ping/pong and close. No extensions are negotiated.

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function encodeFrame(payload, opcode, mask) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const length = data.length;
  const size = length < 126 ? 2 : length < 65536 ? 4 : 10;
  const header = Buffer.alloc(size + (mask ? 4 : 0));
  header[0] = 0x80 | opcode;
  if (length < 126) {
    header[1] = length;
  } else if (length < 65536) {
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  if (!mask) return Buffer.concat([header, data]);
  header[1] |= 0x80;
  const key = crypto.randomBytes(4);
  key.copy(header, size);
  const masked = Buffer.from(data);
  for (let i = 0; i < masked.length; i++) masked[i] ^= key[i & 3];
  return Buffer.concat([header, masked]);
}

/** Reads frames from a socket; calls onMessage with each text message. */
class FrameReader {
  constructor(handlers) {
    this.handlers = handlers;
    this.chunks = [];
    this.length = 0;
    this.fragments = null;
  }

  push(chunk) {
    if (!chunk.length) return;
    this.chunks.push(chunk);
    this.length += chunk.length;
    this.parse();
  }

  flatten() {
    if (this.chunks.length > 1) this.chunks = [Buffer.concat(this.chunks)];
    return this.chunks[0];
  }

  parse() {
    while (this.length >= 2) {
      let head = this.chunks[0].length >= 14 ? this.chunks[0] : this.flatten();
      const fin = (head[0] & 0x80) !== 0;
      const opcode = head[0] & 0x0f;
      const masked = (head[1] & 0x80) !== 0;
      let size = head[1] & 0x7f;
      let offset = 2;
      if (size === 126) {
        if (this.length < 4) return;
        head = this.flatten();
        size = head.readUInt16BE(2);
        offset = 4;
      } else if (size === 127) {
        if (this.length < 10) return;
        head = this.flatten();
        size = Number(head.readBigUInt64BE(2));
        offset = 10;
      }
      const keyAt = offset;
      if (masked) offset += 4;
      if (this.length < offset + size) return;

      const all = this.flatten();
      const frame = all.subarray(0, offset + size);
      const rest = all.subarray(offset + size);
      this.chunks = rest.length ? [rest] : [];
      this.length = rest.length;

      let payload = frame.subarray(offset);
      if (masked) {
        payload = Buffer.from(payload);
        const key = frame.subarray(keyAt, keyAt + 4);
        for (let i = 0; i < payload.length; i++) payload[i] ^= key[i & 3];
      }

      if (opcode === 0x1 || opcode === 0x2) {
        if (fin) this.handlers.message(payload.toString("utf8"));
        else this.fragments = [payload];
      } else if (opcode === 0x0) {
        if (!this.fragments) continue;
        this.fragments.push(payload);
        if (fin) {
          const message = Buffer.concat(this.fragments).toString("utf8");
          this.fragments = null;
          this.handlers.message(message);
        }
      } else if (opcode === 0x8) {
        this.handlers.close();
      } else if (opcode === 0x9) {
        this.handlers.ping(payload);
      }
    }
  }
}

/** Open a WebSocket to Chromium. Resolves with the socket and any bytes after the handshake. */
function connectUpstream(path) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(browser.port, "127.0.0.1");
    const key = crypto.randomBytes(16).toString("base64");
    let buffered = Buffer.alloc(0);
    const onData = (chunk) => {
      buffered = Buffer.concat([buffered, chunk]);
      const end = buffered.indexOf("\r\n\r\n");
      if (end < 0) return;
      socket.off("data", onData);
      const head = buffered.subarray(0, end).toString("latin1");
      if (!/^HTTP\/1\.1 101/.test(head)) {
        socket.destroy();
        return reject(new Error("The browser refused the connection"));
      }
      resolve({ socket, rest: buffered.subarray(end + 4) });
    };
    socket.on("data", onData);
    socket.once("error", reject);
    socket.on("connect", () => {
      socket.write(
        `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${browser.port}\r\nUpgrade: websocket\r\n` +
          `Connection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
  });
}

/**
 * Which page each tab target holds. Chromium lists a "tab" target around
 * each page, with nothing saying which page; attaching to a tab (on a
 * connection of our own) and asking it to attach to its children says.
 */
async function pagesOfTabs(path, tabIds = null) {
  const pages = new Map();
  if (tabIds && !tabIds.length) return pages;
  let upstream;
  try {
    upstream = await connectUpstream(path);
  } catch {
    return pages;
  }
  const { socket } = upstream;
  return new Promise((resolve) => {
    const sessions = new Map(); // tab session → tab id
    let pendingTabs = tabIds ? tabIds.length : 0;
    let nextId = 1;
    const request = (method, params, sessionId) =>
      socket.write(
        encodeFrame(JSON.stringify({ id: nextId++, method, params, ...(sessionId ? { sessionId } : {}) }), 0x1, true),
      );
    const attaches = new Map(); // request id → tab id
    const done = () => {
      clearTimeout(timer);
      socket.destroy();
      resolve(pages);
    };
    const timer = setTimeout(done, 3000);
    const reader = new FrameReader({
      message(text) {
        let message;
        try {
          message = JSON.parse(text);
        } catch {
          return;
        }
        if (message.id === listId) {
          const tabs = (message.result?.targetInfos ?? []).filter((t) => t.type === "tab").map((t) => t.targetId);
          if (!tabs.length) return done();
          attachAll(tabs);
          return;
        }
        if (attaches.has(message.id)) {
          const tab = attaches.get(message.id);
          attaches.delete(message.id);
          const sessionId = message.result?.sessionId;
          if (!sessionId) {
            if (--pendingTabs === 0) done();
            return;
          }
          sessions.set(sessionId, tab);
          request("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, sessionId);
          return;
        }
        if (message.method === "Target.attachedToTarget" && sessions.has(message.sessionId)) {
          const info = message.params?.targetInfo;
          const tab = sessions.get(message.sessionId);
          if (info && PAGE_TYPES.has(info.type) && !pages.has(tab)) {
            pages.set(tab, info.targetId);
            if (--pendingTabs === 0) done();
          }
        }
      },
      close: done,
      ping() {},
    });
    socket.on("data", (chunk) => reader.push(chunk));
    socket.on("close", done);
    socket.on("error", done);
    reader.push(upstream.rest);
    let listId = -1;
    function attachAll(tabs) {
      pendingTabs = tabs.length;
      for (const tab of tabs) {
        attaches.set(nextId, tab);
        request("Target.attachToTarget", { targetId: tab, flatten: true });
      }
    }
    if (tabIds) {
      attachAll(tabIds);
    } else {
      listId = nextId;
      request("Target.getTargets", { filter: [{}] });
    }
  });
}

// MARK: The DevTools proxy

/** Page-like targets: the ones that belong to a tab of KinTerm's. */
const PAGE_TYPES = new Set(["page", "background_page", "webview", "app"]);

/**
 * One Chrome DevTools MCP connection to the browser, filtered to this
 * agent's page: other pages aren't listed, can't be attached to, and their
 * events don't come through. Pages it opens itself (new_page) are its own.
 */
function proxyBrowserConnection(path, tabPages, client, clientRest, upstream, upstreamRest) {
  const types = new Map(); // target id → type
  const own = new Set(browser.target ? [browser.target] : []);
  const blockedTargets = new Set();
  const blockedSessions = new Set();
  const pending = new Map(); // the client's request id → method
  const hidden = new Set(); // our own requests' ids
  let nextHiddenId = 2_000_000_000;

  const filtering = () => browser.target !== null;

  function isBlocked(info) {
    if (!filtering() || !info) return false;
    const id = info.targetId;
    if (own.has(id)) return false;
    if (blockedTargets.has(id)) return true;
    const type = info.type ?? types.get(id);
    if (type === "tab") {
      // A tab is this agent's if the page in it is.
      if (!tabPages.has(id)) return false;
      if (own.has(tabPages.get(id))) return false;
      blockedTargets.add(id);
      return true;
    }
    if (!PAGE_TYPES.has(type)) return false;
    blockedTargets.add(id);
    return true;
  }

  // While finding out which page a new tab holds, Chromium's messages wait
  // here, in order.
  let held = null;

  function holdForTab(tabId, message) {
    held = [message];
    pagesOfTabs(path, [tabId]).then((found) => {
      // A tab with no page we could find: treat it as someone else's,
      // unless it holds a page this agent opened.
      tabPages.set(tabId, found.get(tabId) ?? null);
      const queue = held;
      held = null;
      for (let i = 0; i < queue.length; i++) {
        handleUpstream(queue[i]);
        if (held) {
          held.push(...queue.slice(i + 1));
          return;
        }
      }
    });
  }

  function toClient(message) {
    if (!client.destroyed) client.write(encodeFrame(message, 0x1, false));
  }

  function toUpstream(message) {
    if (!upstream.destroyed) upstream.write(encodeFrame(message, 0x1, true));
  }

  function hiddenRequest(method, params, sessionId) {
    const id = nextHiddenId++;
    hidden.add(id);
    toUpstream(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  }

  // Chromium → Chrome DevTools MCP
  function handleUpstream(text) {
      if (held) return held.push(text);
      debug("<", text.slice(0, 300));
      let message;
      try {
        message = JSON.parse(text);
      } catch {
        return toClient(text);
      }
      if (message.sessionId && blockedSessions.has(message.sessionId)) return;

      if (message.id !== undefined) {
        if (hidden.delete(message.id)) return;
        const method = pending.get(message.id);
        pending.delete(message.id);
        if (method === "Target.getTargets" && message.result?.targetInfos) {
          for (const info of message.result.targetInfos) types.set(info.targetId, info.type);
          message.result.targetInfos = message.result.targetInfos.filter((info) => !isBlocked(info));
          return toClient(JSON.stringify(message));
        }
        if (method === "Target.createTarget" && message.result?.targetId) own.add(message.result.targetId);
        return toClient(text);
      }

      const params = message.params ?? {};
      const info = params.targetInfo;
      if (filtering() && info?.type === "tab" && !tabPages.has(info.targetId)) {
        return holdForTab(info.targetId, text);
      }
      switch (message.method) {
        case "Target.targetCreated":
        case "Target.targetInfoChanged":
          types.set(params.targetInfo?.targetId, params.targetInfo?.type);
          if (isBlocked(params.targetInfo)) return;
          break;
        case "Target.targetDestroyed":
        case "Target.targetCrashed":
          if (blockedTargets.has(params.targetId)) return;
          break;
        case "Target.attachedToTarget":
          types.set(params.targetInfo?.targetId, params.targetInfo?.type);
          if (isBlocked(params.targetInfo)) {
            // Not this agent's page: let it go on (it may be waiting for
            // a debugger) and let go of it.
            blockedSessions.add(params.sessionId);
            if (params.waitingForDebugger) hiddenRequest("Runtime.runIfWaitingForDebugger", {}, params.sessionId);
            hiddenRequest("Target.detachFromTarget", { sessionId: params.sessionId }, message.sessionId);
            return;
          }
          break;
        case "Target.detachedFromTarget":
          if (blockedSessions.delete(params.sessionId)) return;
          break;
      }
      toClient(text);
  }

  const fromUpstream = new FrameReader({
    message: handleUpstream,
    close() {
      client.end(encodeFrame(Buffer.alloc(0), 0x8, false));
      upstream.end();
    },
    ping(payload) {
      upstream.write(encodeFrame(payload, 0xa, true));
    },
  });

  // Chrome DevTools MCP → Chromium
  const fromClient = new FrameReader({
    message(text) {
      debug(">", text.slice(0, 300));
      let message;
      try {
        message = JSON.parse(text);
      } catch {
        return toUpstream(text);
      }
      const params = message.params ?? {};

      // Another page's target: as if it weren't there.
      if (params.targetId && isBlocked({ targetId: params.targetId })) {
        return toClient(
          JSON.stringify({
            id: message.id,
            error: { code: -32602, message: "No target with given id found" },
            ...(message.sessionId ? { sessionId: message.sessionId } : {}),
          }),
        );
      }

      if (message.method === "Target.getTargets" || message.method === "Target.createTarget") {
        pending.set(message.id, message.method);
      }

      // The agent's mouse: move its cursor on the page first, in order.
      if (message.method === "Input.dispatchMouseEvent" && message.sessionId && params.type !== "mouseReleased") {
        const x = Number(params.x) || 0;
        const y = Number(params.y) || 0;
        const type = JSON.stringify(String(params.type));
        hiddenRequest(
          "Runtime.evaluate",
          {
            expression: `window.__kintermAgentPointer && window.__kintermAgentPointer(${x}, ${y}, ${type})`,
            silent: true,
          },
          message.sessionId,
        );
      }
      toUpstream(text);
    },
    close() {
      upstream.end(encodeFrame(Buffer.alloc(0), 0x8, true));
      client.end();
    },
    ping(payload) {
      client.write(encodeFrame(payload, 0xa, false));
    },
  });

  client.on("data", (chunk) => fromClient.push(chunk));
  upstream.on("data", (chunk) => fromUpstream.push(chunk));
  const end = () => {
    client.destroy();
    upstream.destroy();
  };
  client.on("close", end);
  upstream.on("close", end);
  client.on("error", end);
  upstream.on("error", end);
  fromClient.push(clientRest);
  fromUpstream.push(upstreamRest);
}

/** The proxy's HTTP side: /json/version and /json/list, rewritten to point here. */
async function serveHTTP(request, response, proxyPort) {
  const path = (request.url || "/").split("?")[0];
  const rewrite = (url) =>
    typeof url === "string" ? url.replace(`127.0.0.1:${browser.port}`, `127.0.0.1:${proxyPort}`) : url;
  try {
    if (browser.port === null) throw new Error("no browser yet");
    const upstream = await fetch(`http://127.0.0.1:${browser.port}${request.url}`);
    if (path === "/json/version") {
      const body = await upstream.json();
      body.webSocketDebuggerUrl = rewrite(body.webSocketDebuggerUrl);
      return send(response, 200, body);
    }
    if (path === "/json" || path === "/json/list") {
      const list = await upstream.json();
      const visible = list
        .filter((info) => !browser.target || !PAGE_TYPES.has(info.type) || info.id === browser.target)
        .map((info) => ({ ...info, webSocketDebuggerUrl: rewrite(info.webSocketDebuggerUrl) }));
      return send(response, 200, visible);
    }
    send(response, 404, { error: "Not available through KinTerm" });
  } catch (error) {
    send(response, 502, { error: String(error.message || error) });
  }
}

function send(response, status, body) {
  const data = JSON.stringify(body);
  response.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  response.end(data);
}

async function upgrade(request, client, head) {
  const path = (request.url || "").split("?")[0];
  const pageMatch = /^\/devtools\/page\/([^/]+)$/.exec(path);
  const isBrowser = /^\/devtools\/browser\//.test(path);
  const key = request.headers["sec-websocket-key"];
  const refuse = () => client.end("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
  if (!key || browser.port === null || (!isBrowser && !pageMatch)) return refuse();
  if (pageMatch && browser.target && pageMatch[1] !== browser.target) return refuse();

  let upstream;
  try {
    upstream = await connectUpstream(path);
  } catch {
    return refuse();
  }
  const accept = crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
  client.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  if (isBrowser) {
    // Which page each current tab holds, before Chrome DevTools MCP looks.
    const tabPages = browser.target ? await pagesOfTabs(path) : new Map();
    proxyBrowserConnection(path, tabPages, client, head, upstream.socket, upstream.rest);
  } else {
    // A connection to this agent's own page: nothing to hide.
    upstream.socket.write(head);
    client.write(upstream.rest);
    client.pipe(upstream.socket).pipe(client);
    const end = () => {
      client.destroy();
      upstream.socket.destroy();
    };
    client.on("error", end);
    upstream.socket.on("error", end);
  }
}

function startProxy() {
  return new Promise((resolve) => {
    const server = http.createServer((request, response) => serveHTTP(request, response, server.address().port));
    server.on("upgrade", (request, socket, head) => {
      socket.on("error", () => socket.destroy());
      upgrade(request, socket, head);
    });
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

// MARK: The Chrome DevTools MCP child

let child = null;
let proxyPort = null;
let initializeMessage = null; // The client's, replayed when the child restarts.
const hiddenIds = new Set(); // Replies to our replayed requests, not the client's.

function startChild() {
  child = spawn(
    "npx",
    [
      "-y",
      CHROME_DEVTOOLS_MCP,
      `--browserUrl=http://127.0.0.1:${proxyPort}`,
      // Nothing about your pages leaves your machine.
      "--no-usage-statistics",
      "--no-performance-crux",
    ],
    { stdio: ["pipe", "pipe", "inherit"], env: { ...process.env, CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS: "1" } },
  );
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    try {
      const message = JSON.parse(line);
      if (message.id !== undefined && hiddenIds.delete(message.id)) return;
      if (message.id !== undefined && activeCalls.delete(message.id) && activeCalls.size === 0) {
        ask({ cmd: "agent", active: false, target: browser.target ?? undefined }).catch(() => {});
      }
    } catch {
      // Not JSON; pass it on as it is.
    }
    process.stdout.write(line + "\n");
  });
  const current = child;
  child.on("exit", (code) => {
    if (child === current) {
      process.stderr.write(`chrome-devtools-mcp exited (${code})\n`);
      process.exit(code ?? 1);
    }
  });
}

/** The browser restarted, or this tab's page was reopened: start over on it. */
function restartChild() {
  const old = child;
  child = null;
  old?.kill();
  startChild();
  if (initializeMessage) {
    const id = `kinterm-reinit-${Date.now()}`;
    hiddenIds.add(id);
    send_({ ...initializeMessage, id });
    send_({ jsonrpc: "2.0", method: "notifications/initialized" });
  }
}

function send_(message) {
  child.stdin.write(JSON.stringify(message) + "\n");
}

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

// MARK: Messages from the agent

let browserReady = false;

// Tool calls in flight. While there are any, KinTerm shows the agent's
// cursor on the page.
const activeCalls = new Set();

async function ensureBrowser() {
  let opened = await ask({ cmd: "start" });
  // The page's target id comes a moment after the page opens (null until
  // then; an older KinTerm doesn't send it at all).
  const deadline = Date.now() + 10000;
  while (opened.ok && opened.target === null && Date.now() < deadline) {
    await sleep(150);
    opened = await ask({ cmd: "start" });
  }
  if (!opened.ok) throw new Error(opened.error || "KinTerm couldn't open its browser.");

  const target = opened.target ?? null;
  if (browser.port !== null && (opened.port !== browser.port || target !== browser.target)) {
    browser.port = opened.port;
    browser.target = target;
    browserReady = false;
    restartChild();
  }
  browser.port = opened.port;
  browser.target = target;
  if (!browserReady) {
    await waitForBrowser(opened.port);
    browserReady = true;
  }
}

async function main() {
  proxyPort = await startProxy();
  startChild();

  // One message at a time, in order: a tool call may wait for the browser.
  let queue = Promise.resolve();
  readline.createInterface({ input: process.stdin }).on("line", (line) => {
    queue = queue.then(() => handle(line));
  });
  process.stdin.on("end", () => queue.then(() => child?.stdin.end()));
}

async function handle(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    child.stdin.write(line + "\n");
    return;
  }
  if (message.method === "initialize") initializeMessage = message;
  if (message.method === "tools/call") {
    try {
      await ensureBrowser();
    } catch (error) {
      reply(message.id, { content: [{ type: "text", text: String(error.message || error) }], isError: true });
      return;
    }
    if (activeCalls.size === 0) ask({ cmd: "agent", active: true, target: browser.target ?? undefined }).catch(() => {});
    activeCalls.add(message.id);
  }
  send_(message);
}

main();
