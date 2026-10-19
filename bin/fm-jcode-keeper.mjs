#!/usr/bin/env node
// fm-jcode-keeper.mjs - the per-home keeper client for the native jcode backend.
//
// One dependency-free process per firstmate home. Through this home's API bridge
// (JCODE_API_SOCKET, started by bin/fm-jcode-keeper.sh) it stays attached to every
// worker session this home owns, because a turn whose last attached client
// disconnects is abandoned by the daemon (verified, jcode v0.99.0). From the
// events on those attachments it writes firstmate's own records:
//
//   state/jcode/live/<session>        `busy|idle|unknown <epoch>`
//   state/jcode/transitions           append-only normalized transition records
//                                     (<session> TAB jcode TAB from TAB to TAB detail)
//   state/jcode/injected/<session>    `<epoch> <client_id> <point>` per soft interrupt
//   state/jcode/recovered/<session>   crash-recovery marker (bin/fm-jcode-keeper.mjs, D6)
//   state/<id>.jcode-children         `<child>\t<label>\t<working_dir>` per child session
//   state/jcode/keeper.pid|beat|log   process facts
//
// Ownership (amended D11): it attaches only to sessions recorded in this home's
// state/*.jcode-session whose task meta says backend=jcode and which carry no
// state/<id>.jcode-exited. list_sessions is read only to discover children of
// those owned sessions; it never acts on any other session. It never starts the
// shared daemon.
//
// Environment: FM_HOME, JCODE_API_SOCKET; FM_JCODE_KEEPER_IDLE_EXIT_SECS (600),
// FM_JCODE_KEEPER_SCAN_MS (1000), FM_JCODE_KEEPER_BEAT_MS (5000),
// FM_JCODE_KEEPER_CHILD_MS (30000), FM_JCODE_KEEPER_BACKOFF_MS
// (comma list, default 1000,2000,5000,10000,30000).
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HOME = process.env.FM_HOME || "";
const API = process.env.JCODE_API_SOCKET || "";
if (!HOME || !API) {
  process.stderr.write("fm-jcode-keeper: FM_HOME and JCODE_API_SOCKET are required\n");
  process.exit(2);
}
const STATE = path.join(HOME, "state");
const JSTATE = path.join(STATE, "jcode");
const LIVE = path.join(JSTATE, "live");
const INJECTED = path.join(JSTATE, "injected");
const RECOVERED = path.join(JSTATE, "recovered");
const TRANSITIONS = path.join(JSTATE, "transitions");
const SCAN_MS = Number(process.env.FM_JCODE_KEEPER_SCAN_MS || 1000);
const BEAT_MS = Number(process.env.FM_JCODE_KEEPER_BEAT_MS || 5000);
const CHILD_MS = Number(process.env.FM_JCODE_KEEPER_CHILD_MS || 30000);
const IDLE_EXIT_MS = Number(process.env.FM_JCODE_KEEPER_IDLE_EXIT_SECS || 600) * 1000;
const BACKOFF = (process.env.FM_JCODE_KEEPER_BACKOFF_MS || "1000,2000,5000,10000,30000").split(",").map(Number);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const RECOVERY_TEXT =
  "Firstmate: your previous turn was interrupted by an infrastructure restart before it finished. Continue the task from where it stopped; re-run any command whose result you did not see.";

for (const d of [JSTATE, LIVE, INJECTED, RECOVERED]) fs.mkdirSync(d, { recursive: true });

const log = (msg) => {
  try {
    fs.appendFileSync(path.join(JSTATE, "keeper.log"), `${new Date().toISOString()} ${msg}\n`);
  } catch {
    // The log is best effort.
  }
};
const now = () => Math.floor(Date.now() / 1000);

// ---- single instance -------------------------------------------------------
function pidIsKeeper(pid) {
  try {
    const argv = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
    return argv.some((a) => a.endsWith("fm-jcode-keeper.mjs"));
  } catch {
    return false;
  }
}
const lockPath = path.join(JSTATE, "keeper.lock");
try {
  const fd = fs.openSync(lockPath, "wx");
  fs.writeSync(fd, `${process.pid}\n`);
  fs.closeSync(fd);
} catch {
  const holder = Number(fs.readFileSync(lockPath, "utf8").trim());
  if (holder && holder !== process.pid && pidIsKeeper(holder)) {
    process.stderr.write(`fm-jcode-keeper: another keeper (pid ${holder}) holds ${lockPath}\n`);
    process.exit(3);
  }
  fs.writeFileSync(lockPath, `${process.pid}\n`);
}
fs.writeFileSync(path.join(JSTATE, "keeper.pid"), `${process.pid}\n`);
const releaseAndExit = (code) => {
  try {
    const holder = Number(fs.readFileSync(lockPath, "utf8").trim());
    if (holder === process.pid) fs.unlinkSync(lockPath);
  } catch {
    // Already gone.
  }
  try {
    fs.unlinkSync(path.join(JSTATE, "keeper.beat"));
  } catch {
    // Already gone.
  }
  process.exit(code);
};
process.on("SIGTERM", () => releaseAndExit(0));
process.on("SIGINT", () => releaseAndExit(0));

