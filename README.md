# Step Gate

**让 AI Agent 老老实实按步骤干活。**

一个 [OpenClaw](https://openclaw.ai) 插件，解决 Agent 执行多步任务时跳步、合并步骤、忘记更新进度的问题。

---

## 问题

给 Agent 一个 10 步任务，它会：

1. 创建一个漂亮的 todo 文件，列出 10 个步骤
2. 一口气做完所有事
3. 最后才回来"补作业"——把所有 checkbox 一次性勾上

结果：你看到的进度永远是 0% 或 100%，中间没有任何反馈。

更糟的是，Agent 经常在 Execution Log 里写了 `Status: done`，但**忘记勾 checkbox**。

## 解决方案

Step Gate 做两件事：

**1. 自动 Checkbox 同步**

每 15 秒扫描 workspace 中的 todo 文件。如果 Execution Log 里某步标记了 `Status: done`，但 checkbox 还是 `[ ]`，自动改成 `[x]`。

不依赖 Agent 的"自觉性"。

**2. Bootstrap 注入**

每次 Agent 启动新 session 时，将当前任务进度注入到 Agent 上下文中（通过 `STEP-GATE.md`）。内容包括：

- 当前任务的所有步骤和完成状态
- "不许跳步、不许合并"的执行纪律
- 当前应该执行哪一步

```
⬜ Step 1: 搜索市场规模数据 ← NOW
⬜ Step 2: 分析竞品
⬜ Step 3: 生成报告

→ Execute Step 1 now.
```

## 安装

SSH 到 OpenClaw 服务器：

```bash
# 下载
git clone https://github.com/Nimo1987/openclaw-step-gate.git
cd openclaw-step-gate

# 一键安装（包含 plugin + 精简版 AGENTS.md）
sudo bash install.sh
```

或者手动安装：

```bash
# 1. 复制 plugin 文件
mkdir -p ~/.openclaw/extensions/step-gate
cp index.ts openclaw.plugin.json ~/.openclaw/extensions/step-gate/

# 2. 编辑 ~/.openclaw/openclaw.json，添加：
# plugins.entries.step-gate: { "enabled": true, "config": { "enabled": true, "minSteps": 3 } }
# plugins.installs.step-gate: { "source": "path", "installPath": "~/.openclaw/extensions/step-gate" }
# plugins.load.paths: ["~/.openclaw/extensions/step-gate"]
# hooks.internal.enabled: true

# 3. 重启
openclaw gateway restart
```

## 验证

```bash
tail -f /tmp/step-gate.log
```

正常输出：
```
[2026-03-08T08:12:09Z] === step-gate register() ===
[2026-03-08T08:12:09Z] loaded
[2026-03-08T08:12:09Z] bootstrap FIRED
[2026-03-08T08:12:09Z] bootstrap: 1 todos
[2026-03-08T08:12:09Z] injected STEP-GATE.md (9 files)
[2026-03-08T08:12:24Z] cb:1
[2026-03-08T08:12:39Z] cb:2
```

## 工作原理

```
Agent 创建 todo → 执行步骤 → 更新 Execution Log (Status: done)
                                        ↓
                              Plugin 15s 定时器检测到
                                        ↓
                              自动改 checkbox [ ] → [x]
                              自动更新 STEP-GATE.md
                                        ↓
                              下次 bootstrap 注入最新进度
```

### 为什么不用 Hook 实时同步？

试过了。OpenClaw 的 hook 系统有以下限制：

- `agent:bootstrap` 只在 session 开始时触发一次
- 没有 `after_tool_call` 级别的 hook
- `tool_result_persist` 是同步的，只能修改 tool result，无法阻断执行流
- Plugin 的 `register()` 在 hooks loader 之前执行，导致 handler map 可能被重置

最终方案：**定时器轮询 + globalThis fallback**。不优雅，但稳定。

### 为什么附带 AGENTS.md？

OpenClaw 的默认 AGENTS.md 模板需要用户自己填充。大多数用户会写很长的执行规则（我们的原版是 357 行 / 17KB），其中大量内容与 Step Gate 功能重复。

精简版 AGENTS.md（134 行 / 4KB）：
- 删除了被 plugin 替代的内容（checkbox 强制读写规则、Todo Guard 工具、ASCII 流程图）
- 保留了核心执行逻辑（Mode A/B、三阶段协议、敏感操作白名单）
- 补充了官方模板要求的必要章节（Session Startup、Safety Red Lines）
- **节省约 75% 的上下文 token**

## 配置

在 `openclaw.json` 的 `plugins.entries.step-gate.config` 中：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | boolean | `true` | 启用/禁用 |
| `minSteps` | number | `3` | 最少多少步才触发 |
| `syncInterval` | number | `15000` | 同步间隔（毫秒） |

## Todo 文件格式

Step Gate 识别以下格式的 todo 文件：

```markdown
# Task: 某个任务
# Created: 2026-03-08 15:00
# Status: In Progress

## Plan
- [ ] 1. 第一步
- [ ] 2. 第二步
- [ ] 3. 第三步

## Execution Log
### Step 1: 第一步
- Status: done
- Result: 完成了

### Step 2: 第二步
- Status: done
- Result: 也完成了
```

文件名必须以 `todo` 开头、`.md` 结尾，且在最近 24 小时内修改过。

## 卸载

```bash
rm -rf ~/.openclaw/extensions/step-gate/
# 从 openclaw.json 中移除 step-gate 相关配置
openclaw gateway restart
```

## 兼容性

- OpenClaw v1.x+
- 任意 LLM 模型（不依赖特定模型的指令遵从能力）
- 需要 `hooks.internal.enabled: true`（安装脚本自动配置）

## License

MIT
