#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Step Gate — One-click installer for OpenClaw
# 
# 功能：
#   1. 安装 step-gate plugin（自动checkbox同步 + bootstrap注入防跳步）
#   2. 安装精简版 AGENTS.md（优化上下文占用，配合plugin工作）
#
# 用法：
#   curl -sL <url>/install.sh | sudo bash
#   或
#   sudo bash install.sh
#
# 前提：
#   - OpenClaw 已安装并运行
#   - 以 root 或 sudo 执行
# ─────────────────────────────────────────────────────────────

set -euo pipefail

# ── 颜色 ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 检查环境 ──
OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OC_CONFIG="$OC_DIR/openclaw.json"
OC_WORKSPACE="${OPENCLAW_WORKSPACE:-$OC_DIR/workspace}"
OC_EXTENSIONS="$OC_DIR/extensions"

[ -d "$OC_DIR" ] || error "OpenClaw 目录不存在: $OC_DIR"
[ -f "$OC_CONFIG" ] || error "OpenClaw 配置不存在: $OC_CONFIG"

info "检测到 OpenClaw: $OC_DIR"

# ── 创建 plugin 目录 ──
PLUGIN_DIR="$OC_EXTENSIONS/step-gate"
mkdir -p "$PLUGIN_DIR"
info "Plugin 目录: $PLUGIN_DIR"

# ── 写入 plugin manifest ──
cat > "$PLUGIN_DIR/openclaw.plugin.json" << 'MANIFEST_EOF'
{
  "id": "step-gate",
  "name": "Step Gate",
  "description": "Enforces todo-based step execution discipline. Auto-syncs checkboxes from Execution Log and injects task progress into agent context.",
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "enabled": {
        "type": "boolean",
        "description": "Enable or disable step gate enforcement"
      },
      "minSteps": {
        "type": "number",
        "description": "Minimum number of steps in a todo to trigger enforcement (default: 3)"
      }
    }
  }
}
MANIFEST_EOF
info "Plugin manifest 已写入"

# ── 写入 plugin 代码 ──
cat > "$PLUGIN_DIR/index.ts" << 'PLUGIN_EOF'
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Step Gate Plugin v7 — auto-checkbox-sync + bootstrap injection
 *
 * What it does:
 *   1. Every 15s, scans todo files in workspace
 *   2. Reads Execution Log status → auto-checks corresponding checkboxes
 *   3. On agent:bootstrap, injects STEP-GATE.md with current progress into agent context
 *   4. STEP-GATE.md tells the agent to execute steps in order, no skip, no merge
 */

const DEBUG_LOG = "/tmp/step-gate.log";
function D(msg: string): void {
  try { fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`); } catch {}
}

interface Step { number: number; title: string; status: "done" | "pending" | "in-progress"; }
interface Todo { path: string; filename: string; steps: Step[]; total: number; done: number; current: number | null; skipped: number[]; }

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const lines = content.split("\n");
  const cbRe = /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;
  for (const line of lines) {
    const cb = line.match(cbRe);
    if (cb) {
      const m = cb[1], s = +cb[2], e = cb[3] ? +cb[3] : s, t = cb[4].trim();
      const st: Step["status"] = m === "x" || m === "X" ? "done" : m === "~" ? "in-progress" : "pending";
      for (let n = s; n <= e; n++) if (!steps.find(x => x.number === n)) steps.push({ number: n, title: t, status: st });
    }
  }
  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe = /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1];
      const block = m[0].toLowerCase();
      if (block.includes("status: done") || block.includes("status: completed") || block.includes("status: 完成")) {
        const st = steps.find(x => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }
  return steps;
}

function analyze(fp: string): Todo | null {
  try {
    const steps = parseSteps(fs.readFileSync(fp, "utf-8"));
    if (!steps.length) return null;
    const done = steps.filter(s => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    let cur: number | null = null;
    for (const s of sorted) if (s.status !== "done") { cur = s.number; break; }
    const skipped: number[] = [];
    let last = 0;
    for (const s of sorted) if (s.status === "done") { for (let n = last + 1; n < s.number; n++) { const x = steps.find(y => y.number === n); if (x && x.status === "pending") skipped.push(n); } last = s.number; }
    return { path: fp, filename: path.basename(fp), steps, total: steps.length, done, current: cur, skipped };
  } catch { return null; }
}

function findTodos(dir: string): Todo[] {
  const r: Todo[] = [];
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try { if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue; } catch { continue; }
      const t = analyze(fp);
      if (t) r.push(t);
    }
  } catch {}
  return r.sort((a, b) => { try { return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs; } catch { return 0; } });
}

function syncCB(fp: string, steps: Step[]): boolean {
  try {
    let c = fs.readFileSync(fp, "utf-8"), changed = false;
    for (const s of steps) {
      if (s.status !== "done") continue;
      const patterns = [
        new RegExp(`(- \\[) (\\]\\s*${s.number}\\.\\s*)`, "m"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}[.:]\\s*)`, "mi"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}\\s*[-–]\\s*\\d+[.:]\\s*)`, "mi"),
      ];
      for (const p of patterns) {
        if (p.test(c)) { c = c.replace(p, "$1x$2"); changed = true; D(`cb:${s.number}`); break; }
      }
    }
    if (steps.length && steps.every(s => s.status === "done") && /# Status: In Progress/i.test(c)) {
      c = c.replace(/# Status: In Progress/i, "# Status: Completed"); changed = true;
    }
    if (changed) fs.writeFileSync(fp, c, "utf-8");
    return changed;
  } catch { return false; }
}

function genBootstrap(todos: Todo[], min: number): string | null {
  const active = todos.filter(t => t.total >= min && t.done < t.total);
  if (!active.length) return null;
  const p: string[] = [
    "# STEP GATE — Task Execution Discipline", "",
    "## Rules", "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.", "",
  ];
  for (const t of active) {
    p.push(`## ${t.filename} (${t.done}/${t.total})`, "");
    for (const s of t.steps.sort((a, b) => a.number - b.number))
      p.push(`${s.status === "done" ? "✅" : "⬜"} Step ${s.number}: ${s.title}${s.number === t.current ? " **← NOW**" : ""}`);
    p.push("");
    if (t.skipped.length) p.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    if (t.current) p.push(`**→ Execute Step ${t.current} now.**`, "");
  }
  return p.join("\n");
}

