import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Step Gate v10 — OpenClaw Plugin
 *
 * Changes in v10:
 *   - Fixed: restore globalThis delayed injection (5s after register)
 *     to ensure hook handler survives hooks:loader reinitialization
 *   - api.registerHook kept as primary, globalThis as fallback
 *   - Dedup: bootstrap handler checks a flag to avoid double-fire
 */

// ── Debug Logger ──────────────────────────────────────────────────────────

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";

function D(msg: string): void {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`);
  } catch {}
}

// ── Types ─────────────────────────────────────────────────────────────────

interface Step {
  number: number;
  title: string;
  status: "done" | "pending" | "in-progress";
}

interface Todo {
  path: string;
  filename: string;
  steps: Step[];
  total: number;
  done: number;
  current: number | null;
  skipped: number[];
  fileCompleted: boolean;
}

// ── Parser ────────────────────────────────────────────────────────────────

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const lines = content.split("\n");

  const cbRe =
    /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;

  for (const line of lines) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1];
    const start = +cb[2];
    const end = cb[3] ? +cb[3] : start;
    const title = cb[4].trim();
    const status: Step["status"] =
      mark === "x" || mark === "X"
        ? "done"
        : mark === "~"
          ? "in-progress"
          : "pending";
    for (let n = start; n <= end; n++) {
      if (!steps.find((x) => x.number === n)) {
        steps.push({ number: n, title, status });
      }
    }
  }

  // Override from Execution Log
  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe =
      /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1];
      const block = m[0].toLowerCase();
      if (
        block.includes("status: done") ||
        block.includes("status: completed") ||
        block.includes("status: 完成")
      ) {
        const st = steps.find((x) => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }

  return steps;
}

// ── Check if file-level Status is Completed ───────────────────────────────

function isFileCompleted(content: string): boolean {
  const header = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return (
    header.includes("status: completed") ||
    header.includes("status: done") ||
    header.includes("status: 已完成")
  );
}

// ── Analyze a single todo file ────────────────────────────────────────────

function analyze(fp: string): Todo | null {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;

    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);

    let current: number | null = null;
    for (const s of sorted) {
      if (s.status !== "done") {
        current = s.number;
        break;
      }
    }

    const skipped: number[] = [];
    let lastDone = 0;
    for (const s of sorted) {
      if (s.status === "done") {
        for (let n = lastDone + 1; n < s.number; n++) {
          const x = steps.find((y) => y.number === n);
          if (x && x.status === "pending") skipped.push(n);
        }
        lastDone = s.number;
      }
    }

    return {
      path: fp,
      filename: path.basename(fp),
      steps,
      total: steps.length,
      done,
      current,
      skipped,
      fileCompleted,
    };
  } catch {
    return null;
  }
}

// ── Find all recent todo files (last 24h) ─────────────────────────────────

function scanDir(dir: string, results: Todo[]): void {
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try {
        if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue;
      } catch {
        continue;
      }
      if (results.find((r) => r.path === fp)) continue;
      const t = analyze(fp);
      if (t) results.push(t);
    }
  } catch {}
}

function findTodos(dir: string): Todo[] {
  const results: Todo[] = [];
  scanDir(dir, results);
  scanDir(path.join(dir, "todos"), results);

  return results.sort((a, b) => {
    try {
      return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs;
    } catch {
      return 0;
    }
  });
}

// ── Checkbox Sync ─────────────────────────────────────────────────────────

function syncCheckboxes(fp: string, steps: Step[]): boolean {
  try {
    let content = fs.readFileSync(fp, "utf-8");
    let changed = false;

    for (const s of steps) {
      if (s.status !== "done") continue;

      const patterns = [
        new RegExp(`(- \\[) (\\]\\s*${s.number}\\.\\s*)`, "m"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}[.:]\\s*)`, "mi"),
        new RegExp(
          `(- \\[) (\\]\\s*Step\\s*${s.number}\\s*[-–]\\s*\\d+[.:]\\s*)`,
          "mi",
        ),
      ];

      for (const p of patterns) {
        if (p.test(content)) {
          content = content.replace(p, "$1x$2");
          changed = true;
          D(`cb:${s.number}`);
          break;
        }
      }
    }

    if (
      steps.length &&
      steps.every((s) => s.status === "done") &&
      /# Status: In Progress/i.test(content)
    ) {
      content = content.replace(
        /# Status: In Progress/i,
        "# Status: Completed",
      );
      changed = true;
    }

    if (changed) fs.writeFileSync(fp, content, "utf-8");
    return changed;
  } catch {
    return false;
  }
}

// ── Generate STEP-GATE.md ─────────────────────────────────────────────────

