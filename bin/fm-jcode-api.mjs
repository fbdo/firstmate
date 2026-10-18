#!/usr/bin/env node
// fm-jcode-api.mjs - minimal, dependency-free client for the jcode harness API.
//
// Speaks protocol v1 NDJSON over `jcode api-bridge --stdio`, which dials the
// daemon this process's environment selects (JCODE_SOCKET / JCODE_RUNTIME_DIR /
// JCODE_HOME), so a jcode hook process reaches exactly the daemon that ran it.
// It deliberately carries no npm dependency: the published @1jehuang/jcode-sdk
// is the reference client, and this file mirrors only the frames it needs.
//
// Usage:
//   fm-jcode-api.mjs remind <session-id>      read reminder text on stdin; submit
//                                             it to that session as a hidden
//                                             system reminder, which starts a turn
//                                             on an idle session (verified, jcode
//                                             v0.98.1). Exit 0 once the daemon
//                                             accepts the message.
//   fm-jcode-api.mjs session-exists <id>      exit 0 when the daemon lists <id>.
//
// Exit codes: 0 success, 1 refused or not found, 2 usage, 3 transport failure.
// Every failure prints one line on stderr and never retries.
import { spawn } from "node:child_process";

const TIMEOUT_MS = Number(process.env.FM_JCODE_API_TIMEOUT_MS || 15000);
const [verb, sessionId] = process.argv.slice(2);

function usage(message) {
  process.stderr.write(`fm-jcode-api: ${message}\nusage: fm-jcode-api.mjs remind <session-id> | session-exists <session-id>\n`);
  process.exit(2);
}

if (!verb || !sessionId) usage("missing arguments");
if (!/^[A-Za-z0-9_.-]+$/.test(sessionId)) usage("invalid session id");
if (verb !== "remind" && verb !== "session-exists") usage(`unknown verb ${verb}`);

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8").trim();
}

function openBridge() {
  const binary = process.env.FM_JCODE_BIN || "jcode";
  const child = spawn(binary, ["--quiet", "--no-update", "api-bridge", "--stdio"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  const frames = [];
  const waiters = [];
  let buffer = "";
  let closed = false;
  let stderr = "";
  const settle = () => {
    for (let i = waiters.length - 1; i >= 0; i--) {
      const w = waiters[i];
      const frame = frames.find(w.predicate);
      if (frame || closed) {
        waiters.splice(i, 1);
        clearTimeout(w.timer);
        w.resolve(frame || null);
      }
    }
  };
  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let index;
    while ((index = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      try {
        frames.push(JSON.parse(line));
      } catch {
        // A malformed frame is ignored; the waiter times out instead.
      }
    }
    settle();
  });
  child.stderr.on("data", (chunk) => {
    stderr = (stderr + chunk.toString("utf8")).slice(-2000);
  });
  child.on("error", () => {
    closed = true;
    settle();
  });
  child.on("close", () => {
    closed = true;
    settle();
  });
  let nextId = 1;
  return {
    send(request) {
      const id = nextId++;
      child.stdin.write(`${JSON.stringify({ v: 1, id, ...request })}\n`);
      return id;
    },
    wait(predicate, ms = TIMEOUT_MS) {
      return new Promise((resolve) => {
        const frame = frames.find(predicate);
        if (frame || closed) return resolve(frame || null);
        const timer = setTimeout(() => {
          const i = waiters.findIndex((w) => w.timer === timer);
          if (i !== -1) waiters.splice(i, 1);
          resolve(null);
        }, ms);
        waiters.push({ predicate, resolve, timer });
      });
    },
    close() {
      try {
        child.stdin.end();
      } catch {
        // Already closed.
      }
      setTimeout(() => child.kill(), 200).unref();
    },
    lastStderr: () => stderr.trim().split("\n").pop() || "",
  };
}

async function main() {
  const reminder = verb === "remind" ? await readStdin() : "";
  if (verb === "remind" && !reminder) usage("empty reminder on stdin");
  const bridge = openBridge();
  const fail = (code, message) => {
    process.stderr.write(`fm-jcode-api: ${message}\n`);
    bridge.close();
    process.exit(code);
  };
  const hello = bridge.send({ req: "hello", min_version: 1, max_version: 1, client: "firstmate-jcode-hook" });
  const helloReply = await bridge.wait((f) => f.reply_to === hello);
  if (!helloReply) fail(3, `no handshake from jcode api-bridge (${bridge.lastStderr() || "no output"})`);
  if (helloReply.ev !== "hello_ok") fail(3, `handshake refused: ${helloReply.message || helloReply.ev}`);

  if (verb === "session-exists") {
    const list = bridge.send({ req: "list_sessions" });
    const reply = await bridge.wait((f) => f.reply_to === list);
    if (!reply || reply.ev !== "sessions") fail(3, "list_sessions failed");
    const found = (reply.sessions || []).some((s) => s.session_id === sessionId);
    bridge.close();
    process.exit(found ? 0 : 1);
  }

  const attach = bridge.send({ req: "attach_session", session_id: sessionId });
  const attached = await bridge.wait((f) => f.reply_to === attach);
  if (!attached) fail(3, "attach_session timed out");
  if (attached.ev !== "attached") fail(1, `attach_session refused: ${attached.message || attached.ev}`);
  const send = bridge.send({ req: "send_message", session_id: sessionId, content: "", system_reminder: reminder });
  const accepted = await bridge.wait(
    (f) => f.reply_to === send || (f.ev === "message_accepted" && f.session_id === sessionId) || (f.ev === "error" && f.reply_to === send),
  );
  if (!accepted) fail(3, "send_message was not acknowledged");
  if (accepted.ev === "error") fail(1, `send_message refused: ${accepted.message || "error"}`);
  bridge.close();
  process.exit(0);
}

main().catch((error) => {
  process.stderr.write(`fm-jcode-api: ${error?.message || error}\n`);
  process.exit(3);
});
