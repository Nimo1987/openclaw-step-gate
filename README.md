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

Step Gate v11 由两个组件协同工作：

| 组件 | 部署位置 | 职责 |
|---|---|---|
| **Internal Hook** | `~/.openclaw/hooks/step-gate/` | 监听 `agent:bootstrap` 事件，将 STEP-GATE.md 注入 agent 上下文 |
| **Plugin** | `~/.openclaw/extensions/step-gate/` | 每 15 秒扫描 todo 文件，自动同步 checkbox |

### 为什么是两个组件？

> OpenClaw 有两套独立的 Hook 系统：**Plugin Hook System**（`api.registerHook()`）和 **Internal Hook System**（`HOOK.md` + `handler.js`）。`agent:bootstrap` 是 Internal Hook 的事件，Plugin 的 `api.registerHook()` 注册的 handler 永远不会被 Internal Hook System 调用。
>
> v1-v10 一直试图用 Plugin 的 `api.registerHook("agent:bootstrap")` + globalThis hack 来注入 bootstrap，**从未成功**。v11 把 bootstrap 注入正确地放到了 Internal Hook 系统。

## 安装

```bash
# 一键安装
curl -sL https://raw.githubusercontent.com/Nimo1987/openclaw-step-gate/main/install.sh | sudo bash
```

或手动：

```bash
git clone https://github.com/Nimo1987/openclaw-step-gate.git
cd openclaw-step-gate
sudo bash install.sh
```

安装脚本会：
1. 创建 `~/.openclaw/hooks/step-gate/`（HOOK.md + handler.js）
2. 创建 `~/.openclaw/extensions/step-gate/`（plugin manifest + index.ts）
3. 更新 `openclaw.json`（启用 plugin + hook）
4. 重启 Gateway

## 工作原理

```
Agent 启动 session
    ↓
agent:bootstrap 事件触发
    ↓
Internal Hook 扫描 todo*.md → 生成 STEP-GATE.md → 注入 bootstrapFiles
    ↓
Agent 看到步骤纪律 + 当前进度
    ↓
Agent 执行步骤 → 更新 Execution Log (Status: done)
    ↓
Plugin 15s 定时器检测到 → 自动改 checkbox [ ] → [x]
    ↓
下次 session 启动时注入最新进度
```

## 验证

```bash
# 实时日志
tail -f /tmp/step-gate.log

# 发一条消息触发 /new，应该看到：
# [hook] bootstrap FIRED
# [hook] found X todos (Y completed)
# [hook] injected STEP-GATE.md (Z total bootstrap files)

# 检查生成的文件
cat ~/.openclaw/workspace/STEP-GATE.md
```

## 配置

在 `openclaw.json` 的 `plugins.entries.step-gate.config` 中：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `enabled` | boolean | `true` | 启用/禁用 checkbox 同步 |
| `minSteps` | number | `3` | 最少多少步才触发 |
| `syncInterval` | number | `15000` | 同步间隔（毫秒） |

## Todo 文件格式

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
```

文件名必须以 `todo` 开头、`.md` 结尾，且在最近 24 小时内修改过。

## 卸载

```bash
rm -rf ~/.openclaw/hooks/step-gate
rm -rf ~/.openclaw/extensions/step-gate
# 从 openclaw.json 中移除 step-gate 相关配置
```

## 版本历史

| 版本 | 变化 |
|---|---|
| v1-v4 | 探索阶段：错误的 hook event 名、plugin 未注册 |
| v5-v10 | Plugin-only 方案。用 `api.registerHook("agent:bootstrap")` + globalThis hack。**从未生效** — 用错了 hook 系统 |
| **v11** | 拆分为 Internal Hook + Plugin。Bootstrap 注入终于用对了系统。 |

## License

MIT
