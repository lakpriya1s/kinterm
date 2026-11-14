#!/usr/bin/env node
// MCP server for KinTerm itself, run by `kinterm-ctl mcp`: the `kinterm-ctl`
// commands as tools. An agent can run things in a pane beside it, read
// them, say how it's doing, notify you, open the review, and start other
// agents in tabs of their own and work with them.
//
// It speaks to KinTerm over the same socket as `kinterm-ctl` and
// `kinterm-browser`. KinTerm checks every request comes from the terminal
// it names (this server runs under the agent, in that terminal), so an
// agent controls only its own terminal and the ones it started.
//
// No dependencies besides Node 20+.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

/** KinTerm's variables from the nearest parent process that has them (see kinterm-browser-mcp.mjs). */
function fromAncestors() {
  const found = {};
  try {
    let pid = process.ppid;
    for (let i = 0; i < 12 && pid > 1; i++) {
      const env = execFileSync("ps", ["-E", "-ww", "-o", "command=", "-p", String(pid)], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      const surfaceMatch = / KINTERM_SURFACE_ID=([0-9A-Fa-f-]{36})(?= |$)/m.exec(env);
      const socketMatch = / KINTERM_SOCKET=(\/.*?\.sock)(?= [A-Za-z_][A-Za-z0-9_]*=|\s*$)/m.exec(env);
      if (surfaceMatch && !found.surface) found.surface = surfaceMatch[1];
      if (socketMatch && !found.socket) found.socket = socketMatch[1];
      if (found.surface && found.socket) break;
      pid = Number(execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8" }).trim());
    }
  } catch {
    // Use what was found.
  }
  return found;
}

const inherited = process.env.KINTERM_SOCKET && process.env.KINTERM_SURFACE_ID ? {} : fromAncestors();
const socketPath = process.env.KINTERM_SOCKET || inherited.socket || process.env.KINTERM_BROWSER_SOCKET;
const surface = process.env.KINTERM_SURFACE_ID || inherited.surface;

function ask(request) {
  return new Promise((resolve, reject) => {
    if (!socketPath || !surface) return reject(new Error("Not running in a KinTerm terminal."));
    const socket = net.createConnection(socketPath);
    let data = "";
    socket.setTimeout(15000, () => socket.destroy(new Error("KinTerm didn't answer")));
    socket.on("connect", () => socket.write(JSON.stringify({ ...request, surface }) + "\n"));
    socket.on("data", (chunk) => (data += chunk));
    socket.on("end", () => {
      try {
        const reply = JSON.parse(data);
        if (reply.ok) resolve(reply);
        else reject(new Error(reply.error || "KinTerm refused."));
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** A git worktree on branch kinterm/NAME for an agent (see `kinterm-ctl agent spawn --worktree`). */
function makeWorktree(name, from) {
  const git = (...args) => execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  let top;
  try {
    top = git("-C", from, "rev-parse", "--show-toplevel");
  } catch {
    throw new Error(`worktree needs a git repository (${from} isn't in one).`);
  }
  const base = process.env.KINTERM_WORKTREES || path.join(os.homedir(), ".kinterm", "worktrees");
  const dir = path.join(base, path.basename(top), name);
  if (fs.existsSync(dir)) return dir;
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  let exists = true;
  try {
    git("-C", top, "show-ref", "--verify", "--quiet", `refs/heads/kinterm/${name}`);
  } catch {
    exists = false;
  }
  if (exists) git("-C", top, "worktree", "add", "--quiet", dir, `kinterm/${name}`);
  else git("-C", top, "worktree", "add", "--quiet", "-b", `kinterm/${name}`, dir);
  return dir;
}

function describe(w) {
  const needs = (w.exitCode !== undefined ? ` (exit ${w.exitCode})` : "") + (w.needs ? ` (${w.needs})` : "");
  const msg = w.msg ? ` - ${w.msg}` : "";
  const last = w.last ? `\n  Last said: ${w.last}` : "";
  return `${w.name} [${w.kind}]: ${w.state}${needs}${msg}${last}`;
}

// MARK: Tools

const str = (description) => ({ type: "string", description });
const num = (description) => ({ type: "number", description });
const bool = (description) => ({ type: "boolean", description });

const tools = [
  {
    name: "run",
    description:
      "Run a shell command in a new pane beside your terminal, where the user can watch it: dev servers, " +
      "watchers, long test runs. Returns the pane's name; read its output with `logs`. Prefer this to " +
      "running long-lived processes in the background.",
    inputSchema: {
      type: "object",
      properties: {
        command: str("The shell command."),
        name: str("A short name for the pane (letters, digits, . _ -). Default: pane-N."),
        cwd: str("Folder to run in. Default: your terminal's."),
        direction: { type: "string", enum: ["right", "down", "left", "up"], description: "Where the pane goes." },
      },
      required: ["command"],
    },
    async call(a) {
      const reply = await ask({
        cmd: "spawn",
        kind: "pane",
        name: a.name ?? "",
        command: a.command,
        cwd: a.cwd ?? process.cwd(),
        direction: a.direction ?? "right",
      });
      return `Started pane ${reply.worker.name}. Read its output with logs(name: "${reply.worker.name}").`;
    },
  },
  {
    name: "logs",
    description: "What a pane you started with `run` (or an agent you spawned) shows: the last lines of its terminal.",
    inputSchema: {
      type: "object",
      properties: { name: str("The pane's or agent's name."), lines: num("How many lines (default 200).") },
      required: ["name"],
    },
    async call(a) {
      return (await ask({ cmd: "read", name: a.name, lines: a.lines ?? 200 })).text || "(empty)";
    },
  },
  {
    name: "notify",
    description:
      "Send the user a macOS notification that leads back to your terminal. Use when you finish something " +
      "long or are blocked on them and they may not be looking.",
    inputSchema: {
      type: "object",
      properties: { message: str("What to tell them, one line."), title: str("Optional title.") },
      required: ["message"],
    },
    async call(a) {
      await ask({ cmd: "notify", title: a.title ?? "KinTerm", body: a.message });
      return "Notified.";
    },
  },
  {
    name: "set_status",
    description:
      "Show your state on your tab (its face and the Agents panel). Agents with KinTerm's hooks installed " +
      "report this already; use it when you're not one of them.",
    inputSchema: {
      type: "object",
      properties: {
        state: { type: "string", enum: ["idle", "working", "done", "blocked", "error", "clear"] },
        message: str("One line about what you're doing."),
      },
      required: ["state"],
    },
    async call(a) {
      await ask({ cmd: "set-status", state: a.state, msg: a.message ?? "" });
      return "Status set.";
    },
  },
  {
    name: "review",
    description:
      "Open KinTerm's review of your changes (diffs the user can revert by hunk and comment on), at the " +
      "first of `files` to look at. Use when you hand work over.",
    inputSchema: {
      type: "object",
      properties: { files: { type: "array", items: { type: "string" }, description: "Files to look at first." } },
    },
    async call(a) {
      const files = (a.files ?? []).map((f) => path.resolve(process.cwd(), f));
      await ask({ cmd: "review", files });
      return "The review is open.";
    },
  },
  {
    name: "scrollback",
    description: "Your own terminal's text, e.g. output that scrolled past.",
    inputSchema: { type: "object", properties: { lines: num("How many lines (default 200).") } },
    async call(a) {
      return (await ask({ cmd: "scrollback", lines: a.lines ?? 200 })).text || "(empty)";
    },
  },
  {
    name: "agent_spawn",
    description:
      "Start another agent (or any command) in a new KinTerm tab, as your worker. The user sees the tab and " +
      "can type into it. You can then list, wait for, read, message and close it. Give each worker a " +
      "self-contained task. Use worktree: true when workers edit the same repository, so they don't " +
      "overwrite each other. Example command: claude \"add rate limiting to server/api.ts\".",
    inputSchema: {
      type: "object",
      properties: {
        command: str("Command to run in the tab, e.g. claude \"<task>\" or codex \"<task>\"."),
        name: str("A short name (letters, digits, . _ -). Default: agent-N."),
        cwd: str("Folder to start in. Default: yours."),
        worktree: bool("Start in a new git worktree on branch kinterm/<name>."),
        allow_spawn: bool("Let this worker start workers of its own. Default false."),
      },
      required: ["command"],
    },
    async call(a) {
      let cwd = a.cwd ? path.resolve(process.cwd(), a.cwd) : process.cwd();
      let name = a.name ?? "";
      if (a.worktree) {
        if (!name) name = `agent-${Date.now().toString(36)}`;
        cwd = makeWorktree(name, cwd);
      }
      const reply = await ask({
        cmd: "spawn",
        kind: "tab",
        name,
        command: a.command,
        cwd,
        allowSpawn: !!a.allow_spawn,
      });
      return `Started ${reply.worker.name} in ${cwd}. Use agent_wait(names: ["${reply.worker.name}"]) to wait for it.`;
    },
  },
  {
    name: "agent_list",
    description: "The agents and panes you started, and what each is doing: working, done, blocked (needs an answer), " +
      "error, exited-command (its command ended, with exit code), exited (tab closed), or none.",
    inputSchema: { type: "object", properties: {} },
    async call() {
      const { workers } = await ask({ cmd: "workers" });
      return workers.length ? workers.map(describe).join("\n") : "You haven't started any.";
    },
  },
  {
    name: "agent_wait",
    description:
      "Wait until workers finish their turn or need someone (blocked on a question or permission, failed, " +
      "or exited), then say how each one ended, with its last message. until: 'done' waits for all, 'any' " +
      "for the first. Waiting needs the worker to be an agent that reports status (Claude Code or Codex " +
      "with KinTerm's hooks).",
    inputSchema: {
      type: "object",
      properties: {
        names: { type: "array", items: { type: "string" }, description: "Which workers. Default: all." },
        until: { type: "string", enum: ["done", "any"] },
        timeout_seconds: num("Give up after this long (default 600, at most 3600)."),
      },
    },
    async call(a) {
      const until = a.until ?? "done";
      const deadline = Date.now() + Math.min(a.timeout_seconds ?? 600, 3600) * 1000;
      for (;;) {
        const { workers } = await ask({ cmd: "workers" });
        const names = a.names?.length ? a.names : workers.map((w) => w.name);
        const picked = names.map((n) => {
          const w = workers.find((w) => w.name === n);
          if (!w) throw new Error(`No worker named ${n}.`);
          return w;
        });
        if (!picked.length) return "You haven't started any.";
        const ready = until === "any" ? picked.some((w) => w.settled) : picked.every((w) => w.settled);
        if (ready) return picked.map(describe).join("\n");
        if (Date.now() > deadline) return "Still working:\n" + picked.map(describe).join("\n");
        await sleep(2000);
      }
    },
  },
  {
    name: "agent_read",
    description: "The last lines of a worker's terminal, to see what it did or what it's asking.",
    inputSchema: {
      type: "object",
      properties: { name: str("The worker's name."), lines: num("How many lines (default 200).") },
      required: ["name"],
    },
    async call(a) {
      return (await ask({ cmd: "read", name: a.name, lines: a.lines ?? 200 })).text || "(empty)";
    },
  },
  {
    name: "agent_send",
    description:
      "Type a message into a worker's prompt and press Return: an answer to its question, a follow-up " +
      "task, or a correction. Set enter: false to type without sending.",
    inputSchema: {
      type: "object",
      properties: { name: str("The worker's name."), text: str("What to type."), enter: bool("Press Return (default true).") },
      required: ["name", "text"],
    },
    async call(a) {
      await ask({ cmd: "send", name: a.name, text: a.text, enter: a.enter ?? true });
      return `Sent to ${a.name}.`;
    },
  },
  {
    name: "agent_kill",
    description: "Close a worker's tab or pane, ending what runs there.",
    inputSchema: { type: "object", properties: { name: str("The worker's name.") }, required: ["name"] },
    async call(a) {
      await ask({ cmd: "kill", name: a.name });
      return `Closed ${a.name}.`;
    },
  },
  {
    name: "agent_release",
    description: "Hand a worker over to the user: its tab stays, and you can no longer control it.",
    inputSchema: { type: "object", properties: { name: str("The worker's name.") }, required: ["name"] },
    async call(a) {
      await ask({ cmd: "release", name: a.name });
      return `${a.name} is the user's now.`;
    },
  },
];

// MARK: MCP over stdio

function send(message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

async function handle(message) {
  const { id, method, params } = message;
  if (id === undefined) return; // A notification.
  switch (method) {
    case "initialize":
      return send({
        id,
        result: {
          protocolVersion: params?.protocolVersion ?? "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "kinterm", version: "1.0.0" },
          instructions:
            "Tools for the KinTerm terminal you run in. Use `run` for long-running commands so the user can " +
            "see them, `notify` when you finish something long, `review` when you hand work over, and " +
            "agent_* to split a large task across other agents in their own tabs.",
        },
      });
    case "ping":
      return send({ id, result: {} });
    case "tools/list":
      return send({
        id,
        result: { tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) },
      });
    case "tools/call": {
      const tool = tools.find((t) => t.name === params?.name);
      if (!tool) return send({ id, error: { code: -32602, message: `Unknown tool ${params?.name}` } });
      try {
        const text = await tool.call(params.arguments ?? {});
        return send({ id, result: { content: [{ type: "text", text }] } });
      } catch (error) {
        return send({ id, result: { content: [{ type: "text", text: String(error.message || error) }], isError: true } });
      }
    }
    default:
      return send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
  }
}

// Calls run side by side: a long agent_wait mustn't hold up the others.
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  handle(message).catch((error) => send({ id: message.id, error: { code: -32603, message: String(error) } }));
});
