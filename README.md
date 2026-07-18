# stick-shift.nvim

An AI pair-programming harness for Neovim that gives the steering wheel back.

Most AI coding tools optimize for one thing: you describe, the agent writes.
Code appears, learning doesn't, and technical debt accumulates invisibly
because no human held the design. stick-shift.nvim inverts the default. It is a
**configurable handicap** on AI assistance: at its most permissive it behaves
like full vibe coding; dialed down, the AI does less of the writing and more
of the *scaffolding of thought* - it helps you start, keeps direction, and
checks your work - while you make the decisions and do the typing.

The second design goal is **unobtrusiveness**. At lower autonomy the tool
should not feel like a chatbot bolted onto your editor; it should feel like
the editor got quietly smarter. How much raw AI output you see is itself a
dial - from a full agent transcript down to nothing but a `Next step` button
and a one-line hint.

## The autonomy ladder

One number (0–4) governs everything. It is a real enum with a gating table,
not a prompt suggestion, and it is decoupled from model choice.

| Level | Name | Authority | You see | Buffer writes |
|---|---|---|---|---|
| 4 | Autopilot | Full agent: prompt in, code out | Full raw transcript | Agent writes freely (checkpointed) |
| 3 | Driver-assist | Agent implements the current step on request, stops at step boundaries | Transcript summary + step panel | Agent writes on explicit `Implement step` |
| 2 | Co-pilot *(default)* | AI plans and verifies; **the human types the code** | Step panel, Verify/Next, ghost completion, hint - no raw transcript | Human only |
| 1 | Navigator | AI keeps the plan, answers when asked, volunteers nothing | Panel on demand; hint only if asked | Human only |
| 0 | Hint-only | Minimal | One-sentence hint on request; no plan surfaced, no completion | Human only |

Transcript visibility (`ui.transcript = "full"|"summary"|"hidden"`) is a
separate dial that defaults from the level but can be overridden - you can
run autopilot silently or co-pilot with full logs.

## The living plan

The centerpiece is a plan the AI maintains as its working memory across the
session, stored in `.stick-shift/` under your project root:

- **Detail gradient** - the current step is the most detailed; later steps
  are intentionally vague. Over-specifying the far future is wasted effort.
- **It mutates** - the plan follows the code, not the other way around. Each
  `Verify` and `Next` can reshape downstream steps and records why in an
  append-only decision log.
- **Never a black box** - by default the panel shows only the current step,
  but the full plan is always inspectable with `:StickShiftPlan` (read-only
  rendered markdown) and directly editable with `:StickShiftPlan!` at autonomy
  levels ≤ 2, where rewriting the AI's working memory is a feature.

`.stick-shift/` layout (git-ignored by default via its own `.gitignore`):

```
.stick-shift/
  plan.json         # source of truth: steps, statuses, backend session id
  plan.md           # human-readable render (what :StickShiftPlan shows)
  decisions.log     # append-only log of meaningful course changes
  checkpoints.json  # snapshot refs taken before agent edits
  .gitignore        # contains "*"; delete it to track the plan in git
```

Step statuses are `pending`, `active`, `verified` - plus `skipped`, a
pragmatic extension for when you advance past a step without verifying it
(recorded honestly instead of pretending it was done).

## Verify: two confidence signals, never conflated

`Verify step` runs as an isolated subtask (fresh context; only a structured
summary returns) and is **scoped**, never a full-repo reread:

1. The changed surface = the step's expected `touched` files plus the actual
   git diff since the step began (untracked files included).
2. Your project's **real test command** runs (configurable, or auto-detected
   for npm / cargo / go / pytest / make / mix) and its output is captured.
3. The LLM sees only the scoped diff and the test output and returns a
   structured verdict.
4. The result reports **two separate confidence signals**: "the LLM thinks
   the diff matches the step" and "the test suite actually passed". The
   plugin merges in the test ground truth itself - the model never gets to
   claim test results, and an LLM eyeball never substitutes for a green run.
   A step is only marked `verified` when the LLM verdict is positive *and*
   tests (if any ran) passed.

## Quick start

```lua
require("stick-shift").setup({})   -- defaults: co-pilot (level 2), claude_code backend
```

1. Open your project and run `:StickShiftGoal build a todo CLI in Lua`. The AI
   drafts a living plan and the first step becomes current.
2. Write the code for the current step yourself (with ghost-text completion
   and `:StickShiftHint` if you want a nudge).
3. `:StickShiftVerify` - scoped check + real test run, two confidence signals.
4. `:StickShiftNext` - the next step gets its detail filled in and becomes
   current; later steps are reshaped if your decisions changed anything.
5. `:StickShift` toggles the panel; `:StickShiftAutonomy 4` when you just want it done.

No API key needed to try it: `backend = "mock"` runs the whole loop offline
with canned responses.

## Installation