// ---- records ---------------------------------------------------------------
const clean = (s) => String(s ?? "").replace(/[\t\r\n]+/g, " ");
function setLive(session, value) {
  fs.writeFileSync(path.join(LIVE, session), `${value} ${now()}\n`);
}
function readLive(session) {
  try {
    return fs.readFileSync(path.join(LIVE, session), "utf8").split(" ")[0];
  } catch {
    return "";
  }
}
function transition(session, from, to, detail) {
  fs.appendFileSync(TRANSITIONS, `${[session, "jcode", from, to, clean(detail).slice(0, 160)].join("\t")}\n`);
}

// ---- owned sessions --------------------------------------------------------
function metaValue(id, key) {
  try {
    const line = fs.readFileSync(path.join(STATE, `${id}.meta`), "utf8").split("\n").filter((l) => l.startsWith(`${key}=`)).pop();
    return line ? line.slice(key.length + 1) : "";
  } catch {
    return "";
  }
}
function ownedSessions() {
  const out = new Map();
  let names = [];
  try {
    names = fs.readdirSync(STATE);
  } catch {
    return out;
  }
  for (const name of names) {
    if (!name.endsWith(".jcode-session")) continue;
    const id = name.slice(0, -".jcode-session".length);
    if (!/^[A-Za-z0-9._-]+$/.test(id)) continue;
    if (metaValue(id, "backend") !== "jcode") continue;
    if (fs.existsSync(path.join(STATE, `${id}.jcode-exited`))) continue;
    let session = "";
    for (const line of fs.readFileSync(path.join(STATE, name), "utf8").split("\n")) {
      if (line.startsWith("session=")) session = line.slice(8);
    }
    if (/^[A-Za-z0-9_.-]+$/.test(session)) out.set(session, id);
  }
  return out;
}

// ---- wire ------------------------------------------------------------------
function connect(onFrame, onClose) {
  const sock = net.createConnection(API);
  let buffer = "";
  let nextId = 1;
  const pending = new Map();
  sock.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let i;
    while ((i = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, i).trim();
      buffer = buffer.slice(i + 1);
      if (!line) continue;
      let frame;
      try {
        frame = JSON.parse(line);
      } catch {
        continue;
      }
      if (frame.reply_to && pending.has(frame.reply_to)) {
        const p = pending.get(frame.reply_to);
        pending.delete(frame.reply_to);
        clearTimeout(p.timer);
        p.resolve(frame);
      } else onFrame(frame);
    }
  });
  let closed = false;
  const finish = (why) => {
    if (closed) return;
    closed = true;
    for (const p of pending.values()) {
      clearTimeout(p.timer);
      p.resolve(null);
    }
    pending.clear();
    onClose(why);
  };
  sock.on("error", (e) => finish(e.code || String(e)));
  sock.on("close", () => finish("closed"));
  const conn = {
    sock,
    request(req, ms = 15000) {
      return new Promise((resolve) => {
        if (closed) return resolve(null);
        const id = nextId++;
        const timer = setTimeout(() => {
          pending.delete(id);
          resolve(null);
        }, ms);
        pending.set(id, { resolve, timer });
        sock.write(`${JSON.stringify({ v: 1, id, ...req })}\n`);
      });
    },
    close() {
      sock.destroy();
    },
  };
  return new Promise((resolve) => {
    sock.once("connect", async () => {
      const hello = await conn.request({ req: "hello", min_version: 1, max_version: 1, client: "firstmate-keeper" });
      resolve(hello && hello.ev === "hello_ok" ? conn : null);
    });
    sock.once("error", () => resolve(null));
  });
}

// ---- per-session holders ---------------------------------------------------
const holders = new Map(); // session -> { id, conn, attempts, retryAt, attaching }

async function ensureBridge() {
  // Ask the lifecycle script to restart only the bridge; it never starts the daemon.
  return new Promise((resolve) => {
    const child = spawn(path.join(HERE, "fm-jcode-keeper.sh"), ["ensure", "--from-keeper"], {
      env: process.env,
      stdio: "ignore",
    });
    child.on("close", (code) => resolve(code === 0));
    child.on("error", () => resolve(false));
  });
}

