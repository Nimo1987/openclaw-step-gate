#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Step Gate v11 — One-click installer for OpenClaw
#
# Deploys TWO components:
#   1. Internal Hook (~/.openclaw/hooks/step-gate/)
#      → Handles agent:bootstrap injection (STEP-GATE.md into context)
#   2. Plugin (~/.openclaw/extensions/step-gate/)
#      → Handles periodic checkbox sync (every 15s)
#
# Usage:
#   curl -sL <url>/install.sh | sudo bash
#   or: sudo bash install.sh
#
# Requires: OpenClaw installed and running
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Check environment ──
OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OC_CONFIG="$OC_DIR/openclaw.json"
OC_WORKSPACE="${OPENCLAW_WORKSPACE:-$OC_DIR/workspace}"
OC_EXTENSIONS="$OC_DIR/extensions"
OC_HOOKS="$OC_DIR/hooks"

[ -d "$OC_DIR" ] || error "OpenClaw directory not found: $OC_DIR"
[ -f "$OC_CONFIG" ] || error "OpenClaw config not found: $OC_CONFIG"

info "OpenClaw detected: $OC_DIR"

# ══════════════════════════════════════════════════════════════
# Part 1: Internal Hook (bootstrap injection)
# ══════════════════════════════════════════════════════════════

HOOK_DIR="$OC_HOOKS/step-gate"
mkdir -p "$HOOK_DIR"
info "Hook directory: $HOOK_DIR"

# ── Write HOOK.md ──
cat > "$HOOK_DIR/HOOK.md" << 'HOOKMD_EOF'
---
name: step-gate
description: "Inject STEP-GATE.md into agent bootstrap context to enforce step execution discipline"
metadata:
  clawdbot:
    emoji: "🚦"
    events: ["agent:bootstrap"]
    always: true
---
# Step Gate — Bootstrap Hook

Injects `STEP-GATE.md` into the agent's bootstrap context on every session start.

Scans workspace for active `todo*.md` files, builds a progress summary with step-by-step
execution rules, and prepends it to `bootstrapFiles` so the agent sees it first.

Works together with the step-gate plugin (periodic checkbox sync).
HOOKMD_EOF
info "HOOK.md written"