function syncAll(dir: string): void {
  const todos = findTodos(dir);
  for (const t of todos) syncCB(t.path, t.steps);
  const content = genBootstrap(todos, 3);
  if (content) try { fs.writeFileSync(path.join(dir, "STEP-GATE.md"), content, "utf-8"); } catch {}
}

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  D("=== step-gate v7 register() ===");
  if (!enabled) return;
  const wsDir = (): string => process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");
  const bootstrapHandler = async (event: any) => {
    D("bootstrap FIRED");
    const ctx = event?.context ?? {};
    const wd = ctx.workspaceDir || wsDir();
    const todos = findTodos(wd);
    D(`bootstrap: ${todos.length} todos`);
    if (!todos.length) return;
    for (const t of todos) syncCB(t.path, t.steps);
    const content = genBootstrap(todos, minSteps);
    if (!content) return;
    const fp = path.join(wd, "STEP-GATE.md");
    try { fs.writeFileSync(fp, content, "utf-8"); } catch {}
    const bf = ctx.bootstrapFiles;
    if (Array.isArray(bf)) {
      const idx = bf.findIndex((f: any) => f.name === "STEP-GATE.md" || f.path?.endsWith("STEP-GATE.md"));
      if (idx >= 0) bf.splice(idx, 1);
      bf.unshift({ name: "STEP-GATE.md", path: fp, content, source: "step-gate" });
      D(`injected STEP-GATE.md (${bf.length} files)`);
    }
  };
  api.registerHook("agent:bootstrap", bootstrapHandler, { name: "step-gate-bootstrap" });
  const g = globalThis as any;
  if (!g.__openclaw_internal_hook_handlers__) g.__openclaw_internal_hook_handlers__ = new Map();
  const hMap: Map<string, Function[]> = g.__openclaw_internal_hook_handlers__;
  if (!hMap.has("agent:bootstrap")) hMap.set("agent:bootstrap", []);
  hMap.get("agent:bootstrap")!.push(bootstrapHandler);
  setInterval(() => {
    try { syncAll(wsDir()); } catch (e: any) { D(`err: ${e.message}`); }
  }, 15000);
  D("v7 loaded");
  api.logger?.info?.("step-gate v7 loaded (auto-cb-sync + bootstrap)");
}
PLUGIN_EOF
info "Plugin 代码已写入"

# ── 更新 openclaw.json 配置 ──
info "更新 openclaw.json 配置..."

python3 << 'PYEOF'
import json, sys, os

