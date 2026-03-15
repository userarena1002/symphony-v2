---
tracker:
  kind: linear
  project_slug: "clip-engine-10822e5d7361"
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/code/symphony-v2-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/userarena1002/clip-engine.git .
    npm ci
agent:
  backend: claude
  max_concurrent_agents: 2
  max_turns: 10
  session_timeout_ms: 3600000
  allowed_tools:
    - Read
    - Write
    - Edit
    - Bash
    - Glob
    - Grep
codex:
  command: "claude -p --output-format stream-json"
  approval_policy: never
  thread_sandbox: danger-full-access
  stall_timeout_ms: 300000
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
server:
  port: 4000
  host: "0.0.0.0"
---

You are working on a Linear ticket `{{ issue.identifier }}` for the `clip-engine` repository.

{% if attempt %}
This is retry attempt #{{ attempt }}. Resume from the current workspace state.
{% endif %}

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:
1. This is a Next.js application.
2. Work only in the provided workspace directory.
3. Run `npm run typecheck` to validate changes.
4. Create a feature branch named after the issue identifier.
5. Make clean, focused commits.
6. When done, push the branch and create a PR.