# ── Write handler.js ──
cat > "$HOOK_DIR/handler.js" << 'HANDLER_EOF'
/**
 * Step Gate — Internal Hook Handler (v11)
 *
 * Listens to agent:bootstrap events and injects STEP-GATE.md
 * into the agent's bootstrap context.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";

function D(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [hook] ${msg}\n`);
  } catch {}
}

function parseSteps(content) {
  const steps = [];
  const lines = content.split("\n");
  const cbRe = /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;

  for (const line of lines) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1], start = +cb[2], end = cb[3] ? +cb[3] : start, title = cb[4].trim();
    const status = mark === "x" || mark === "X" ? "done" : mark === "~" ? "in-progress" : "pending";
    for (let n = start; n <= end; n++) {
      if (!steps.find((x) => x.number === n)) steps.push({ number: n, title, status });
    }
  }

  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe = /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1], block = m[0].toLowerCase();
      if (block.includes("status: done") || block.includes("status: completed") || block.includes("status: 完成")) {
        const st = steps.find((x) => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }
  return steps;
}

function isFileCompleted(content) {
  const header = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return header.includes("status: completed") || header.includes("status: done") || header.includes("status: 已完成");
}

function analyze(fp) {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;
    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);
    let current = null;
    for (const s of sorted) { if (s.status !== "done") { current = s.number; break; } }
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
    return { path: fp, filename: path.basename(fp), steps, total: steps.length, done, current, skipped, fileCompleted };
  } catch { return null; }
}

function scanDir(dir, results) {
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try { if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue; } catch { continue; }
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
    try { return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs; } catch { return 0; }
  });
}

function generateBootstrap(todos, minSteps) {
  const active = todos.filter((t) => !t.fileCompleted && t.total >= minSteps && t.done < t.total);
  if (!active.length) return null;
  const lines = [
    "# STEP GATE — Task Execution Discipline", "",
    "## Rules", "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.", "",
  ];
  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");
    for (const s of t.steps.sort((a, b) => a.number - b.number)) {
      const icon = s.status === "done" ? "✅" : "⬜";
      const marker = s.number === t.current ? " **← NOW**" : "";
      lines.push(`${icon} Step ${s.number}: ${s.title}${marker}`);
    }
    lines.push("");
    if (t.skipped.length) lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    if (t.current) lines.push(`**→ Execute Step ${t.current} now.**`, "");
  }
  return lines.join("\n");
}

const MIN_STEPS = 3;

const stepGateBootstrapHandler = async (event) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  D("bootstrap FIRED");
  const context = event.context ?? {};
  const workspaceDir = context.workspaceDir || process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");

  const todos = findTodos(workspaceDir);
  D(`found ${todos.length} todos (${todos.filter((t) => t.fileCompleted).length} completed)`);
  if (!todos.length) return;

  const content = generateBootstrap(todos, MIN_STEPS);
  if (!content) { D("no active todos need injection, skip"); return; }

  const fp = path.join(workspaceDir, "STEP-GATE.md");
  try { fs.writeFileSync(fp, content, "utf-8"); } catch (e) { D(`write err: ${e.message}`); }

  const bf = context.bootstrapFiles;
  if (Array.isArray(bf)) {
    const idx = bf.findIndex((f) => f.name === "STEP-GATE.md" || f.path?.endsWith("STEP-GATE.md"));
    if (idx >= 0) bf.splice(idx, 1);
    bf.unshift({ name: "STEP-GATE.md", path: fp, content, source: "step-gate" });
    D(`injected STEP-GATE.md (${bf.length} total bootstrap files)`);
  } else {
    D("WARNING: bootstrapFiles not found in event.context");
  }
};

export default stepGateBootstrapHandler;
HANDLER_EOF
info "handler.js written"

# ══════════════════════════════════════════════════════════════
# Part 2: Plugin (periodic checkbox sync)
# ══════════════════════════════════════════════════════════════

PLUGIN_DIR="$OC_EXTENSIONS/step-gate"
mkdir -p "$PLUGIN_DIR"
info "Plugin directory: $PLUGIN_DIR"

# ── Write plugin manifest ──
cat > "$PLUGIN_DIR/openclaw.plugin.json" << 'MANIFEST_EOF'
{
  "id": "step-gate",
  "name": "Step Gate",
  "description": "Periodic checkbox sync for todo-based step execution. Bootstrap injection handled by Internal Hook.",
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "enabled": {
        "type": "boolean",
        "description": "Enable or disable checkbox sync"
      },
      "minSteps": {
        "type": "number",
        "description": "Minimum steps to trigger enforcement (default: 3)"
      },
      "syncInterval": {
        "type": "number",
        "description": "Checkbox sync interval in ms (default: 15000)"
      }
    }
  }
}
MANIFEST_EOF
info "Plugin manifest written"

# ── Write plugin package.json ──
cat > "$PLUGIN_DIR/package.json" << 'PKG_EOF'
{
  "name": "step-gate",
  "version": "11.0.0",
  "type": "module"
}
PKG_EOF

# ── Write plugin code ──
cat > "$PLUGIN_DIR/index.ts" << 'PLUGIN_EOF'
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Step Gate Plugin v11 — Periodic Checkbox Sync Only
 *
 * Bootstrap injection is handled by the Internal Hook (hooks/step-gate/).
 * This plugin only does periodic checkbox sync.
 */

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";
function D(msg: string): void {
  try { fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [plugin] ${msg}\n`); } catch {}
}

interface Step { number: number; title: string; status: "done" | "pending" | "in-progress"; }
interface Todo { path: string; filename: string; steps: Step[]; total: number; done: number; current: number | null; skipped: number[]; fileCompleted: boolean; }

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const cbRe = /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;
  for (const line of content.split("\n")) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1], start = +cb[2], end = cb[3] ? +cb[3] : start, title = cb[4].trim();
    const status: Step["status"] = mark === "x" || mark === "X" ? "done" : mark === "~" ? "in-progress" : "pending";
    for (let n = start; n <= end; n++) if (!steps.find(x => x.number === n)) steps.push({ number: n, title, status });
  }
  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe = /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1], block = m[0].toLowerCase();
      if (block.includes("status: done") || block.includes("status: completed") || block.includes("status: 完成")) {
        const st = steps.find(x => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }
  return steps;
}

function isFileCompleted(content: string): boolean {
  const h = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return h.includes("status: completed") || h.includes("status: done") || h.includes("status: 已完成");
}

function analyze(fp: string): Todo | null {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;
    const done = steps.filter(s => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);
    let current: number | null = null;
    for (const s of sorted) if (s.status !== "done") { current = s.number; break; }
    const skipped: number[] = [];
    let lastDone = 0;
    for (const s of sorted) if (s.status === "done") { for (let n = lastDone + 1; n < s.number; n++) { const x = steps.find(y => y.number === n); if (x && x.status === "pending") skipped.push(n); } lastDone = s.number; }
    return { path: fp, filename: path.basename(fp), steps, total: steps.length, done, current, skipped, fileCompleted };
  } catch { return null; }
}

function findTodos(dir: string): Todo[] {
  const r: Todo[] = [];
  for (const d of [dir, path.join(dir, "todos")]) {
    try {
      for (const f of fs.readdirSync(d)) {
        if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
        const fp = path.join(d, f);
        try { if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue; } catch { continue; }
        if (r.find(x => x.path === fp)) continue;
        const t = analyze(fp);
        if (t) r.push(t);
      }
    } catch {}
  }
  return r.sort((a, b) => { try { return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs; } catch { return 0; } });
}

function syncCheckboxes(fp: string, steps: Step[]): boolean {
  try {
    let c = fs.readFileSync(fp, "utf-8"), changed = false;
    for (const s of steps) {
      if (s.status !== "done") continue;
      const patterns = [
        new RegExp(`(- \\[) (\\]\\s*${s.number}\\.\\s*)`, "m"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}[.:]\\s*)`, "mi"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}\\s*[-–]\\s*\\d+[.:]\\s*)`, "mi"),
      ];
      for (const p of patterns) if (p.test(c)) { c = c.replace(p, "$1x$2"); changed = true; D(`cb:${s.number}`); break; }
    }
    if (steps.length && steps.every(s => s.status === "done") && /# Status: In Progress/i.test(c)) {
      c = c.replace(/# Status: In Progress/i, "# Status: Completed"); changed = true;
    }
    if (changed) fs.writeFileSync(fp, c, "utf-8");
    return changed;
  } catch { return false; }
}

function generateBootstrap(todos: Todo[], minSteps: number): string | null {
  const active = todos.filter(t => !t.fileCompleted && t.total >= minSteps && t.done < t.total);
  if (!active.length) return null;
  const lines: string[] = ["# STEP GATE — Task Execution Discipline", "", "## Rules", "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.", ""];
  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");
    for (const s of t.steps.sort((a, b) => a.number - b.number))
      lines.push(`${s.status === "done" ? "✅" : "⬜"} Step ${s.number}: ${s.title}${s.number === t.current ? " **← NOW**" : ""}`);
    lines.push("");
    if (t.skipped.length) lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    if (t.current) lines.push(`**→ Execute Step ${t.current} now.**`, "");
  }
  return lines.join("\n");
}

function syncAll(dir: string, minSteps: number): void {
  const todos = findTodos(dir);
  for (const t of todos) syncCheckboxes(t.path, t.steps);
  const content = generateBootstrap(todos, minSteps);
  if (content) try { fs.writeFileSync(path.join(dir, "STEP-GATE.md"), content, "utf-8"); } catch {}
  else try { fs.unlinkSync(path.join(dir, "STEP-GATE.md")); } catch {}
}

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  const syncInterval = cfg.syncInterval ?? 15000;
  D("=== step-gate v11 register() ===");
  if (!enabled) return;
  const wsDir = (): string => process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");
  setInterval(() => { try { syncAll(wsDir(), minSteps); } catch (e: any) { D(`sync err: ${e.message}`); } }, syncInterval);
  D("v11 loaded (checkbox-sync only, bootstrap via Internal Hook)");
  api.logger?.info?.("step-gate v11 loaded");
}
PLUGIN_EOF
info "Plugin code written"

# ══════════════════════════════════════════════════════════════
# Part 3: Update openclaw.json config
# ══════════════════════════════════════════════════════════════

info "Updating openclaw.json..."

OC_CONFIG="$OC_CONFIG" PLUGIN_DIR="$PLUGIN_DIR" python3 << 'PYEOF'
import json, os

config_path = os.environ["OC_CONFIG"]
plugin_dir = os.environ["PLUGIN_DIR"]

with open(config_path, "r") as f:
    cfg = json.load(f)

# Ensure plugins section
for key in ["plugins"]:
    if key not in cfg:
        cfg[key] = {}
for key in ["entries", "installs", "load"]:
    if key not in cfg["plugins"]:
        cfg["plugins"][key] = {}
if "paths" not in cfg["plugins"]["load"]:
    cfg["plugins"]["load"]["paths"] = []

# Plugin entry
cfg["plugins"]["entries"]["step-gate"] = {
    "enabled": True,
    "config": {
        "enabled": True,
        "minSteps": 3
    }
}

# Plugin install record
cfg["plugins"]["installs"]["step-gate"] = {
    "source": "path",
    "spec": plugin_dir,
    "sourcePath": plugin_dir,
    "installPath": plugin_dir,
    "version": "11.0.0",
    "resolvedName": "step-gate",
    "resolvedVersion": "11.0.0"
}

# Load path
if plugin_dir not in cfg["plugins"]["load"]["paths"]:
    cfg["plugins"]["load"]["paths"].append(plugin_dir)

# Enable internal hooks + step-gate hook entry
if "hooks" not in cfg:
    cfg["hooks"] = {}
if "internal" not in cfg["hooks"]:
    cfg["hooks"]["internal"] = {}
cfg["hooks"]["internal"]["enabled"] = True
if "entries" not in cfg["hooks"]["internal"]:
    cfg["hooks"]["internal"]["entries"] = {}
cfg["hooks"]["internal"]["entries"]["step-gate"] = {"enabled": True}

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("Config updated successfully")
PYEOF

info "openclaw.json updated"

# ══════════════════════════════════════════════════════════════
# Part 4: Restart Gateway
# ══════════════════════════════════════════════════════════════

info "Restarting OpenClaw Gateway..."

# Clear old log
> /tmp/step-gate.log 2>/dev/null || true

if pgrep -f openclaw-gateway > /dev/null 2>&1; then
    kill -15 $(pgrep -f openclaw-gateway) 2>/dev/null
    sleep 3
    # Wait for auto-restart (systemd or supervisor)
    for i in $(seq 1 10); do
        if pgrep -f openclaw-gateway > /dev/null 2>&1; then
            info "Gateway restarted (PID: $(pgrep -f openclaw-gateway))"
            break
        fi
        sleep 2
    done
    if ! pgrep -f openclaw-gateway > /dev/null 2>&1; then
        warn "Gateway did not auto-restart. Please start it manually."
    fi
else
    warn "Gateway not running. Please start it manually."
fi

# ══════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Step Gate v11 installed!"
echo ""
echo "  Components:"
echo "    - Internal Hook → $HOOK_DIR (agent:bootstrap injection)"
echo "    - Plugin        → $PLUGIN_DIR (periodic checkbox sync)"
echo ""
echo "  Verify:"
echo "    tail -f /tmp/step-gate.log"
echo "    # Look for '[hook] bootstrap FIRED' on next /new command"
echo ""
echo "  Uninstall:"
echo "    rm -rf $HOOK_DIR $PLUGIN_DIR"
echo "    # Then remove step-gate from openclaw.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
