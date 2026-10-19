#!/usr/bin/env node
// fm-jcode-api.mjs - minimal, dependency-free client for the jcode harness API.
//
// Speaks protocol v1 NDJSON over `jcode api-bridge --stdio`, which dials the
// daemon this process's environment selects (JCODE_SOCKET / JCODE_RUNTIME_DIR /
// JCODE_HOME), so a jcode hook process reaches exactly the daemon that ran it.
// It deliberately carries no npm dependency: the published @1jehuang/jcode-sdk
// is the reference client, and this file mirrors only the frames it needs.
//
// One connection is attached to one session at a time (a request for another
// session answers unknown_session), so every session verb attaches first.
// A turn whose only attached client disconnects is abandoned by the daemon
// (verified, jcode v0.98.1), so a verb that starts a turn (`send`, `remind`)
// must only be used while another client - the worker's TUI - stays attached;
// this process exits as soon as the daemon accepts the request.
//
// Usage:
//   fm-jcode-api.mjs create <working-dir> [--model <id>] [--effort <level>] [--note <text>]
//                                             create an idle session in that
//                                             directory and print its id. A
//                                             created session lives only in the
//                                             daemon's memory until it holds a
//                                             message, and is gone once this
//                                             connection closes, so the note
//                                             (default: a one-line Firstmate
//                                             marker) is stored as a no-reply
//                                             user message, which persists the
//                                             session for `jcode --resume`
//                                             without starting a turn (verified,
//                                             jcode v0.98.1). A refused model
//                                             archives the new session and exits
//                                             1; a refused effort keeps the
//                                             session on its default and warns on
//                                             stderr.
//   fm-jcode-api.mjs send <session-id>        read text on stdin and submit it
//                                             as a user message, which starts a
//                                             turn. Exit 0 once accepted.
//   fm-jcode-api.mjs remind <session-id>      read reminder text on stdin; submit
//                                             it to that session as a hidden
//                                             system reminder, which starts a turn
//                                             on an idle session (verified, jcode
//                                             v0.98.1). Exit 0 once the daemon
//                                             accepts the message.
//   fm-jcode-api.mjs cancel <session-id>      stop the session's running turn and
//                                             print `cancelled` once the turn has
//                                             really ended (turn_done), or
//                                             `not-running` when it was idle. A
//                                             cancel from a connection that did
//                                             not start the turn is cooperative
//                                             and the daemon clears it 500 ms
//                                             later, so one request can lose that
//                                             race (verified, jcode v0.98.1); the
//                                             request repeats on this connection
//                                             until turn_done, bounded by
//                                             FM_JCODE_CANCEL_WAIT_MS (10000), and
//                                             prints `unconfirmed` with exit 1
//                                             when the turn never reports done.
//   fm-jcode-api.mjs archive <session-id>     reversibly hide the session from
//                                             the daemon's listing.
//   fm-jcode-api.mjs session-exists <id>      exit 0 when the daemon lists <id>.
//   fm-jcode-api.mjs status <session-id>      attach and print the first
//                                             non-attached session_status value
//                                             (`running`, `idle`, ...).
//
// Exit codes: 0 success, 1 refused or not found, 2 usage, 3 transport failure.
// Every failure prints one line on stderr and never retries.
import { spawn } from "node:child_process";

const TIMEOUT_MS = Number(process.env.FM_JCODE_API_TIMEOUT_MS || 15000);
const VERBS = ["create", "send", "remind", "cancel", "archive", "session-exists", "status"];
const [verb, target, ...rest] = process.argv.slice(2);

function usage(message) {
  process.stderr.write(
    `fm-jcode-api: ${message}\nusage: fm-jcode-api.mjs create <working-dir> [--model <id>] [--effort <level>] [--note <text>] | ${VERBS.slice(1).join("|")} <session-id>\n`,
  );
  process.exit(2);
}

