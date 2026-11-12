#!/usr/bin/env node
// MCP server for KinTerm's browser, run by `kinterm-browser mcp`.
//
// It's Chrome DevTools MCP (pages, clicks, typing, console, network,
// performance traces, screenshots…) pointed at the browser inside KinTerm
// instead of a Chrome of its own. This passes messages through, and on the
// first tool call asks KinTerm to open its browser, so an agent that never
// uses it never starts it.
//
// No dependencies besides Node 20+ and npx.

import { spawn } from "node:child_process";
import net from "node:net";
import readline from "node:readline";

const CHROME_DEVTOOLS_MCP = "chrome-devtools-mcp@1.13.0";
const socketPath = process.env.KINTERM_BROWSER_SOCKET;

/** Ask KinTerm something over its socket. */
function ask(request) {
  return new Promise((resolve, reject) => {
    if (!socketPath) return reject(new Error("KINTERM_BROWSER_SOCKET isn't set"));
    const socket = net.createConnection(socketPath);
    let data = "";
    socket.setTimeout(15000, () => socket.destroy(new Error("KinTerm didn't answer")));
    socket.on("connect", () => socket.write(JSON.stringify(request) + "\n"));
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
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  throw new Error("KinTerm's browser didn't start in time.");
}

// MARK: The Chrome DevTools MCP child

let child = null;
let childPort = null;
let initializeMessage = null; // The client's, replayed when the child restarts.
const hiddenIds = new Set(); // Replies to our replayed requests, not the client's.

function startChild(port) {
  childPort = port;
  child = spawn(
    "npx",
    [
      "-y",
      CHROME_DEVTOOLS_MCP,
      `--browserUrl=http://127.0.0.1:${port}`,
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
        ask({ cmd: "agent", active: false }).catch(() => {});
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

/** KinTerm restarted with another port: start over on the new one. */
function restartChild(port) {
  const old = child;
  child = null;
  old?.kill();
  startChild(port);
  if (initializeMessage) {
    const id = `kinterm-reinit-${Date.now()}`;
    hiddenIds.add(id);
    send({ ...initializeMessage, id });
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }
}

function send(message) {
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
  const opened = await ask({ cmd: "start" });
  if (!opened.ok) throw new Error(opened.error || "KinTerm couldn't open its browser.");
  if (opened.port !== childPort) {
    restartChild(opened.port);
    browserReady = false;
  }
  if (!browserReady) {
    await waitForBrowser(opened.port);
    browserReady = true;
  }
}

async function main() {
  // The port is known before the browser runs; asking doesn't start it.
  let port = 9;
  try {
    const status = await ask({ cmd: "status" });
    if (status.port) port = status.port;
  } catch {
    // KinTerm isn't running yet. Tool calls will say so, or find it later.
  }
  startChild(port);

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
    if (activeCalls.size === 0) ask({ cmd: "agent", active: true }).catch(() => {});
    activeCalls.add(message.id);
  }
  send(message);
}

main();