function generateBootstrap(todos: Todo[], minSteps: number): string | null {
  const active = todos.filter(
    (t) => !t.fileCompleted && t.total >= minSteps && t.done < t.total,
  );
  if (!active.length) return null;

  const lines: string[] = [
    "# STEP GATE — Task Execution Discipline",
    "",
    "## Rules",
    "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.",
    "",
  ];

  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");

    for (const s of t.steps.sort((a, b) => a.number - b.number)) {
      const icon = s.status === "done" ? "✅" : "⬜";
      const marker = s.number === t.current ? " **← NOW**" : "";
      lines.push(`${icon} Step ${s.number}: ${s.title}${marker}`);
    }
    lines.push("");

    if (t.skipped.length) {
      lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    }
    if (t.current) {
      lines.push(`**→ Execute Step ${t.current} now.**`, "");
    }
  }

  return lines.join("\n");
}

// ── Periodic Sync ─────────────────────────────────────────────────────────

function syncAll(dir: string): void {
  const todos = findTodos(dir);

  for (const t of todos) syncCheckboxes(t.path, t.steps);

  const content = generateBootstrap(todos, 3);
  if (content) {
    try {
      fs.writeFileSync(path.join(dir, "STEP-GATE.md"), content, "utf-8");
    } catch {}
  } else {
    try {
      fs.unlinkSync(path.join(dir, "STEP-GATE.md"));
    } catch {}
  }
}

// ── globalThis hook injection ─────────────────────────────────────────────
// OpenClaw's hooks:loader may reinitialize the handler map AFTER plugin
// register() runs. We inject directly into globalThis with a delay to
// ensure our handler survives.

function injectGlobalHook(handler: Function): void {
  const G = globalThis as any;
  const KEY = "__openclaw_internal_hook_handlers__";

  const inject = () => {
    let map = G[KEY];
    if (!map || typeof map.get !== "function") {
      // Map doesn't exist yet, create it
      map = new Map();
      G[KEY] = map;
    }

    const event = "agent:bootstrap";
    const existing = map.get(event) || [];

    // Check if we already injected (avoid duplicates)
    const alreadyInjected = existing.some(
      (h: any) => h._stepGate === true,
    );
    if (alreadyInjected) {
      D("globalThis: already injected, skip");
      return;
    }

    // Tag our handler for dedup
    (handler as any)._stepGate = true;
    existing.push(handler);
    map.set(event, existing);
    D(`globalThis: injected agent:bootstrap (total: ${existing.length})`);
  };

  // Inject immediately
  inject();

  // Re-inject after 5s (after hooks:loader has run)
  setTimeout(() => {
    D("globalThis: delayed re-inject (5s)");
    inject();
  }, 5000);

  // Re-inject after 15s (safety net)
  setTimeout(() => {
    D("globalThis: delayed re-inject (15s)");
    inject();
  }, 15000);
}

// ── Plugin Entry Point ────────────────────────────────────────────────────

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  const syncInterval = cfg.syncInterval ?? 15000;

  D(`=== step-gate v10 register() ===`);
  if (!enabled) return;

  const wsDir = (): string =>
    process.env.OPENCLAW_WORKSPACE_DIR ||
    path.join(os.homedir(), ".openclaw", "workspace");

  // ── Dedup flag to prevent double-fire ──
  let lastBootstrapTs = 0;

  const bootstrapHandler = async (event: any) => {
    // Dedup: ignore if fired within 2 seconds
    const now = Date.now();
    if (now - lastBootstrapTs < 2000) {
      D("bootstrap: dedup skip");
      return;
    }
    lastBootstrapTs = now;

    D("bootstrap FIRED");
    const ctx = event?.context ?? {};
    const wd = ctx.workspaceDir || wsDir();
    const todos = findTodos(wd);
    D(`bootstrap: ${todos.length} todos (${todos.filter((t: Todo) => t.fileCompleted).length} completed)`);
    if (!todos.length) return;

    for (const t of todos) syncCheckboxes(t.path, t.steps);

    const content = generateBootstrap(todos, minSteps);
    if (!content) {
      D("no active todos, skip injection");
      return;
    }

    const fp = path.join(wd, "STEP-GATE.md");
    try {
      fs.writeFileSync(fp, content, "utf-8");
    } catch {}

    const bf = ctx.bootstrapFiles;
    if (Array.isArray(bf)) {
      const idx = bf.findIndex(
        (f: any) =>
          f.name === "STEP-GATE.md" || f.path?.endsWith("STEP-GATE.md"),
      );
      if (idx >= 0) bf.splice(idx, 1);
      bf.unshift({
        name: "STEP-GATE.md",
        path: fp,
        content,
        source: "step-gate",
      });
      D(`injected STEP-GATE.md (${bf.length} files)`);
    }
  };

  // Primary: api.registerHook
  api.registerHook("agent:bootstrap", bootstrapHandler, {
    name: "step-gate-bootstrap",
  });

  // Fallback: globalThis injection with delay
  injectGlobalHook(bootstrapHandler);

  // ── Timer: periodic checkbox sync ──
  setInterval(() => {
    try {
      syncAll(wsDir());
    } catch (e: any) {
      D(`err: ${e.message}`);
    }
  }, syncInterval);

  D("v10 loaded (globalThis-reinject + dedup + completed-filter)");
  api.logger?.info?.("step-gate v10 loaded");
}