config_path = os.environ.get("OC_CONFIG", os.path.expanduser("~/.openclaw/openclaw.json"))
plugin_dir = os.environ.get("PLUGIN_DIR", os.path.expanduser("~/.openclaw/extensions/step-gate"))

with open(config_path, "r") as f:
    cfg = json.load(f)

# Ensure plugins section exists
if "plugins" not in cfg:
    cfg["plugins"] = {}
if "entries" not in cfg["plugins"]:
    cfg["plugins"]["entries"] = {}
if "installs" not in cfg["plugins"]:
    cfg["plugins"]["installs"] = {}
if "load" not in cfg["plugins"]:
    cfg["plugins"]["load"] = {}
if "paths" not in cfg["plugins"]["load"]:
    cfg["plugins"]["load"]["paths"] = []

# Add step-gate entry
cfg["plugins"]["entries"]["step-gate"] = {
    "enabled": True,
    "config": {
        "enabled": True,
        "minSteps": 3
    }
}

# Add step-gate install record
cfg["plugins"]["installs"]["step-gate"] = {
    "source": "path",
    "spec": plugin_dir,
    "sourcePath": plugin_dir,
    "installPath": plugin_dir,
    "version": "7.0.0",
    "resolvedName": "step-gate",
    "resolvedVersion": "7.0.0"
}

# Add load path
if plugin_dir not in cfg["plugins"]["load"]["paths"]:
    cfg["plugins"]["load"]["paths"].append(plugin_dir)

# Enable internal hooks
if "hooks" not in cfg:
    cfg["hooks"] = {}
if "internal" not in cfg["hooks"]:
    cfg["hooks"]["internal"] = {}
cfg["hooks"]["internal"]["enabled"] = True

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("Config updated successfully")
PYEOF

info "openclaw.json 已更新"

# ── 安装 AGENTS.md（可选） ──
AGENTS_FILE="$OC_WORKSPACE/AGENTS.md"
INSTALL_AGENTS=true

if [ -f "$AGENTS_FILE" ]; then
    AGENTS_SIZE=$(wc -c < "$AGENTS_FILE")
    if [ "$AGENTS_SIZE" -gt 10000 ]; then
        warn "检测到现有 AGENTS.md (${AGENTS_SIZE} bytes)，较大，建议替换为精简版"
        warn "原文件将备份为 AGENTS-backup.md"
        cp "$AGENTS_FILE" "$OC_WORKSPACE/AGENTS-backup-$(date +%Y%m%d%H%M).md"
    else
        warn "检测到现有 AGENTS.md (${AGENTS_SIZE} bytes)，将备份后替换"
        cp "$AGENTS_FILE" "$OC_WORKSPACE/AGENTS-backup-$(date +%Y%m%d%H%M).md"
    fi
fi

if [ "$INSTALL_AGENTS" = true ]; then
    cat > "$AGENTS_FILE" << 'AGENTS_EOF'
# Agent Workflow & Operations Manual

## 0. Decision Priority Chain (CRITICAL)
When rules conflict, follow this priority order:
**Safety > User's Explicit Instruction > Cost Control > Skill-First > Default Behavior**

---

## 1. Session Startup (required)
Before doing anything else:
1. Read `SOUL.md` — this is who you are
2. Read `USER.md` — this is who you're helping
3. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
4. **If in MAIN SESSION** (direct chat): Also read `MEMORY.md`

Don't ask permission. Just do it.

---

## 2. Execution Modes

### Mode A: 快速响应模式
- 简单问答、单步查询、单次工具调用
- 直接执行，直接返回。不创建 todo 文件。

### Mode B: 复杂任务模式 (Agent Loop)
- 多步推理、跨工具协作、长程规划的任务
- **Phase 1 - Proposal**：生成分步计划，创建 todo 文件，向用户发送计划预览。**等待用户确认**后才执行。
- **Phase 2 - Execution**：用户确认后，静默执行全部步骤，完成后交付结果。

### 模式自动升级
- 如果 Mode A 执行中发现步骤将超过 3 步，自动升级到 Mode B。
- 已进入 Mode B 不降级。

---

## 3. Core Principles
1. **Skill-First**: 非简单任务必须先查 skills 列表，使用前必须 `read` 对应 `SKILL.md`。
2. **Task Decomposition**: 复杂目标拆解为单工具子任务，通过 todo 文件维护状态。
3. **Node-Awareness**: 需要本地交互时（browser、文件系统），路由到对应 Node。

---

## 4. Task Execution (Mode B)

### 4.1 三阶段协议

