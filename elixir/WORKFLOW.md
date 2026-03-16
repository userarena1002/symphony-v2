---
tracker:
  kind: linear
  project_slug: "clip-engine-10822e5d7361"
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
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
    git fetch --all --prune
    if [ -n "$CLIP_ENGINE_ENV_FILE" ] && [ -f "$CLIP_ENGINE_ENV_FILE" ]; then
      cp "$CLIP_ENGINE_ENV_FILE" .env
    fi
    npm ci
agent:
  backend: claude
  max_concurrent_agents: 3
  max_turns: 200
  session_timeout_ms: 3600000
  allowed_tools:
    - Read
    - Write
    - Edit
    - Bash
    - Glob
    - Grep
codex:
  command: "claude --print --output-format stream-json --verbose"
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
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Prefer short, checkpointed turns over one long uninterrupted turn.
- After any meaningful milestone, update the local workpad, then it is acceptable to end the current turn while the issue remains in an active state so Symphony can resume from fresh context on the next poll.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions unless blocked by missing auth, missing secrets, or missing service access.
2. Final message must report completed actions and blockers only. Do not include user next steps unless blocked.
3. Work only in the provided repository copy. Do not touch any other path.

## Linear interaction

Symphony handles Linear state transitions automatically:
- Issue is moved to `In Progress` when dispatched to you.
- Issue is moved to `Human Review` when you complete successfully.

You do NOT need to update the Linear issue state. Focus on the code work.

If you need to add a comment to the Linear issue, use the `gh` CLI or `curl` with
the Linear GraphQL API. The LINEAR_API_KEY environment variable is available.

Example to add a comment:
```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "mutation { commentCreate(input: { issueId: \"<issue_id>\", body: \"Your comment\" }) { success } }"}'
```

## Repository posture

- This repo is a Next.js application.
- Minimum validation is `npm run typecheck`.
- If app behavior changes, run targeted app validation in addition to typecheck.
- If UI changes, launch the app and validate the changed path directly.
- Respect existing repo conventions and avoid destructive git operations.
- Runtime for this workflow is full local access:
  - git branch/fetch/push operations are allowed,
  - localhost app servers may be started for preview and validation,
  - browser automation may be used for UI proof and walkthrough capture.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by reading the local workpad at `.symphony/workpad.md` (if it exists) and bringing it up to date before doing new implementation work.
- Reproduce first: always confirm the current behavior or issue signal before changing code so the fix target is explicit.
- Keep exploration lean. Prefer search-first narrowing over broad file reads.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.

## Related skills

The `.codex/skills/` directory contains workflow skills. Use them by reading the SKILL.md file in each:
- `commit`: create clean commits. Read `.codex/skills/commit/SKILL.md` for instructions.
- `push`: keep the remote branch current and create or update a PR. Read `.codex/skills/push/SKILL.md` for instructions.
- `pull`: merge latest `origin/main` into the branch before handoff. Read `.codex/skills/pull/SKILL.md` for instructions.
- `land`: when the issue reaches `Merging`, read `.codex/skills/land/SKILL.md` for instructions.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; Symphony moves to `In Progress` on dispatch.
- `In Progress` -> implementation actively underway.
- `Human Review` -> PR is attached and validated; Symphony moves here on completion.
- `Merging` -> approved by human; execute the `land` skill flow.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Execution requirements

1. Maintain a local workpad file at `.symphony/workpad.md`.
2. Keep a checklist-based plan, acceptance criteria, and validation section in that file.
3. Record a compact environment stamp at the top of the workpad in the form `<host>:<abs-workdir>@<short-sha>`.
4. Use the `pull` skill (read `.codex/skills/pull/SKILL.md`) before implementation and record the result in the workpad notes.
5. Before every push, rerun required validation and confirm it passes.
6. Before the session ends, ensure:
   - acceptance criteria are checked off in the workpad,
   - validation is documented,
   - the branch is pushed and a PR exists (use the `push` skill),
   - the latest branch includes `origin/main`.

## Clip Engine-specific validation baseline

- Run `npm run typecheck`.
- If the ticket touches UI, run the relevant page locally and validate the changed flow.
- If the ticket touches render or editing logic, capture the exact clip or route used for proof.
- If a ticket provides a manual QA or validation checklist, mirror it into the workpad and complete it explicitly.
- For UI validation, stop once you have one clear reproduction and one clear proof of the changed behavior. Do not stay in long browser exploration loops after the acceptance criteria are proven.

## Exploration discipline

- First use `rg`, `rg --files`, or similarly narrow discovery commands to identify the smallest set of candidate files.
- Do not read entire large files by default.
- When opening source files, read the smallest relevant slice first:
  - target roughly 80-160 lines around the likely edit site
  - expand only if the first slice is insufficient
- Avoid repeated full-file dumps of the same file in one turn.
- For UI tickets, identify the primary component file and any one supporting style/theme file before launching the app.

## Review handoff requirements for app changes

- For any ticket that changes app behavior or UI, add a `### Review Launch` section to the workpad before completion.
- If `./scripts/start-preview-detached.sh` exists, start a detached review server using:
  - `cd <workspace-abs-path> && ./scripts/start-preview-detached.sh {{ issue.identifier }} --port <chosen-port>`
- That section must include:
  - the exact detached launch command used,
  - the localhost URL or external preview URL,
  - the specific page or route to open.
- Choose a non-default port so multiple review workspaces can run side by side.

## Git workflow

- Create a feature branch named after the issue identifier (e.g., `USE-22`).
- Make clean, focused commits using the `commit` skill.
- Push the branch and create a PR using the `push` skill.
- The PR title should include the issue identifier and a brief description.
- Always push your work before the session ends — unpushed work is invisible to reviewers.

## CRITICAL: Completion checklist

You MUST complete ALL of the following before your session ends. Do not exit
until every item is done. This is not optional.

1. **Code changes** — implement the ticket requirements
2. **Validation** — run `npm run typecheck` and confirm it passes
3. **Commit** — stage and commit all changes with a clear message
4. **Push** — push the branch to origin (read `.codex/skills/push/SKILL.md`)
5. **Pull request** — create a PR using `gh pr create` with the issue identifier in the title
6. **Preview server** — if `./scripts/start-preview-detached.sh` exists, start a detached preview server on a unique port and note the URL in the workpad
7. **Workpad** — update `.symphony/workpad.md` with final status

If you are running low on context or turns, prioritize in this order:
commit → push → PR → everything else. Unpushed code is lost work.
