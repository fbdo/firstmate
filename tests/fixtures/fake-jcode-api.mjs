#!/usr/bin/env node
// fake-jcode-api.mjs - a fake jcode daemon API for the portable jcode tests.
//
//   fake-jcode-api.mjs serve <socket> <dir>    speak protocol v1 NDJSON on <socket>
//   fake-jcode-api.mjs proxy <listen> <target> stand in for `jcode api-bridge
//                                              --api-socket`: forward each
//                                              connection to <target>, tell the
//                                              client "daemon connection closed"
//                                              when the target dies, and stay up
//
// <dir> holds: state.json (sessions, survives a restart), requests.log (one JSON
// request per line), ctl (control commands, one per line, consumed), and an
// optional script.json ({"turn_ms": 50, "hold": false}).
// Control commands: `child <parent> <label> [dir]` (add a session with
// parent_session_id), `finish <session>`, `stop <session> <reason> [message]`,
// `drop` (close every connection, keep listening), `crash` (close everything
// and exit non-zero, leaving a stale socket file behind).
//
// It enforces the real retention rule (verified, jcode v0.99.0): a running turn
// whose session has no attached connection left is abandoned, so the history
// keeps the user row and gains no assistant row, and the session reads idle.
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const [mode, listenPath, other] = process.argv.slice(2);

function lines(socket, onLine) {
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let i;
    while ((i = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, i).trim();
      buffer = buffer.slice(i + 1);
      if (line) onLine(line);
    }
  });
}