**阶段一：启动确认（Blocking）**
- 发送：任务目标 + 步骤清单 + 预估耗时
- 等待用户确认（"ok"、"go"、"开始"）

**阶段二：全程自治（Silent）**
- 按 todo 顺序逐步执行
- 每步完成后更新 Execution Log（Status: done + Result）
- 不主动打扰用户
- 禁止跳步、禁止合并步骤
- 失败连续3次才上报用户

**阶段三：交付结果（Blocking）**
- 标记 Status 为 Completed
- 发送交付消息（任务摘要 + 交付物 + 执行统计）

### 4.2 敏感操作（遇到即暂停，要求用户确认）
- 删除文件/目录
- 修改系统核心配置
- 调用付费服务（超出常规额度）
- 访问敏感服务（银行/支付/隐私数据）
- 发布公开内容（推文/邮件）

### 4.3 跳步处理
如必须跳步，先在 todo 写入 `Status: skipped` + `Reason`，然后继续。交付时汇报跳步说明。

---

## 5. Todo File Management

### 5.1 命名规范 (CRITICAL)
```
路径：~/.openclaw/workspace/todo_{YYYYMMDD}_{简短任务描述}.md
示例：~/.openclaw/workspace/todo_20260307_ev_market_research.md
```
- 禁止命名为 `todo.md`。必须包含日期和任务描述。
- 同一时间只有一个活跃 todo 文件。新任务先归档当前 todo（标记 `suspended`）。

### 5.2 文件格式（严格遵守）
```markdown
# Task: {任务简述}
# Created: {YYYY-MM-DD HH:MM}
# Status: In Progress | Suspended | Completed
## Plan
- [ ] 1. {步骤描述}
- [ ] 2. {步骤描述}
...
## Execution Log
### Step 1: {步骤描述}
- Status: done | failed | skipped
- Result: {一句话结果摘要}
### Step 2: ...
```

> **Note**: Checkbox 同步由 step-gate plugin 自动处理。你只需在 Execution Log 中正确标记 Status 即可。

### 5.3 归档
- 完成后标记 `Completed`，文件保留在 workspace。
- 超过 10 个已完成 todo 时，移动最早的到 `archive/`。

---

## 6. Error Handling
- 失败时先分析错误，换方法重试。不重复相同的失败操作。
- 连续 3 次失败后，暂停并向用户报告。

---

## 7. Memory
- **Daily log**: `memory/YYYY-MM-DD.md`
- **Long-term**: `MEMORY.md`（仅 main session 加载）
- 当用户引用过去的工作（"我们讨论过的"、"那个项目"），先 `memory_search` 再回应。
- 记住：你每次 session 都是全新的，连续性靠文件。

---

## 8. Safety Red Lines
- 不泄露私人数据
- 不运行破坏性命令（除非明确要求）
- `trash` > `rm`
- 群聊中不代替用户发言，不分享私人信息
- 有疑问就问

---

## 9. Automation
- **Cron**: 用 `schedule` 工具处理定时/周期任务
- **Heartbeat**: 由 Gateway 配置管理
AGENTS_EOF
    info "AGENTS.md 已安装 (精简版, 4KB)"
fi

# ── 重启 Gateway ──
info "重启 OpenClaw Gateway..."
if command -v openclaw &> /dev/null; then
    openclaw gateway restart 2>/dev/null && info "Gateway 已重启" || warn "Gateway 重启失败，请手动执行: openclaw gateway restart"
elif systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
    systemctl restart openclaw-gateway && info "Gateway 已重启" || warn "Gateway 重启失败，请手动执行: systemctl restart openclaw-gateway"
else
    warn "未检测到 Gateway 服务，请手动重启 OpenClaw"
fi

# ── 完成 ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Step Gate 安装完成!"
echo ""
echo "  已安装:"
echo "    - step-gate plugin → $PLUGIN_DIR"
echo "    - AGENTS.md (精简版) → $AGENTS_FILE"
echo ""
echo "  功能:"
echo "    - 自动 checkbox 同步 (每15秒从 Execution Log 检测)"
echo "    - Bootstrap 注入 (STEP-GATE.md 防跳步指令)"
echo "    - 精简 AGENTS.md (节省 ~75% 上下文)"
echo ""
echo "  验证:"
echo "    tail -f /tmp/step-gate.log"
echo ""
echo "  卸载:"
echo "    rm -rf $PLUGIN_DIR"
echo "    # 然后从 openclaw.json 中移除 step-gate 相关配置"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
