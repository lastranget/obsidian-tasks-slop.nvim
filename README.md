# nvim-tasks

A Neovim plugin that re-implements the [Obsidian Tasks](https://github.com/obsidian-tasks-group/obsidian-tasks) plugin natively in Lua.

Built by auditing the original TypeScript source. Parsing, serialization, urgency scoring, recurrence, status types, and the query language all match the original plugin's behavior. Task lines are fully interchangeable between Neovim and Obsidian.

## Dependencies

| Dependency | Purpose | Required |
|-----------|---------|----------|
| [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) | Async vault scanning (scandir, ripgrep jobs, path utils) | **Yes** |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Picker, input prompts, notifications | **Yes** |
| [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim) | Auto-detects vault path from workspace config | Optional (auto-detected) |
| [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) | Coordinates to avoid rendering conflicts | Optional (auto-detected) |

## Installation

### lazy.nvim

```lua
{
  "lastranget/obsidian-tasks-slop.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "folke/snacks.nvim",
  },
  ft = { "markdown" },
  opts = {},  -- vault_paths auto-detected from obsidian.nvim
}
```

### render-markdown.nvim coordination

If you use render-markdown.nvim, add `'tasks'` to its `code.disable` list to prevent it from styling `tasks` code blocks (nvim-tasks renders its own virtual text overlay):

```lua
require("render-markdown").setup({
  code = {
    disable = { "tasks" },
  },
})
```

nvim-tasks inspects render-markdown's runtime config on each render. If `'tasks'` is already in `code.disable` (or all code rendering is disabled), no warning appears. Otherwise a one-time warning points to this snippet.

### obsidian.nvim integration

If `vault_paths` is empty (the default), nvim-tasks reads the vault root from obsidian.nvim's globals — preferring `Obsidian.dir` (vault root), falling back to `Obsidian.workspace.root`, then `Obsidian.workspace.path`. No duplicate configuration needed — just make sure obsidian.nvim loads first:

```lua
-- obsidian.nvim
{ "obsidian-nvim/obsidian.nvim", opts = { workspaces = { { name = "vault", path = "~/vault" } } } },
-- nvim-tasks (auto-detects ~/vault from obsidian.nvim)
{ "your-username/nvim-tasks", dependencies = { "nvim-lua/plenary.nvim", "folke/snacks.nvim" }, opts = {} },
```

To override, set `vault_paths` explicitly:

```lua
require("nvim-tasks").setup({ vault_paths = { "~/vaults/personal", "~/vaults/work" } })
```

## Quick Start

1. Install the plugin with dependencies.
2. Call `require("nvim-tasks").setup({})` — vault path auto-detects from obsidian.nvim.
3. Write a task: `- [ ] Buy groceries ⏫ 📅 2026-04-20`
4. Press `<C-CR>` to toggle done.
5. Write a query block, results render automatically:

````markdown
```tasks
not done
due before tomorrow
sort by priority
group by filename
```
````

6. `<leader>otr` toggles between rendered results and raw edit view.
7. `<leader>otF` opens the Snacks picker to search all tasks across your vault.
8. `<leader>otc` starts the sequential create/edit wizard.

## Task Format

Full compatibility with the Obsidian Tasks Emoji Format, including alternate emoji variants.

### Priority

🔺 Highest · ⏫ High · 🔼 Medium · *(none)* · 🔽 Low · ⏬ Lowest

### Dates

📅 Due (also accepts 📆 🗓) · ⏳ Scheduled (also ⌛) · 🛫 Start · ➕ Created · ✅ Done · ❌ Cancelled

### Recurrence

`🔁 every day` · `every N weeks` · `every month` · `every weekday` · `every monday` · `every january on the 4th` · append `when done` to base on completion date.

### Other

🆔 Task ID · ⛔ Depends on (comma-separated) · 🏁 On completion (`delete` / `keep`) · `^block-link` preserved

### Status Types

`[ ]` TODO · `[x]` / `[X]` DONE · `[/]` IN_PROGRESS · `[-]` CANCELLED · `[h]` ON_HOLD · `[Q]` NON_TASK

The default status table matches Obsidian Tasks' built-ins. Override `statuses` in `setup()` to use different symbols (e.g. `>` for on-hold).

## Task Management

### Task lines

Any line matching `[indent][list-marker] [status] description` is a task. Supported:

- **List markers:** `-`, `*`, `+`, `1.`, `1)` (numbered lists accept a single terminator).
- **Callouts:** tasks inside Obsidian callouts parse correctly — `> - [ ] Task in callout` and `>> - [ ] Nested` both work.
- **Status symbols:** any single Unicode codepoint (ASCII or multi-byte). Custom themes using e.g. `[▸]` or `[🔥]` round-trip faithfully.

### Toggle Done (`<C-CR>`)

| Line Type | Result |
|-----------|--------|
| Task line | Toggles done with ✅ date, handles recurrence |
| Plain checklist | Toggles checkbox |
| List item without checkbox | Adds `[ ]` |
| Plain text | Converts to `- [ ] text` |

### Create/Edit Wizard (`<leader>otc`)

Sequential Snacks.input prompts: Description → Priority (select) → Due date → Scheduled → Recurrence → Tags → save. Pre-fills when cursor is on an existing task.

### Task Search (`<leader>otF`)

Opens Snacks picker with all vault tasks. Priority-colored, due-date badges, file source. Press enter to jump to the task's source file and line.

## Query Language

Write queries inside `` ```tasks `` code blocks. Each line is one instruction. `#` lines are comments.

### Filters

**Status:** `done`, `not done`, `status.type is/is not <TYPE>`, `status.name includes/does not include <text>`

**Dates** (for `due`, `scheduled`, `starts`, `created`, `done`, `cancelled`, `happens`):
`<field> on/before/after/on or before/on or after <date>` · `<field> in or before <date>` · `<field> in or after <date>` · `<field> <date>` (shorthand for `on`) · `<field> in this week` · `<field> in last month` · `<field> in 2026-01-01 2026-03-31` · `has/no <field> date` · `<field> date is invalid`

Dates accept: `YYYY-MM-DD`, `today`, `tomorrow`, `yesterday`, `+3d`, `-1w`. The shorthand form `due 2026-04-20` only accepts ISO dates — for relative dates use the explicit keyword (`due on tomorrow`).

**Priority:** `priority [is] [above|below|not] <level>` · `has priority` · `no priority`

Levels: `lowest`, `low`, `none`, `medium`, `high`, `highest`. All of these work: `priority is high`, `priority high`, `priority is above medium`, `priority above medium`, `priority not low`, `priority is not low`.

**Text** (for `description`, `path`, `filename`, `folder`, `root`, `heading`, `recurrence`, `id`, `status.name`):
`<field> includes/does not include <text>` · `<field> regex matches/regex does not match /<pattern>[/flags]`

Regex patterns use **Lua patterns**, not JavaScript regex. For case-insensitive matching, use the `/i` flag: `description regex matches /^meeting/i`. For substring searches, `includes`/`does not include` is simpler and always case-insensitive.

**Tags:** `has tags` · `no tags` · `tag includes/does not include <text>` · `tag regex matches /<pattern>/`

**Dependencies:** `has id` · `no id` · `has depends on` · `no depends on` · `is blocking` · `is not blocking` · `is blocked` · `is not blocked`

**Other:** `is recurring` · `is not recurring` · `exclude sub-items` (keeps top-level list items and top-level callout items; drops indented children)

**Boolean:** `(f1) AND (f2)` · `(f1) OR (f2)` · `(f1) XOR (f2)` · `NOT (f1)` · `(f1) AND NOT (f2)` · `(f1) OR NOT (f2)`

Arbitrary nesting and chaining are supported: `((a) AND (b)) OR (c)`, `(a) AND (b) AND (c)`, `NOT NOT (a)`. Leaf filters must be wrapped in `()` or `""`. Binary operators are left-associative with equal precedence — parenthesise explicitly when mixing.

**Long lines:** a line ending in a single `\` continues onto the next line (the two are joined with a space). A line ending in `\\` is a literal trailing `\` (used inside regex, e.g. `/foo\\/`), not a continuation.

### Sorting

`sort by <field> [reverse]` — Available: `due`, `scheduled`, `start`, `created`, `done`, `cancelled`, `happens`, `priority`, `urgency`, `description`, `path`, `filename`, `heading`, `status`, `status.name`, `status.type`, `recurring`, `tag`, `tag <N>`, `id`, `random`

Queries without an explicit `sort by` automatically sort by status-type, urgency, due, priority, path (matching Obsidian Tasks' `Sort.defaultSorters`). User-specified sorters are applied first, then these defaults break ties.

`sort by random` is stable within a day — same query, same day, same order. The ordering changes each new day. `sort by description` strips leading Markdown (`**bold**`, `*italic*`, `==highlight==`, `[[link|alias]]`) before comparing.

### Grouping

`group by <field>` — Available: `filename`, `folder`, `root`, `path`, `backlink`, `heading`, `priority`, `status`, `status.name`, `status.type`, `recurring`, `recurrence`, `due`, `scheduled`, `start`, `created`, `done`, `cancelled`, `happens`, `tags`, `id`, `urgency`

### Layout

`short mode` · `full mode` · `hide/show <field>` · `limit <N>` · `limit groups to <N>` · `explain` · `ignore global query`

Hideable: `priority`, `recurrence rule`, `on completion`, `start date`, `scheduled date`, `due date`, `created date`, `done date`, `cancelled date`, `tags`, `id`, `depends on`, `backlink`, `path`, `task count`

`show urgency` adds ⚡score to each task.

## Rendering

When rendering is on, each `tasks` block's source is **replaced** in the buffer with the query's results as real markdown text. The rendered output is navigable (cursor lands on it like any other line), clickable (wiki-link backlinks jump to source with `gf` or obsidian.nvim), and interactive (`:TasksToggleDone` and other commands on a rendered task line operate on the source file).

### What gets rendered

Given this in your note:

```markdown
```tasks
not done
group by priority
```
```

The block is replaced with:

```markdown
*── 218 tasks ──*

#### Priority: high
- [ ] High-priority task ⏫ 📅 2026-04-25 [[source-note#heading]]
- [ ] Another ⏫ [[other-note]]

#### Priority: medium
- [ ] Medium task 🔼 [[source-note]]

*── end ──*
```

- **Group headings are level-4 (`####`)** so your existing treesitter fold-expr picks them up — each group folds under its heading automatically. No extra fold config needed.
- **Task lines are real markdown** (`- [ ] desc ⏫ 📅 date [[file#heading]]`). render-markdown.nvim styles them just like any other task in your vault, so the visual is consistent.
- **Backlinks are Obsidian wiki-links.** `gf`, obsidian.nvim's follow-link, and any other Markdown-aware navigation jumps to the source file and heading.

### Interactivity

With the cursor on a rendered task line, the normal plugin commands operate on that task's **source file**, not the rendered view:

- `:TasksToggleDone` — toggles the task in its source file, saves, re-renders.
- `:TasksCycleStatus` — cycles status in source.
- `:TasksSetPriority`, `:TasksSetDueDate`, etc. — same pattern.
- `:TasksGoto` (default: `<leader>otg`) — jumps cursor to the task's source file and exact line.
- `:TasksGotoSplit` (default: `<leader>otG`) — opens the source in a horizontal split, keeping the rendered dashboard visible in the original window.
- `:TasksUndo` (default: `<leader>otu`) — reverses the last dispatched edit. Single-slot, per-session. See the Undo section below.

The source file on disk is always written as the original ```tasks...``` source; the rendered output exists only in the buffer while rendering is on.

### Undo

`:TasksUndo` reverses the last **rendered-dispatch** edit — the one where your toggle/priority/date command wrote to a source file you weren't looking at. Neovim's native `u` can't reach those edits (it operates on the current buffer's history, not a different file's), so this fills the gap.

- **Single-slot, per-session.** Only the most recent dispatched mutation is remembered; running `:TasksUndo` twice in a row is a no-op after the first.
- **Same-buffer edits** (editing a source `.md` file directly) use Neovim's native `u` — `:TasksUndo` is only for the cross-file dispatch case.
- **Conflict detection.** If the source file has changed since the edit (another process wrote to it, you edited it manually, git pulled), `:TasksUndo` refuses rather than risk corruption. Fix the conflict, retry.
- **Handles recurrence and delete-on-completion.** Toggling a recurring task adds a new instance and marks the old one done (two lines from one); undo restores the single original line. Tasks with `🏁 delete` that get removed on completion are re-inserted on undo.

### Toggling and editing

`:TasksToggleRender` flips between rendered and raw views. To edit the query source itself, toggle rendering off, edit the fenced block, then toggle back on — your changes are reflected immediately.

Saving (`:w`) while rendered is safe: the file on disk will contain your original query source, never the rendered output. After save, the buffer re-renders automatically so you stay in the same view.

## Configuration

```lua
require("nvim-tasks").setup({
  vault_paths = {},                           -- empty = auto-detect from obsidian.nvim → cwd
  global_filter = "",                         -- only tasks containing this string
  global_query = "",                          -- prepended to all queries
  recurrence_position = "above",              -- "above" or "below" (matches obsidian-tasks)
  remove_scheduled_on_recurrence = false,     -- drop scheduled date on next occurrence
  auto_created_date = true,
  auto_done_date = true,
  render_on_load = true,
  emoji_aliases = { due = { "📆", "🗓" }, scheduled = { "⌛" } },
  statuses = {
    { symbol = " ", name = "Todo",        next = "x", type = "TODO" },
    { symbol = "x", name = "Done",        next = " ", type = "DONE" },
    { symbol = "X", name = "Done",        next = " ", type = "DONE" },
    { symbol = "/", name = "In Progress", next = "x", type = "IN_PROGRESS" },
    { symbol = "-", name = "Cancelled",   next = " ", type = "CANCELLED" },
    { symbol = "h", name = "On Hold",     next = " ", type = "ON_HOLD" },
    { symbol = "Q", name = "Non-Task",    next = "A", type = "NON_TASK" },
  },
  keymaps = {                                 -- set any to false to disable
    toggle_done       = "<C-CR>",
    toggle_render     = "<leader>otr",
    create_task       = "<leader>otc",
    set_priority      = "<leader>otp",
    set_due_date      = "<leader>otd",
    set_scheduled     = "<leader>ots",
    set_start_date    = "<leader>otS",
    cycle_status      = "<leader>otx",
    increase_priority = "<leader>ot+",
    decrease_priority = "<leader>ot-",
    search_tasks      = "<leader>otF",
    goto_source       = "<leader>otg",
    goto_source_split = "<leader>otG",
    undo_last         = "<leader>otu",
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:TasksToggleDone` | Toggle done (all line types, recurrence, on-completion) |
| `:TasksCycleStatus` | Cycle status symbols |
| `:TasksCreate` | Sequential wizard via Snacks |
| `:TasksSetPriority` | Snacks picker |
| `:TasksSetDueDate` | Snacks input with smart date parsing |
| `:TasksSetScheduled` | Snacks input |
| `:TasksSetStartDate` | Snacks input |
| `:TasksSetStatus` | Snacks picker |
| `:TasksToggleRender` | Toggle query block rendering |
| `:TasksRender` | Force render |
| `:TasksClearRender` | Clear virtual text |
| `:TasksRefresh` | Invalidate vault cache + re-render |
| `:TasksIncreasePriority` | Bump up |
| `:TasksDecreasePriority` | Bump down |
| `:TasksSearch` | Snacks picker across vault tasks |
| `:TasksGoto` | Jump to task's source file and exact line |
| `:TasksGotoSplit` | Open task's source in a horizontal split |
| `:TasksUndo` | Undo the last rendered-dispatch edit (single-slot, per-session) |
| `:TasksQuery <query>` | Ad-hoc query (`;` as line separator) |

## Architecture

```
lua/nvim-tasks/
├── init.lua        Dependency checks, commands, keymaps, autocmds
├── config.lua      Defaults, obsidian.nvim vault auto-detection, status lookups
├── task.lua        Parse/serialize (iterative end-matching, alt emojis, urgency)
├── date.lua        Date arithmetic, comparison, smart relative parsing (+3d, today)
├── recurrence.lua  Rule parsing, next-date with relative offset preservation
├── vault.lua       plenary.scandir + plenary.job (ripgrep) + plenary.path
├── filter.lua      All filters: dates, text, regex, status types, blocking/blocked
├── sort.lua        All sort fields including urgency, random, tag N
├── group.lua       All group fields including backlink, root, urgency
├── query.lua       Parser with global query merging, all_tasks context
├── render.lua      Extmark rendering, render-markdown.nvim coordination
├── toggle.lua      Toggle done for tasks/checklists/lists/plain text
└── ui.lua          Snacks picker, input, notify; sequential wizard; vault search
```

## Known Limitations

- `filter/sort/group by function` (JS expressions) — not implemented
- Placeholder expansion (`{{query.file.path}}`) — not implemented
- Presets (`preset my_preset`) — not implemented
- Date parsing uses `YYYY-MM-DD` + relatives — not full chrono-style natural language
- Recurrence covers common patterns but not full RFC 5545 rrule spec

## License

MIT