Requires Neovim 0.11+ and git. Backends need their own tools (`claude` CLI,
`ollama`, or curl - see [Backends](#backends)).

### lazy.nvim

```lua
{
  "00nateo/stick-shift.nvim",
  opts = {},
}
```

### Neovim 0.12 vim.pack

Per the Neovim 0.12 `vim.pack` docs (verified against
[neovim.io/doc/user/pack.html](https://neovim.io/doc/user/pack.html);
untested here - this machine runs 0.11.5, which has no `vim.pack`):

```lua
vim.pack.add({
  { src = "https://github.com/00nateo/stick-shift.nvim" },
})
require("stick-shift").setup({})
```

### Any plugin manager

Put the repo on your runtimepath, then:

```lua
require("stick-shift").setup({})
```

### Packer (legacy, not the recommended path)

```lua
use({ "00nateo/stick-shift.nvim", config = function() require("stick-shift").setup({}) end })
```

## Commands

| Command | Description |
|---|---|
| `:StickShift` | Toggle the panel |
| `:StickShift {layout}` | Move the panel: `left`/`right`/`top`/`bottom`/`float` (opens it if closed) |
| `:StickShiftGoal {text}` | Set the goal and create (or re-create) the living plan - the entry point. No argument prompts for input |
| `:StickShiftPlan` | Inspect the rendered plan (read-only) |
| `:StickShiftPlan!` | Edit `plan.json` directly (autonomy ≤ 2 only) |
| `:StickShiftVerify` | Verify the current step (scoped diff + real tests) |
| `:StickShiftNext` | Advance: fill in the next step's detail, make it current |
| `:StickShiftImplement` | Agent implements the current step (autonomy ≥ 3) |
| `:StickShiftHint` | One-sentence hint at the cursor |
| `:StickShiftAutonomy {0..4}` | Set the autonomy level; no argument shows it |
| `:StickShiftBackend {name}` | Switch backend; no argument shows the active one |
| `:StickShiftRevert` | Restore the working tree to the last checkpoint |
| `:checkhealth stick-shift` | Environment and backend diagnostics |

Default keymaps (all overridable, set to `false` to disable): `<leader>ss`
toggle panel, `<leader>sv` verify, `<leader>sn` next, `<leader>sa` cycle
autonomy, `<leader>sh` hint. In insert mode, `<Tab>` accepts a ghost
completion and falls through to a normal `<Tab>` when there is none.

## Configuration

Defaults, verbatim from `lua/stick-shift/config.lua` (pass only the keys you want
to change; unknown keys warn, invalid values fall back to defaults):

```lua
require("stick-shift").setup({
  -- 0..4: hint-only, navigator, co-pilot, driver-assist, autopilot. See :help stick-shift-autonomy.
  autonomy = 2,
  -- Active backend adapter: "claude_code" | "acp" | "ollama" | "local_mac" | "mock"
  backend = "claude_code",
  -- Per-role model routing, decoupled from autonomy. Each value is either an
  -- alias string ("local"/"frontier"/explicit model name) resolved by the
  -- active adapter, or { backend = "<adapter>", model = "<name>" } to pin a
  -- different adapter for that role.
  models = {
    ghost = "local",
    hint = "local",
    plan = "frontier",
    verify = "frontier",
    next_step = "frontier",
  },
  ui = {
    layout = "right", -- "left" | "top" | "right" | "bottom" | "float" (movable live via :StickShift {layout})
    transcript = nil, -- nil = derive from autonomy; else "full"|"summary"|"hidden"
    open_on_start = false, -- note: at autonomy 3-4 the panel opens on setup regardless
    width = 48, -- columns for left/right docks and float
    height = 14, -- rows for top/bottom docks and float
  },
  plan = {
    visibility = "current-only", -- "hidden" | "current-only" | "full"
  },
  completion = {
    level = "line", -- "off" | "word" | "line" | "multiline" | "paragraph"
    accept_key = "<Tab>",
    debounce_ms = 180,
    force = false, -- allow completion below autonomy level 2
  },
  hint = {
    enabled = true,
    trigger = "manual", -- "auto" | "manual"
    max_len = 120,
  },
  verify = {
    test_command = nil, -- string; nil = auto-detect when auto_detect_tests
    auto_detect_tests = true,
    timeout_ms = 120000,
  },
  git = {
    tag_commits = false, -- add "StickShift-Autonomy: N (name)" trailer to assisted commits
    checkpoint = true, -- snapshot before agent-driven edits (levels 3-4)
  },
  backends = {
    claude_code = {
      bin = "claude",
      model_local = "haiku", -- CLI alias; cheap roles
      model_frontier = nil, -- nil = the CLI's configured default model
      extra_args = {},
    },
    ollama = {
      host = "http://localhost:11434",
      model_local = "qwen3-coder:30b",
      model_frontier = "qwen3-coder:30b",
    },
    acp = {
      command = nil, -- argv table, e.g. { "claude-code-acp" }
    },
    local_mac = {
      url = "http://localhost:8080/v1",
      model = "default",
    },
  },
  keymaps = {
    -- set any to false to disable
    toggle_panel = "<leader>ss",
    verify = "<leader>sv",
    next = "<leader>sn",
    cycle_autonomy = "<leader>sa",
    hint = "<leader>sh",
  },
})
```

## Backends

All backends implement one adapter interface; switch at runtime with
`:StickShiftBackend {name}`.

- **claude_code** (default) - runs the `claude` CLI headless (`-p` with a
  JSON envelope; session `--resume` gives free conversation persistence, the
  id is stored in `plan.json`). For `Implement step` it streams the agent's
  events into the transcript. It runs as *your own authenticated tool*: no
  background daemon hammering it, and stick-shift never embeds, reads, or logs
  credentials - use it within the usage terms of your Claude subscription.
- **ollama** - plain HTTP to a local Ollama server via curl. Good cheap
  target for the ghost/hint roles.
- **acp** - Agent Client Protocol (JSON-RPC over stdio) client for ACP
  agents. In first integration; see [Status](#status).
- **local_mac** - OpenAI-compatible local server (MLX etc.). In first
  integration; see [Status](#status).
- **mock** - deterministic canned responses; makes the whole core loop
  runnable offline and is what the tests use.

### Per-role model routing

Model choice is decoupled from autonomy. Each role (`ghost`, `hint`, `plan`,
`verify`, `next_step`) resolves independently and may even pin a different
adapter than the active backend:

```lua
require("stick-shift").setup({
  backend = "claude_code",
  models = {
    -- cheap, local, fast for the high-frequency roles:
    ghost = { backend = "ollama", model = "qwen3-coder:30b" },
    hint  = { backend = "ollama", model = "qwen3-coder:30b" },
    -- frontier model for the roles that shape the plan:
    plan      = "frontier",
    verify    = "frontier",
    next_step = "frontier",
  },
})
```

## Safety

These are core mechanics, not footnotes:

- **Single-writer buffer lock** - completion-accept and agent edits both
  have to acquire a per-buffer lock; two writers can never touch the same
  buffer at once. Ghost text *display* is lock-free; accepting it takes the
  lock.
- **Per-step checkpoints** (levels 3–4) - before the agent writes, a
  non-mutating git snapshot is taken (includes untracked files; refs recorded
  in `.stick-shift/checkpoints.json`). `:StickShiftRevert` restores the working tree
  from the last snapshot. Known limitation: files the agent *created after*
  the snapshot are not deleted by the restore - review with `git status`.
- **Append-only decision log** - `.stick-shift/decisions.log` records one line per
  meaningful course change.
- **Autonomy-tagged commits** (opt-in `git.tag_commits`) - commit-message
  buffers (`gitcommit` filetype) get a `StickShift-Autonomy: 2 (co-pilot)` trailer
  inserted automatically, so `git log` shows how much of the history was
  machine-assisted. Delete the line before saving to opt out per-commit.

## Health

`:checkhealth stick-shift` reports the Neovim version, git, each registered
backend's availability (claude binary, ollama reachability), the detected
test command for the current project, and whether a plan exists.

## Developing

```sh
# manual smoke: loads only this repo, mock backend, level 2
nvim -u scripts/minimal_init.lua

# headless smoke test of the core loop (plan -> verify -> next)
nvim --headless -l scripts/smoke.lua

# test suite (exit code = number of failures)
nvim --headless -l tests/run.lua
```

Backends are plain adapter tables - see `lua/stick-shift/backend/init.lua` for the
contract and `lua/stick-shift/backend/mock.lua` for the reference implementation.
`:help stick-shift-develop` has the details.

## Status

Honest state as of the last build pass:

- **Core loop** (config + validation, autonomy gating, plan store, lifecycle
  plan/verify/next, backend runner with schema validation + one retry, buffer
  lock, mock backend): implemented, covered by the offline test suite
  (`nvim --headless -l tests/run.lua`: 172 passing tests, 0 failing) plus a
  headless smoke test of the full loop.
- **Panel UI, ghost completion, hint, checkpoints, health**: implemented and
  tested offline (including panel window edge cases and completion staleness
  guards, exercised headlessly).
- **claude_code adapter**: one-shot `generate` (JSON envelope) and the
  agentic `implement` path (stream-json, `--permission-mode acceptEdits`)
  both verified against the real `claude` CLI 2.1.208 on this machine.
- **ollama adapter**: verified against a live local ollama server
  (`/api/generate`, `format: "json"`).
- **acp / local_mac adapters**: request construction and response parsing are
  exercised only against scripted/canned responses - NOT yet validated
  against a live ACP agent or MLX/llama.cpp server. `available()` and
  `:checkhealth stick-shift` report this honestly.
- Remaining `TODO(stick-shift)` markers: `touched` symbol expansion via
  LSP/Tree-sitter (verify-diff narrowing), Neovim 0.12 native
  `vim.lsp.inline_completion` integration, ACP live validation and
  `session/load` reuse, local_mac live-server validation.

## Non-goals

No general chatbot. No hardcoded keys or endpoints; secrets are never
logged. The plan is never a permanent black box. Autonomy is not model
choice. No full-repo rereads on verify.

## License

MIT - see [LICENSE](LICENSE).
