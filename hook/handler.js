/**
 * Step Gate — Internal Hook Handler (v11)
 *
 * This is an Internal Hook handler loaded by OpenClaw's hooks:loader.
 * It listens to `agent:bootstrap` events and injects STEP-GATE.md
 * into the agent's bootstrap context.
 *
 * Separate from the Plugin (which handles periodic checkbox sync).
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

// ── Debug Logger ──────────────────────────────────────────────────────────

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";

function D(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [hook] ${msg}\n`);
  } catch {}
}

// ── Parser ────────────────────────────────────────────────────────────────

function parseSteps(content) {
  const steps = [];
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
    const status =
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

// ── File-level completion check ───────────────────────────────────────────

function isFileCompleted(content) {
  const header = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return (
    header.includes("status: completed") ||
    header.includes("status: done") ||
    header.includes("status: 已完成")
  );
}

// ── Analyze a single todo file ────────────────────────────────────────────

function analyze(fp) {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;

    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);

    let current = null;
    for (const s of sorted) {
      if (s.status !== "done") {
        current = s.number;
        break;
      }
    }

    const skipped = [];
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

// ── Find todo files ───────────────────────────────────────────────────────

function scanDir(dir, results) {
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

function findTodos(dir) {
  const results = [];
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

// ── Generate STEP-GATE.md content ─────────────────────────────────────────

function generateBootstrap(todos, minSteps) {
  const active = todos.filter(
    (t) => !t.fileCompleted && t.total >= minSteps && t.done < t.total,
  );
  if (!active.length) return null;

  const lines = [
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

// ── Bootstrap Handler ─────────────────────────────────────────────────────

const MIN_STEPS = 3;

const stepGateBootstrapHandler = async (event) => {
  // Guard: only handle agent:bootstrap
  if (event.type !== "agent" || event.action !== "bootstrap") {
    return;
  }

  D("bootstrap FIRED");

  const context = event.context ?? {};
  const workspaceDir =
    context.workspaceDir ||
    process.env.OPENCLAW_WORKSPACE_DIR ||
    path.join(os.homedir(), ".openclaw", "workspace");

  const todos = findTodos(workspaceDir);
  const completedCount = todos.filter((t) => t.fileCompleted).length;
  D(`found ${todos.length} todos (${completedCount} completed)`);

  if (!todos.length) return;

  const content = generateBootstrap(todos, MIN_STEPS);
  if (!content) {
    D("no active todos need injection, skip");
    return;
  }

  // Write STEP-GATE.md to disk (for periodic sync reference)
  const fp = path.join(workspaceDir, "STEP-GATE.md");
  try {
    fs.writeFileSync(fp, content, "utf-8");
  } catch (e) {
    D(`failed to write STEP-GATE.md: ${e.message}`);
  }

  // Inject into bootstrapFiles (in-memory context mutation)
  const bf = context.bootstrapFiles;
  if (Array.isArray(bf)) {
    // Remove existing STEP-GATE.md entry if present
    const idx = bf.findIndex(
      (f) => f.name === "STEP-GATE.md" || f.path?.endsWith("STEP-GATE.md"),
    );
    if (idx >= 0) bf.splice(idx, 1);

    // Prepend (highest priority)
    bf.unshift({
      name: "STEP-GATE.md",
      path: fp,
      content,
      source: "step-gate",
    });
    D(`injected STEP-GATE.md into bootstrapFiles (${bf.length} total files)`);
  } else {
    D("WARNING: bootstrapFiles not found or not an array in event.context");
  }
};

export default stepGateBootstrapHandler;
