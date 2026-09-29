import assert from "node:assert/strict";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin, {
  aggregateState,
  closeIsEligible,
  createPlugin,
  environmentIsValid,
  send,
  turnEventID,
} from "../../Argus/Resources/ArgusKiloTurnCompletionPlugin.js";

assert.equal(environmentIsValid({}), false);
assert.equal(environmentIsValid({ ARGUS_SOCKET_PATH: "socket", ARGUS_WORKSPACE_ID: "workspace", ARGUS_SURFACE_ID: "surface" }), true);
const eligibleState = { candidateID: "user", activity: true, synthetic: false, compaction: false, closed: false };
assert.equal(closeIsEligible({ reason: "completed" }, eligibleState, true), true);
assert.equal(closeIsEligible({ reason: "completed" }, eligibleState, false), false);
assert.equal(closeIsEligible({ reason: "error" }, eligibleState, true), false);
assert.equal(closeIsEligible({ reason: "interrupted" }, eligibleState, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, activity: false }, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, synthetic: true }, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, compaction: true }, true), false);
assert.notEqual(turnEventID("session", "user", 1), turnEventID("session", "user", 2));
const none = { pending: new Map(), busy: new Set(), errored: new Set() };
assert.equal(aggregateState(none), "idle");
assert.equal(aggregateState({ ...none, errored: new Set(["s"]) }), "error");
assert.equal(aggregateState({ ...none, errored: new Set(["s"]), busy: new Set(["s"]) }), "running");
assert.equal(aggregateState({ ...none, busy: new Set(["s"]), pending: new Map([["p", "s"]]) }), "needsInput");

const deliveries = [];
const handlers = new Map();
const roots = new Set(["root", "synthetic", "failed", "interrupted", "idle"]);
const environment = {
  ARGUS_SOCKET_PATH: "/tmp/argus.sock",
  ARGUS_WORKSPACE_ID: "workspace-id",
  ARGUS_SURFACE_ID: "surface-id",
};
const api = {
  event: { on(name, handler) { handlers.set(name, handler); return () => {}; } },
  lifecycle: { onDispose() {} },
  client: { session: { async get({ sessionID }) { return roots.has(sessionID) ? { data: { id: sessionID } } : { data: { id: sessionID, parentID: "root" } }; } } },
};
createPlugin({ environment, instanceID: "test", transport: async (socketPath, payload) => { deliveries.push({ socketPath, payload }); } }).tui(api);
const completions = () => deliveries.filter(({ payload }) => payload.method === "agent.turnCompleted");
assert(handlers.has("message.updated"));
assert(handlers.has("message.part.updated"));
assert(handlers.has("session.status"));
assert(handlers.has("session.turn.open"));
assert(handlers.has("session.turn.close"));
async function closeTurn(sessionID, { reason = "completed", synthetic = false, compaction = false, active = true } = {}) {
  handlers.get("session.turn.open")({ properties: { sessionID } });
  handlers.get("message.updated")({ properties: { info: { id: `user-${sessionID}`, sessionID, role: "user", synthetic } } });
  if (compaction) handlers.get("message.part.updated")({ properties: { part: { sessionID, type: "compaction" } } });
  if (active) handlers.get("session.status")({ properties: { sessionID, status: { type: "busy" } } });
  await handlers.get("session.turn.close")({ properties: { sessionID, reason } });
}

await closeTurn("root");
await closeTurn("child");
await closeTurn("synthetic", { synthetic: true });
await closeTurn("failed", { reason: "error" });
await closeTurn("interrupted", { reason: "interrupted" });
await closeTurn("idle", { active: false });
await closeTurn("compaction", { compaction: true });

assert.equal(completions().length, 1);
assert.deepEqual(completions()[0], {
  socketPath: environment.ARGUS_SOCKET_PATH,
  payload: {
    version: 1,
    id: "kilo:root:user-root:1",
    method: "agent.turnCompleted",
    params: {
      agentKey: "kilo",
      workspaceId: environment.ARGUS_WORKSPACE_ID,
      surfaceId: environment.ARGUS_SURFACE_ID,
      eventId: "kilo:root:user-root:1",
    },
  },
});

