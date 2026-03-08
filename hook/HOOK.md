---
name: step-gate
description: "Inject STEP-GATE.md into agent bootstrap context to enforce step execution discipline"
metadata:
  {
    "openclaw":
      {
        "emoji": "🚦",
        "events": ["agent:bootstrap"],
        "always": true,
      },
  }
---
# Step Gate — Bootstrap Hook

Injects `STEP-GATE.md` into the agent's bootstrap context on every session start.

Scans workspace for active `todo*.md` files, builds a progress summary with step-by-step
execution rules, and prepends it to `bootstrapFiles` so the agent sees it first.

Works together with the step-gate plugin (periodic checkbox sync).