function onEvent(session, frame) {
  switch (frame.ev) {
    case "message_accepted":
    case "connection_phase":
    case "tool_start":
      markBusy(session);
      break;
    case "session_status":
      if (frame.status === "running") markBusy(session);
      else if (frame.status === "idle") markIdle(session, null);
      break;
    case "turn_stopped": {
      const reason = frame.reason || "unknown";
      if (reason === "interrupted") markIdle(session, `turn_stopped ${reason}`);
      else {
        const was = readLive(session);
        setLive(session, "idle");
        transition(session, was, "blocked", `${reason} ${frame.message || ""}`);
      }
      break;
    }
    case "turn_done":
      markIdle(session, "turn_done");
      break;
    case "soft_interrupt_injected":
      for (const cid of frame.client_ids || []) {
        fs.appendFileSync(path.join(INJECTED, session), `${now()} ${clean(cid)} ${clean(frame.point)}\n`);
      }
      break;
    case "session_recovery":
      holders.get(session) && (holders.get(session).recovery = true);
      break;
    default:
  }
}
function markBusy(session) {
  const was = readLive(session);
  if (was === "busy") return;
  setLive(session, "busy");
  transition(session, was || "idle", "working", "busy");
}
function markIdle(session, detail) {
  const was = readLive(session);
  if (was === "idle") return;
  setLive(session, "idle");
  transition(session, was, "idle", detail || "idle");
}

async function attach(session, h) {
  h.attaching = true;
  const conn = await connect(
    (frame) => {
      if (frame.session_id === session || frame.ev === "soft_interrupt_injected") onEvent(session, frame);
    },
    (why) => {
      if (holders.get(session) === h) {
        h.conn = null;
        setLive(session, "unknown");
        log(`session ${session} connection closed (${why})`);
      }
    },
  );
  if (!conn) {
    h.attaching = false;
    h.attempts += 1;
    h.retryAt = Date.now() + BACKOFF[Math.min(h.attempts - 1, BACKOFF.length - 1)];
    if (h.attempts % 2 === 1) ensureBridge().catch(() => {});
    return;
  }
  const attached = await conn.request({ req: "attach_session", session_id: session });
  if (!attached || attached.ev !== "attached") {
    conn.close();
    h.attaching = false;
    h.attempts += 1;
    h.retryAt = Date.now() + BACKOFF[Math.min(h.attempts - 1, BACKOFF.length - 1)];
    log(`attach ${session} refused: ${attached ? attached.message || attached.ev : "no reply"}`);
    return;
  }
  h.conn = conn;
  h.attempts = 0;
  h.attaching = false;
  // Memory-off is not durable once nothing holds the session (G6): re-apply on every attach.
  await conn.request({ req: "runtime_command", session_id: session, command: "memory", args: ["off"] });
  if (!readLive(session) || readLive(session) === "unknown") setLive(session, "idle");
  log(`attached ${session}`);
}

// ---- children discovery (D13) ---------------------------------------------
let childConn = null;
async function discoverChildren() {
  const owned = ownedSessions();
  if (!owned.size) return;
  if (!childConn) {
    childConn = await connect(() => {}, () => {
      childConn = null;
    });
    if (!childConn) return;
  }
  const reply = await childConn.request({ req: "list_sessions" });
  if (!reply || reply.ev !== "sessions") return;
  for (const s of reply.sessions || []) {
    const parentTask = s.parent_session_id && owned.get(s.parent_session_id);
    if (!parentTask || s.archived) continue;
    const file = path.join(STATE, `${parentTask}.jcode-children`);
    let known = "";
    try {
      known = fs.readFileSync(file, "utf8");
    } catch {
      // First child.
    }
    if (known.split("\n").some((l) => l.split("\t")[0] === s.session_id)) continue;
    fs.appendFileSync(file, `${[s.session_id, clean(s.agent_label), clean(s.working_dir)].join("\t")}\n`);
  }
}

// ---- main loop ---------------------------------------------------------------
let emptySince = Date.now();
async function scan() {
  const owned = ownedSessions();
  for (const [session, id] of owned) {
    let h = holders.get(session);
    if (!h) {
      h = { id, conn: null, attempts: 0, retryAt: 0, attaching: false };
      holders.set(session, h);
    }
    if (!h.conn && !h.attaching && Date.now() >= h.retryAt) attach(session, h);
  }
  for (const [session, h] of [...holders]) {
    if (owned.has(session)) continue;
    h.conn?.close();
    holders.delete(session);
  }
  if (owned.size) emptySince = Date.now();
  else if (Date.now() - emptySince >= IDLE_EXIT_MS) {
    log("no bound sessions; exiting");
    releaseAndExit(0);
  }
}

const beat = () => fs.writeFileSync(path.join(JSTATE, "keeper.beat"), `${now()}\n`);
beat();
log(`keeper started pid=${process.pid} api=${API}`);
setInterval(beat, BEAT_MS);
setInterval(() => scan().catch((e) => log(`scan: ${e?.message || e}`)), SCAN_MS);
setInterval(() => discoverChildren().catch((e) => log(`children: ${e?.message || e}`)), CHILD_MS);
scan().catch(() => {});