assert.equal(plugin.id, "argus-turn-completed");

// Live Agent Status: one reporting session per plugin instance, sent only on change.
{
  const sent = [];
  const statusHandlers = new Map();
  let dispose;
  const statusAPI = {
    event: { on(name, handler) { statusHandlers.set(name, handler); return () => {}; } },
    lifecycle: { onDispose(fn) { dispose = fn; } },
    client: { session: { async get({ sessionID }) { return { data: sessionID === "child" ? { parentID: "root" } : {} }; } } },
  };
  createPlugin({ environment, instanceID: "status", transport: async (_socketPath, payload) => { sent.push(payload); } }).tui(statusAPI);
  const emit = (name, properties) => statusHandlers.get(name)({ properties });
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  const states = () => sent.filter((payload) => payload.method === "agent.statusChanged").map((payload) => payload.params.state);

  emit("session.turn.open", { sessionID: "root" });
  emit("session.status", { sessionID: "root", status: { type: "busy" } });
  emit("session.status", { sessionID: "child", status: { type: "busy" } });
  emit("permission.asked", { id: "perm", sessionID: "child" });
  emit("permission.replied", { sessionID: "child", requestID: "perm" });
  emit("session.idle", { sessionID: "child" });
  emit("question.asked", { id: "question", sessionID: "root" });
  emit("question.rejected", { sessionID: "root", requestID: "question" });
  emit("session.status", { sessionID: "root", status: { type: "idle" } });
  await statusHandlers.get("session.turn.close")({ properties: { sessionID: "root", reason: "error" } });
  emit("session.turn.open", { sessionID: "root" });
  await statusHandlers.get("session.turn.close")({ properties: { sessionID: "root", reason: "interrupted" } });
  await flush();
  assert.deepEqual(states(), ["idle", "running", "needsInput", "running", "needsInput", "running", "idle", "error", "running", "idle"]);

  const first = sent[0];
  assert.deepEqual(first, {
    version: 1,
    id: "kilo:changed:kilo:status:1",
    method: "agent.statusChanged",
    params: {
      agentKey: "kilo",
      workspaceId: environment.ARGUS_WORKSPACE_ID,
      surfaceId: environment.ARGUS_SURFACE_ID,
      state: "idle",
      sessionId: "kilo:status",
      sequence: 1,
    },
  });
  const sequences = sent.map((payload) => payload.params.sequence);
  assert.deepEqual(sequences, sequences.map((_, index) => index + 1));

  await dispose();
  const cleared = sent.at(-1);
  assert.equal(cleared.method, "agent.statusCleared");
  assert.equal(cleared.params.sessionId, "kilo:status");
  assert.equal(cleared.params.state, undefined);
}

// A failing transport never rejects into Kilo's event handlers.
{
  const failingHandlers = new Map();
  createPlugin({ environment, transport: async () => { throw new Error("offline"); } }).tui({
    event: { on(name, handler) { failingHandlers.set(name, handler); return () => {}; } },
    lifecycle: { onDispose() {} },
    client: { session: { async get() { return { data: {} }; } } },
  });
  failingHandlers.get("session.turn.open")({ properties: { sessionID: "root" } });
  await failingHandlers.get("session.turn.close")({ properties: { sessionID: "root", reason: "completed" } });
}

const socketPath = join(tmpdir(), `argus-kilo-transport-${process.pid}-${Date.now()}.sock`);
let serverReleasedConnection = false;
const server = createServer({ allowHalfOpen: true }, (socket) => {
  socket.on("data", () => {});
  setTimeout(() => {
    serverReleasedConnection = true;
    socket.end();
  }, 30);
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});
await send(socketPath, { version: 1 });
assert.equal(serverReleasedConnection, true, "delivery waits for the connection to close");
await new Promise((resolve) => server.close(resolve));
