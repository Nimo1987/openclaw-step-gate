import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Step Gate — OpenClaw Plugin
 *
 * Enforces sequential task execution discipline for AI agents.
 *
 * How it works:
 *   1. On agent:bootstrap → injects STEP-GATE.md into agent context
 *      with current task progress and "no skip, no merge" rules
 *   2. Every 15s → scans todo files, reads Execution Log status,
 *      auto-checks corresponding checkboxes, updates STEP-GATE.md
 *
 * The key insight: agents update Execution Log (Status: done) but
 * forget to check the checkbox. This plugin bridges that gap.
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
}

// ── Parser ────────────────────────────────────────────────────────────────
// Reads both Plan checkboxes AND Execution Log status.
// Execution Log takes priority — if it says "done", the step is done
// regardless of checkbox state.

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const lines = content.split("\n");

  // Phase 1: parse checkbox lines in Plan section
  // Matches: "- [ ] 1. Do something" or "- [x] Step 3: Do something"
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

  // Phase 2: override from Execution Log
  // Agent writes "Status: done" here but forgets to check the checkbox
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

// ── Analyze a single todo file ────────────────────────────────────────────

function analyze(fp: string): Todo | null {
  try {
    const steps = parseSteps(fs.readFileSync(fp, "utf-8"));
    if (!steps.length) return null;

    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);

    // Find current step (first non-done)
    let current: number | null = null;
    for (const s of sorted) {
      if (s.status !== "done") {
        current = s.number;
        break;
      }
    }

    // Detect skipped steps (done steps with pending gaps before them)
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
    };
  } catch {
    return null;
  }
}

// ── Find all recent todo files (last 24h) ─────────────────────────────────

function findTodos(dir: string): Todo[] {
  const results: Todo[] = [];
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try {
        if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue;
      } catch {
        continue;
      }
      const t = analyze(fp);
      if (t) results.push(t);
    }
  } catch {}

  // Most recently modified first
  return results.sort((a, b) => {
    try {
      return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs;
    } catch {
      return 0;
    }
  });
}

// ── Checkbox Sync ─────────────────────────────────────────────────────────
// For each step marked "done" in Execution Log, find the corresponding
// checkbox line and change [ ] to [x].

function syncCheckboxes(fp: string, steps: Step[]): boolean {
  try {
    let content = fs.readFileSync(fp, "utf-8");
    let changed = false;

    for (const s of steps) {
      if (s.status !== "done") continue;

      // Try multiple patterns to match the checkbox line
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

    // Auto-set Status to Completed when all steps are done
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
// This file gets injected into the agent's context at bootstrap.
// It shows current progress and enforces execution discipline.

function generateBootstrap(todos: Todo[], minSteps: number): string | null {
  const active = todos.filter((t) => t.total >= minSteps && t.done < t.total);
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
  }
}

// ── Plugin Entry Point ────────────────────────────────────────────────────

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  const syncInterval = cfg.syncInterval ?? 15000; // ms

  D(`=== step-gate register() ===`);
  if (!enabled) return;

  const wsDir = (): string =>
    process.env.OPENCLAW_WORKSPACE_DIR ||
    path.join(os.homedir(), ".openclaw", "workspace");

  // ── Bootstrap hook: inject STEP-GATE.md into agent context ──

  const bootstrapHandler = async (event: any) => {
    D("bootstrap FIRED");
    const ctx = event?.context ?? {};
    const wd = ctx.workspaceDir || wsDir();
    const todos = findTodos(wd);
    D(`bootstrap: ${todos.length} todos`);
    if (!todos.length) return;

    // Sync checkboxes first
    for (const t of todos) syncCheckboxes(t.path, t.steps);

    // Generate and inject STEP-GATE.md
    const content = generateBootstrap(todos, minSteps);
    if (!content) return;

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

  // Register via plugin API
  api.registerHook("agent:bootstrap", bootstrapHandler, {
    name: "step-gate-bootstrap",
  });

  // Also register to globalThis as fallback
  // (OpenClaw's hook loader may reset the handler map after plugin registration)
  const g = globalThis as any;
  if (!g.__openclaw_internal_hook_handlers__) {
    g.__openclaw_internal_hook_handlers__ = new Map();
  }
  const hMap: Map<string, Function[]> = g.__openclaw_internal_hook_handlers__;
  if (!hMap.has("agent:bootstrap")) hMap.set("agent:bootstrap", []);
  hMap.get("agent:bootstrap")!.push(bootstrapHandler);

  // ── Timer: periodic checkbox sync ──

  setInterval(() => {
    try {
      syncAll(wsDir());
    } catch (e: any) {
      D(`err: ${e.message}`);
    }
  }, syncInterval);

  D("loaded");
  api.logger?.info?.("step-gate loaded (auto-cb-sync + bootstrap)");
}
