// ai-task-monitor: observer only, for OpenCode V2 and V1 >= 1.18.29.
import { spawn } from "node:child_process";
const bridge = __BRIDGE__;
const dataDirectory = __DATA__;

export function translate(event) {
  const data = event.data ?? event.properties ?? {};
  const info = data.info ?? data.session ?? {};
  const session = data.sessionID ?? data.sessionId ?? info.id ?? data.request?.sessionID;
  if (!session || info.parentID || info.parent_id) return;
  let kind;
  if (event.type === "session.execution.started") kind = "UserPromptSubmit";
  else if (["session.execution.succeeded", "session.idle"].includes(event.type)) kind = "Stop";
  else if (["session.execution.failed", "session.execution.interrupted", "session.deleted", "session.archived", "session.error"].includes(event.type)) kind = "SessionEnd";
  else if (["permission.asked", "permission.updated", "form.created", "question.asked"].includes(event.type)) kind = "PermissionRequest";
  else if (["permission.replied", "form.replied", "question.replied"].includes(event.type)) kind = "PostToolUse";
  else if (event.type === "session.status") {
    kind = data.status?.type === "busy" ? "PreToolUse" : data.status?.type === "idle" ? "Stop" : undefined;
  } else if (["session.created", "session.renamed", "session.updated"].includes(event.type)) kind = "SessionMetadata";
  if (!kind) return;
  return { event: kind, payload: { session_id: session, title: info.title ?? data.title,
    event_id: event.id, cwd: event.location?.directory ?? info.directory } };
}

let queue = Promise.resolve();
function relay(event) {
  const translated = translate(event);
  if (!translated) return;
  // Serialize events to preserve rapid start/stop order across child processes.
  queue = queue.then(() => new Promise((resolve) => {
    const child = spawn("/usr/bin/python3", [bridge, "--provider", "opencode", "--event", translated.event,
      "--data-dir", dataDirectory], { stdio: ["pipe", "ignore", "ignore"] });
    child.on("error", resolve);
    child.on("exit", resolve);
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify(translated.payload));
    const timer = setTimeout(() => { child.kill(); resolve(); }, 2000);
    child.once("close", () => clearTimeout(timer));
  })).catch(() => {});
  return queue;
}

export default {
  id: "ai-task-monitor",
  setup(ctx) {
    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) await relay(event);
      } catch { /* Observer loss must not interrupt the client. */ }
    })();
    return () => controller.abort();
  },
  async server() { return { event: async ({ event }) => { await relay(event); } }; },
};