if (mode === "proxy") {
  try { fs.unlinkSync(listenPath); } catch { /* absent */ }
  net
    .createServer((client) => {
      const upstream = net.createConnection(other);
      let up = false;
      upstream.on("connect", () => { up = true; });
      upstream.on("error", () => {
        if (!client.destroyed) client.destroy();
      });
      upstream.on("close", () => {
        if (up && !client.destroyed) {
          client.write(`${JSON.stringify({ v: 1, ev: "error", code: "internal", message: "daemon connection closed" })}\n`);
          client.end();
        } else if (!client.destroyed) client.destroy();
      });
      upstream.pipe(client);
      client.pipe(upstream);
      client.on("close", () => upstream.destroy());
      client.on("error", () => upstream.destroy());
    })
    .listen(listenPath);
} else if (mode === "serve") {
  const dir = other;
  fs.mkdirSync(dir, { recursive: true });
  const statePath = path.join(dir, "state.json");
  const logPath = path.join(dir, "requests.log");
  const ctlPath = path.join(dir, "ctl");
  let sessions = {};
  try { sessions = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch { /* fresh */ }
  for (const s of Object.values(sessions)) s.status = "idle";
  const running = {}; // session -> timer or "hold"
  const attached = {}; // session -> Set of sockets
  const conns = new Set();
  const save = () => fs.writeFileSync(statePath, JSON.stringify(sessions));
  const script = () => {
    try { return JSON.parse(fs.readFileSync(path.join(dir, "script.json"), "utf8")); } catch { return {}; }
  };
  const emit = (socket, frame) => { if (!socket.destroyed) socket.write(`${JSON.stringify({ v: 1, ...frame })}\n`); };
  const broadcast = (id, frame) => { for (const s of attached[id] || []) emit(s, frame); };
  const info = (id) => ({
    session_id: id,
    working_dir: sessions[id].working_dir,
    status: sessions[id].status,
    archived: !!sessions[id].archived,
    title: sessions[id].title,
    parent_session_id: sessions[id].parent,
    agent_label: sessions[id].label,
  });
  // memory is per session and resets when the last connection holding it closes
  // (verified, jcode v0.99.0); swarm is per connection.
  const memory = {}; // session -> boolean while held
  const swarmOf = new Map(); // socket -> boolean
  const endTurn = (id, assistant) => {
    if (running[id] && running[id] !== "hold") clearTimeout(running[id]);
    delete running[id];
    sessions[id].status = "idle";
    if (assistant) sessions[id].history.push({ role: "assistant", content: assistant });
    save();
  };
  const startTurn = (id, content) => {
    sessions[id].history.push({ role: "user", content });
    sessions[id].status = "running";
    save();
    broadcast(id, { ev: "session_status", session_id: id, status: "running" });
    broadcast(id, { ev: "connection_phase", session_id: id, phase: "streaming" });
    broadcast(id, { ev: "tool_start", session_id: id, id: "t1", name: "bash" });
    const cfg = script();
    if (cfg.hold) { running[id] = "hold"; return; }
    running[id] = setTimeout(() => {
      endTurn(id, "ok");
      broadcast(id, { ev: "turn_done", session_id: id });
      broadcast(id, { ev: "session_status", session_id: id, status: "idle" });
    }, Number(cfg.turn_ms ?? 50));
  };
  const handle = (socket, line) => {
    let req;
    try { req = JSON.parse(line); } catch { return; }
    fs.appendFileSync(logPath, `${JSON.stringify(req)}\n`);
    const reply = (frame) => emit(socket, { reply_to: req.id, ...frame });
    const err = (code, message) => reply({ ev: "error", code, message });
    const id = req.session_id;
    const known = () => {
      if (!id || !sessions[id] || sessions[id].archived) { err("unknown_session", `unknown session ${id}`); return false; }
      return true;
    };
    switch (req.req) {
      case "hello": return reply({ ev: "hello_ok", version: 1 });
      case "list_sessions": return reply({ ev: "sessions", sessions: Object.keys(sessions).map(info) });
      case "create_session": {
        const sid = `session_fake_${Object.keys(sessions).length + 1}`;
        sessions[sid] = { history: [], status: "idle", working_dir: req.working_dir };
        (attached[sid] ||= new Set()).add(socket);
        save();
        return reply({ ev: "attached", session: info(sid) });
      }
      case "set_model": return known() && (req.model === "bad-model" ? err("invalid_request", "model not supported") : reply({ ev: "ok" }));
      case "set_reasoning_effort": return known() && reply({ ev: "ok" });
      case "attach_session": {
        if (!known()) return;
        (attached[id] ||= new Set()).add(socket);
        reply({ ev: "attached", session: info(id) });
        if (sessions[id].crashed) {
          sessions[id].crashed = false;
          save();
          emit(socket, { ev: "session_recovery", session_id: id, message: "interrupted by a server reload while a tool was running" });
        }
        emit(socket, { ev: "session_status", session_id: id, status: "attached" });
        emit(socket, { ev: "session_status", session_id: id, status: sessions[id].status });
        return;
      }
      case "detach_session": attached[id]?.delete(socket); return reply({ ev: "ok" });
      case "send_message": {
        if (!known()) return;
        if (req.no_reply) {
          sessions[id].history.push({ role: "user", content: req.content });
          save();
          return reply({ ev: "ok" });
        }
        emit(socket, { ev: "message_accepted", session_id: id });
        startTurn(id, req.content);
        return;
      }
      case "soft_interrupt": {
        if (!known()) return;
        reply({ ev: "ok" });
        if (sessions[id].status !== "running") {
          startTurn(id, req.content);
          broadcast(id, { ev: "soft_interrupt_injected", session_id: id, point: "turn_start", client_ids: [req.client_id] });
        } else {
          sessions[id].history.push({ role: "user", content: req.content });
          save();
          broadcast(id, { ev: "soft_interrupt_injected", session_id: id, point: "D", client_ids: [req.client_id] });
        }
        return;
      }
      case "cancel": {
        if (!known()) return;
        reply({ ev: "ok" });
        if (sessions[id].status === "running") {
          endTurn(id, "");
          broadcast(id, { ev: "turn_stopped", session_id: id, reason: "interrupted", message: "cancelled" });
          broadcast(id, { ev: "turn_done", session_id: id });
          broadcast(id, { ev: "session_status", session_id: id, status: "idle" });
        }
        return;
      }
      case "rename_session": {
        if (!known()) return;
        sessions[id].title = req.title;
        save();
        reply({ ev: "ok" });
        return broadcast(id, { ev: "session_renamed", session_id: id, display_title: req.title });
      }
      case "runtime_command": {
        if (!known()) return;
        if (req.command === "memory") {
          if (req.args?.[0] === "off") memory[id] = false;
          else if (req.args?.[0] === "on") memory[id] = true;
          return reply({ ev: "runtime_command_result", data: { enabled: memory[id] ?? true } });
        }
        if (req.command === "swarm") {
          if (req.args?.[0] === "off") swarmOf.set(socket, false);
          return reply({ ev: "runtime_command_result", data: { enabled: swarmOf.get(socket) ?? true } });
        }
        return err("invalid_request", `unknown runtime command ${req.command}`);
      }
      case "get_history": return known() && reply({ ev: "history", session_id: id, messages: sessions[id].history });
      case "archive_session": {
        if (!id || !sessions[id]) return err("unknown_session", `unknown session ${id}`);
        sessions[id].archived = true;
        save();
        return reply({ ev: "ok" });
      }
      default: return err("unknown_request", `unknown request ${req.req}`);
    }
  };
  const abandonIfOrphaned = (id) => {
    if (running[id] && (!attached[id] || attached[id].size === 0)) {
      endTurn(id, "");
      sessions[id].crashed = true;
      save();
    }
    if (!attached[id] || attached[id].size === 0) delete memory[id];
  };
  const server = net.createServer((socket) => {
    conns.add(socket);
    socket.on("close", () => swarmOf.delete(socket));
    lines(socket, (line) => handle(socket, line));
    socket.on("error", () => {});
    socket.on("close", () => {
      conns.delete(socket);
      for (const id of Object.keys(attached)) {
        if (attached[id].delete(socket)) abandonIfOrphaned(id);
      }
    });
  });
  try { fs.unlinkSync(listenPath); } catch { /* absent */ }
  server.listen(listenPath);
  const ctl = () => {
    let text;
    try { text = fs.readFileSync(ctlPath, "utf8"); fs.unlinkSync(ctlPath); } catch { return; }
    for (const line of text.split("\n").filter(Boolean)) {
      const [cmd, id, reason, ...msg] = line.split(" ");
      if (cmd === "finish" && sessions[id] && running[id]) {
        endTurn(id, "ok");
        broadcast(id, { ev: "turn_done", session_id: id });
        broadcast(id, { ev: "session_status", session_id: id, status: "idle" });
      } else if (cmd === "stop" && sessions[id]) {
        endTurn(id, "");
        broadcast(id, { ev: "turn_stopped", session_id: id, reason: reason || "failure", message: msg.join(" ") || "boom" });
        broadcast(id, { ev: "session_status", session_id: id, status: "idle" });
      } else if (cmd === "child" && sessions[id]) {
        const sid = `session_fake_${Object.keys(sessions).length + 1}`;
        sessions[sid] = { history: [], status: "idle", working_dir: msg[0] || sessions[id].working_dir, parent: id, label: reason };
        save();
      } else if (cmd === "drop") {
        for (const s of [...conns]) s.destroy();
      } else if (cmd === "crash") {
        for (const s of [...conns]) s.destroy();
        process.exit(1);
      }
    }
  };
  setInterval(ctl, 50);
  process.on("SIGTERM", () => process.exit(0));
} else {
  process.stderr.write("usage: fake-jcode-api.mjs serve <socket> <dir> | proxy <listen> <target>\n");
  process.exit(2);
}
