/* Argus-owned Pi extension for live Agent Status and turn completion. */
const requiredEnvironment = ["ARGUS_SOCKET_PATH", "ARGUS_WORKSPACE_ID", "ARGUS_SURFACE_ID"];
const deliveryTimeoutMilliseconds = 1500;

export function environmentIsValid(environment) {
  return requiredEnvironment.every(
    (key) => typeof environment[key] === "string" && environment[key].length > 0,
  );
}

export function hasFinalAgentError(messages) {
  return Array.isArray(messages) && messages.some(
    (message) => message?.role === "assistant" && message.stopReason === "error",
  );
}

export function statusEventID(sessionID, sequence, operation = "changed") {
  return `pi:${operation}:${sessionID}:${sequence}`;
}

export function turnEventID(sessionID, sequence) {
  return `pi:turnCompleted:${sessionID}:${sequence}`;
}

export async function send(socketPath, payload) {
  const { connect } = await import("node:net");
  await new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    let settled = false;
    const finish = (operation) => (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      socket.destroy();
      operation(value);
    };
    const timeout = setTimeout(
      () => finish(reject)(new Error("Argus delivery timed out")),
      deliveryTimeoutMilliseconds,
    );
    socket.once("error", finish(reject));
    socket.once("close", finish(resolve));
    socket.end(`${JSON.stringify(payload)}\n`);
  });
}

async function deliverWithDeadline(transport, socketPath, payload) {
  let timeout;
  try {
    await Promise.race([
      transport(socketPath, payload),
      new Promise((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error("Argus delivery timed out")),
          deliveryTimeoutMilliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function defaultInstanceID() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function sessionIDFor(context, instanceID) {
  const sessionID = context?.sessionManager?.getSessionId?.();
  const base = typeof sessionID === "string" && sessionID.length > 0 ? sessionID : "unknown";
  return `${base}:${instanceID}`;
}

// pi-subagents is optional. Use its public event-bus protocol, not package imports
// or child event traffic: only its current-session snapshot proves work is idle.
function createSubagentStatusReader(pi, instanceID) {
  let advertisement;
  let requestSequence = 0;
  let cancel = () => {};
  const unsubscribeReady = pi.events?.on("subagents:rpc:v1:ready", (data) => {
    advertisement = data ?? null;
  });

  return {
    cancel() { cancel(); },
    dispose() {
      cancel();
      unsubscribeReady?.();
    },
    async hasActiveWork(context) {
      if (advertisement === undefined) return false; // Plain Pi, no package advertised.
      if (advertisement?.version !== 1
          || advertisement.capabilities?.fleetStatus?.version !== 1
          || advertisement.session?.sessionId !== context?.sessionManager?.getSessionId?.()) {
        return undefined;
      }
      cancel();
      const requestId = `argus:${instanceID}:${++requestSequence}`;
      return new Promise((resolve) => {
        let settled = false;
        let unsubscribe;
        const finish = (active) => {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          unsubscribe?.();
          cancel = () => {};
          resolve(active);
        };
        const timeout = setTimeout(() => finish(undefined), deliveryTimeoutMilliseconds);
        cancel = () => finish(undefined);
        try {
          unsubscribe = pi.events.on(`subagents:rpc:v1:reply:${requestId}`, (reply) => {
            if (reply?.version !== 1 || reply.requestId !== requestId
                || (reply.method !== undefined && reply.method !== "status")) return;
            const fleet = reply.success === true ? reply.data?.fleet : undefined;
            finish(fleet?.version === 1 && Number.isSafeInteger(fleet.totalActive) && fleet.totalActive >= 0
              ? fleet.totalActive > 0 : undefined);
          });
          pi.events.emit("subagents:rpc:v1:request", { version: 1, requestId, method: "status" });
        } catch {
          finish(undefined);
        }
      });
    },
  };
}

export function createPlugin({ environment: suppliedEnvironment, transport = send, instanceID = defaultInstanceID() } = {}) {
  return function install(pi) {
    const environment = suppliedEnvironment ?? (typeof process === "undefined" ? {} : process.env);
    if (environment.PI_SUBAGENT_CHILD === "1" || !environmentIsValid(environment)) return;

    const subagents = createSubagentStatusReader(pi, instanceID);
    let sessionID;
    let sequence = 0;
    let generation = 0;
    let turnPending = false;
    let finalAgentError = false;
    let finalAgentAborted = false;
    let deliveryQueue = Promise.resolve();

    function ensureSession(context) {
      const nextSessionID = sessionIDFor(context, instanceID);
      if (sessionID !== nextSessionID) {
        sessionID = nextSessionID;
        sequence = 0;
        finalAgentError = false;
      }
      return sessionID;
    }

    function enqueue(context, state, isCurrent = () => true) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const payload = {
        version: 1,
        id: statusEventID(currentSessionID, currentSequence),
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state,
          sessionId: currentSessionID,
          sequence: currentSequence,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => isCurrent() ? deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload) : undefined)
        .catch(() => {
          // Delivery failures must not alter Pi's lifecycle behavior.
        });
      return deliveryQueue;
    }

    function enqueueTurnCompletion(context, isCurrent) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const eventId = turnEventID(currentSessionID, currentSequence);
      const payload = {
        version: 1,
        id: eventId,
        method: "agent.turnCompleted",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          eventId,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => isCurrent() ? deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload) : undefined)
        .catch(() => {
          // Delivery failures must not alter Pi's lifecycle behavior.
        });
      return deliveryQueue;
    }

    function enqueueClear(context) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const payload = {
        version: 1,
        id: statusEventID(currentSessionID, currentSequence, "cleared"),
        method: "agent.statusCleared",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          sessionId: currentSessionID,
          sequence: currentSequence,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload))
        .catch(() => {
          // Delivery failures must not alter Pi's shutdown behavior.
        });
      return deliveryQueue;
    }

    pi.on("session_start", (_event, context) => {
      generation++;
      turnPending = false;
      subagents.cancel();
      return enqueue(context, "idle");
    });

    pi.on("agent_start", (_event, context) => {
      generation++;
      subagents.cancel();
      turnPending = true;
      finalAgentError = false;
      finalAgentAborted = false;
      return enqueue(context, "running");
    });

    pi.on("agent_end", (event) => {
      finalAgentError = hasFinalAgentError(event?.messages);
      finalAgentAborted = Array.isArray(event?.messages) && event.messages.some(
        (message) => message?.role === "assistant" && message.stopReason === "aborted",
      );
    });

    pi.on("agent_settled", async (_event, context) => {
      if (!turnPending) return;
      turnPending = false;
      const settledGeneration = generation;
      const settledSessionID = ensureSession(context);
      const isCurrent = () => generation === settledGeneration
        && sessionIDFor(context, instanceID) === settledSessionID
        && context?.isIdle?.() !== false;
      const failed = finalAgentError;
      const aborted = finalAgentAborted;
      if (failed) return enqueue(context, "error", isCurrent);

      const activeWork = await subagents.hasActiveWork(context);
      if (!isCurrent() || activeWork === undefined) return;
      await enqueue(context, activeWork ? "running" : "idle", isCurrent);
      // A child completion never announces success. Wait for the main agent's
      // next successful settlement after it has consumed the delegated results.
      if (!activeWork && !aborted && isCurrent()) await enqueueTurnCompletion(context, isCurrent);
    });

    pi.on("session_shutdown", (_event, context) => {
      generation++;
      turnPending = false;
      subagents.dispose();
      return enqueueClear(context);
    });
  };
}

export default function (pi) {
  return createPlugin()(pi);
}