if (!verb || !target) usage("missing arguments");
if (!VERBS.includes(verb)) usage(`unknown verb ${verb}`);
const options = {};
const allowed = verb === "create" ? ["--model", "--effort", "--note"] : [];
for (let i = 0; i < rest.length; i += 2) {
  const key = rest[i];
  const value = rest[i + 1];
  if (!allowed.includes(key) || !value) usage(`unexpected argument ${key}`);
  options[key.slice(2)] = value;
}
if (verb !== "create" && !/^[A-Za-z0-9_.-]+$/.test(target)) usage("invalid session id");

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
  const text = verb === "remind" || verb === "send" ? await readStdin() : "";
  if ((verb === "remind" || verb === "send") && !text) usage(`empty ${verb === "send" ? "message" : "reminder"} on stdin`);
  const bridge = openBridge();
  const fail = (code, message) => {
    process.stderr.write(`fm-jcode-api: ${message}\n`);
    bridge.close();
    process.exit(code);
  };
  // Send one request and wait for its reply frame (or an error naming it).
  const request = async (frame, what) => {
    const id = bridge.send(frame);
    const reply = await bridge.wait((f) => f.reply_to === id);
    if (!reply) fail(3, `${what} timed out`);
    return reply;
  };
  const hello = await request({ req: "hello", min_version: 1, max_version: 1, client: "firstmate" }, "handshake");
  if (hello.ev !== "hello_ok") fail(3, `handshake refused: ${hello.message || hello.ev}`);

  if (verb === "session-exists") {
    const reply = await request({ req: "list_sessions" }, "list_sessions");
    if (reply.ev !== "sessions") fail(3, "list_sessions failed");
    const found = (reply.sessions || []).some((s) => s.session_id === target);
    bridge.close();
    process.exit(found ? 0 : 1);
  }

  if (verb === "create") {
    const created = await request({ req: "create_session", working_dir: target }, "create_session");
    if (created.ev !== "attached" || !created.session?.session_id) {
      fail(1, `create_session refused: ${created.message || created.ev}`);
    }
    const sessionId = created.session.session_id;
    if (options.model) {
      const reply = await request({ req: "set_model", session_id: sessionId, model: options.model }, "set_model");
      if (reply.ev !== "ok") {
        await request({ req: "archive_session", session_id: sessionId }, "archive_session");
        fail(1, `model ${options.model} refused: ${reply.message || reply.ev}`);
      }
    }
    if (options.effort) {
      const reply = await request({ req: "set_reasoning_effort", session_id: sessionId, effort: options.effort }, "set_reasoning_effort");
      if (reply.ev !== "ok") {
        process.stderr.write(`fm-jcode-api: reasoning effort ${options.effort} refused (${reply.message || reply.ev}); the session keeps its default\n`);
      }
    }
    const note = options.note || "Firstmate worker session. The launch brief follows as the next message.";
    const persisted = await request({ req: "send_message", session_id: sessionId, content: note, no_reply: true }, "send_message");
    if (persisted.ev !== "ok") {
      await request({ req: "archive_session", session_id: sessionId }, "archive_session");
      fail(1, `the session could not be persisted: ${persisted.message || persisted.ev}`);
    }
    process.stdout.write(`${sessionId}\n`);
    bridge.close();
    process.exit(0);
  }

  if (verb === "archive") {
    const reply = await request({ req: "archive_session", session_id: target }, "archive_session");
    if (reply.ev !== "ok") fail(1, `archive_session refused: ${reply.message || reply.ev}`);
    bridge.close();
    process.exit(0);
  }

  const attached = await request({ req: "attach_session", session_id: target }, "attach_session");
  if (attached.ev !== "attached") fail(1, `attach_session refused: ${attached.message || attached.ev}`);

  if (verb === "status") {
    const status = await bridge.wait(
      (f) => f.ev === "session_status" && f.session_id === target && f.status !== "attached",
      2000,
    );
    if (!status) fail(3, "no session_status was reported");
    process.stdout.write(`${status.status}\n`);
    bridge.close();
    process.exit(0);
  }

  if (verb === "cancel") {
    // The attach announces the session's state: `running` while a turn is in
    // flight, `idle` otherwise (`attached` is only this connection's own).
    const status = await bridge.wait(
      (f) => f.ev === "session_status" && f.session_id === target && f.status !== "attached",
      500,
    );
    if (status && status.status !== "running") {
      process.stdout.write("not-running\n");
      bridge.close();
      process.exit(0);
    }
    const isDone = (f) => f.ev === "turn_done" && f.session_id === target;
    const deadline = Date.now() + Number(process.env.FM_JCODE_CANCEL_WAIT_MS || 10000);
    let done = null;
    while (!done && Date.now() < deadline) {
      const reply = await request({ req: "cancel", session_id: target }, "cancel");
      if (reply.ev !== "ok") fail(1, `cancel refused: ${reply.message || reply.ev}`);
      done = await bridge.wait(isDone, 300);
    }
    if (!done) {
      process.stdout.write("unconfirmed\n");
      bridge.close();
      process.exit(1);
    }
    // The daemon clears a non-owner cancel 500 ms after it fires; wait that out
    // so the last request cannot abort a turn that starts right after this one.
    await new Promise((resolve) => setTimeout(resolve, 600));
    process.stdout.write("cancelled\n");
    bridge.close();
    process.exit(0);
  }

  const message = verb === "send"
    ? { req: "send_message", session_id: target, content: text }
    : { req: "send_message", session_id: target, content: "", system_reminder: text };
  const send = bridge.send(message);
  const accepted = await bridge.wait(
    (f) => f.reply_to === send || (f.ev === "message_accepted" && f.session_id === target) || (f.ev === "error" && f.reply_to === send),
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
