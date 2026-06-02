# Coverage Gaps: `obsidian-tasks-slop.nvim` vs. `obsidian-tasks`

This document catalogs query-language features that are **defined in the
authoritative `obsidian-tasks` docs** (`obsidian-tasks/docs`) but are **not
fully reproduced** by the Neovim reimplementation.

Scope: the query DSL inside ```` ```tasks ```` blocks — filtering, sorting,
grouping, layout, and the meta-features (presets, placeholders, file
defaults, custom functions). Editing UX, rendering architecture, and
recurrence-engine internals are noted only where they affect query results.

Source of truth for the implementation:
`lua/nvim-tasks/{filter,sort,group,query,date}.lua`.
Source of truth for requirements: `obsidian-tasks/docs/Queries/*` and
`obsidian-tasks/docs/Reference/*`.

Legend:

- ❌ **Missing** — instruction is unrecognized; the line produces a
  `⚠ Unknown instruction/sort/group` error (or is silently ignored).
- ◐ **Partial / divergent** — recognized, but behaves differently from the
  official plugin in ways a user can observe.
- ✅ — covered (listed only to delimit a partial area).

---

## 1. ✅ DONE: `filter / sort / group by function` (custom JS)

✅ **Implemented** (was the single largest gap). `filter by function`,
`sort by function [reverse]`, and `group by function [reverse]` are now
recognized and evaluated.

Approach (see `lua/nvim-tasks/js.lua` + `js/harness.mjs`): rather than
reimplement JavaScript semantics in Lua, expressions are evaluated by an
**external JS engine** (Deno by default — a single sandboxed binary — with Node
and Bun also supported). This mirrors the official plugin, which compiles each
expression with `new Function('task','query', ...)`.

- **Batched**: one engine invocation per query block, over all candidate tasks
  at once — no per-task process spawning.
- **Graceful degradation**: the engine is only consulted when a `... by function`
  instruction is present; if none is installed, those instructions show a clear
  error and everything else works unchanged.
- **Object model** (`task.*`, `query.file.*`, `TasksDate` with
  `.format/.category/.fromNow/.moment`, global `moment()`) is built in
  `js.lua` (serialization) + `js/harness.mjs` (wrapping), with a minimal moment
  formatter covering the documented tokens.
- **Return rules match obsidian-tasks**: filter → boolean (else error), sort →
  number/string/boolean/null, group → string/number/null(omit)/array(multi-group).

Tests: `js/harness.test.mjs` (27, engine-side logic), `test_js.lua` (52, Lua
plumbing with a stubbed engine), `test_js_engine.lua` (8, real round-trip under
Neovim).

Remaining nuance: a few advanced bits are not yet wired (`task.isBlocked()` /
`isBlocking()` methods, `query.allTasks`, full moment token set). These are
narrow next steps, not the architectural gap that this item represented.

---

## 2. Date handling

The keyword-less date-range form (`created last week`, `happens this week`,
`due 2026-01-01 2026-12-31`) was **fixed in this session** — see the changelog
entry at the bottom. Remaining date gaps:

### 2.1 ❌ Numbered date ranges
`obsidian-tasks` supports calendar-anchored ranges independent of "today":

- Week: `YYYY-Www` (e.g. `due in 2022-W14`)
- Month: `YYYY-mm` (e.g. `due 2023-10`)
- Quarter: `YYYY-Qq` (e.g. `due 2021-Q4`)
- Year: `YYYY` (e.g. `created 2023`)

`filter.lua:_date_range` only recognizes absolute `YYYY-MM-DD YYYY-MM-DD`
pairs and the relative `last|this|next week|month|quarter|year` set. Numbered
ranges fall through → `⚠ Unknown instruction`.

### 2.2 ◐ Natural-language single dates are very limited
`date.lua:parse_relative` understands only `today`, `tomorrow`, `yesterday`,
and signed offsets `±Nd|w|m|y`. The official plugin uses the `chrono` library
and accepts `next monday`, `last friday`, `14 days ago`, `in two weeks`,
`14 October`, `May`, etc. Those all fail here.

> Note: this is partly a *deliberate* design decision (see the comment in
> `_date_filter` — "relative/natural date parsing in Lua is too ambiguous to
> bind implicitly"). Listed as a gap because it is a real difference in what
> queries the user can write.

---

## 3. Filters — field-level gaps

### 3.1 ◐ Regular expressions use Lua patterns, not JS regex
`<field> regex matches /pattern/flags` is recognized for description, path,
filename, folder, root, heading, id, recurrence, status.name — but the
"pattern" is fed to Lua's `string.match`, **not** a JavaScript regex engine.
Common regex syntax (`\d`, `\w`, `\s`, `|` alternation, `{n,m}` quantifiers,
backreferences) does not work. Only the `i` flag is honored; other JS flags
(`g`, `m`, `s`, `u`) are ignored. (This is documented honestly in the source.)

### 3.2 ❌ `tags regex matches` / `tag regex matches`
Tag filtering supports only `tag(s) include(s)` and `… does not include`
(with optional `#`). The `tags regex matches /…/` form documented in
Filters.md is **not** wired up — `tags` is absent from the regex-capable
text-filter list. → `⚠ Unknown instruction`.

### 3.3 ❌ Boolean delimiters `[...]`, `{...}`
Combining Filters.md allows four delimiter styles for boolean atoms:
`(...)`, `[...]`, `{...}`, `"..."`. The tokenizer in `filter.lua`
(`tokenize_boolean` / `find_matching_paren`) only handles `(` and `"`. A query
like `[due today] OR [no due date]` is not parsed as a boolean expression.

### 3.4 ❌ `status.symbol` / `status.nextSymbol`
Only `status.type` and `status.name` filters exist. The docs note
`status.symbol`/`status.nextSymbol` are accessible (primarily via
`filter by function`), so this overlaps with §1.

### 3.5 Operator-precedence note (◐)
The boolean parser treats all binary operators (`AND`, `OR`, `XOR`,
`AND NOT`, `OR NOT`) as **equal precedence, left-associative**. The official
plugin defines precedence `NOT > XOR > AND > OR`. For unparenthesized mixed
expressions (e.g. `a OR b AND c`) results can differ. The docs recommend
explicit parentheses, which sidesteps this — but unparenthesized queries are
not faithful.

---

## 4. Sorting & Grouping

### 4.1 ✅ DONE: `group by … reverse`
Implemented. `group.parse_grouper` now strips a trailing `reverse` and
`group.apply` orders groups by per-level first-appearance, flipping any level
marked `reverse`. (As part of the same refactor, `group.apply` now also handles
**multi-group arrays** — a grouper returning a list of headings puts the task in
each group, via cartesian expansion across grouper levels — which `group by
function` relies on.)

### 4.2 ◐ Date groupers emit raw dates, not categorized headings
Official `group by due` (and scheduled/start/done/created/cancelled) produces
headings like `2023-06-12 Monday` and dedicated `Invalid date` / `No due date`
buckets. Here, `group.lua` returns the raw `YYYY-MM-DD` string (or `No due`),
so headings lack the weekday and the invalid/missing distinction differs.

### 4.3 ◐ `group by happens` bucketing differs
Implementation returns `Overdue` / `Today` / raw-date. The official grouper
formats the happens date with a weekday like the other date groupers. Output
headings will not match.

### 4.4 ❌ All custom `sort by function` / `group by function`
Covered in §1.

---

## 5. Presets

❌ **Not implemented.** Presets.md defines:

- `preset <name>` (whole-line substitution)
- `{{preset.<name>}}` (inline substitution, including inside boolean atoms)
- Built-in presets: `this_file`, `this_folder`, `this_folder_only`,
  `this_root`, `hide_date_fields`, `hide_non_date_fields`,
  `hide_query_elements`, `hide_everything`.

No preset registry, no expansion step. `preset this_file` →
`⚠ Unknown instruction`; `{{preset.x}}` is passed through verbatim and then
fails to parse.

---

## 6. Placeholders

❌ **Not implemented.** The docs use `{{query.file.path}}`,
`{{query.file.folder}}`, `{{query.file.root}}`, `{{query.file.filename}}`,
`{{query.file.pathWithoutExtension}}`, `{{query.file.filenameWithoutExtension}}`
inside instructions (e.g. `path includes {{query.file.path}}`). There is no
placeholder-expansion pass in `query.lua`, so the literal `{{…}}` text is
matched as a substring needle — almost always matching nothing.

---

## 7. Query File Defaults (`TQ_*` frontmatter)

❌ **Not implemented.** Query File Defaults.md defines ~22 YAML frontmatter
properties (`TQ_explain`, `TQ_short_mode`, `TQ_extra_instructions`, and a
`TQ_show_*` toggle per field) that inject defaults into every tasks block in a
file. `query.lua` does not read note frontmatter at all, so none of these take
effect.

> The closely-related **Global Query** *is* implemented
> (`config.global_query`, merged in `query.lua:execute`, with
> `ignore global query` honored). Query File Defaults is the per-file analog
> and is the missing half.

---

## 8. Comments

- ✅ Full-line `# comment` — supported (`parse_line` skips `^#`).
- ❌ **Inline comments** `{{! … }}` (Tasks 4.7.0+) — not stripped; the `{{!`
  text would be treated as part of an instruction.

---

## 9. Layout / display instructions

`query.lua:try_hide_show` accepts **any** `hide X` / `show X` token into a
generic `hide_fields` set, and `render.lua` honors a subset. Because the
parser is permissive, these never error — but several have **no rendering
effect**, which is a silent divergence:

| Instruction | Status | Note |
|---|---|---|
| `hide/show <date field>`, `priority`, `tags`, `recurrence rule` | ◐ | honored by render where the field is displayed |
| `short mode` / `full mode` | ✅ | parsed and honored by `render.lua` |
| `hide/show tree` | ❌ | no parent/child tree rendering exists |
| `hide/show toolbar` | ❌ | no toolbar concept in Neovim render |
| `hide/show edit button` | ❌ | no edit button |
| `hide/show postpone button` | ❌ | no postpone button |
| `hide/show backlink` | ◐ | backlinks are rendered as wiki-links; toggle not wired |
| `hide/show urgency` | ◐ | urgency not shown in render by default |
| `hide/show task count` | ◐ | count banner is always shown |

Many of these (toolbar, edit/postpone buttons, interactive tree) are
**Obsidian-UI concepts with no Neovim equivalent**, so "missing" is arguably
correct — but a user copying a query from Obsidian will see the instruction
quietly do nothing rather than be told it is unsupported.

### `explain`
◐ `explain` is parsed into `q.explain`, but there is no full explanation
renderer equivalent to Explaining Queries.md (expanded dates, regex
interpretation, boolean structure, global-query/file-defaults echo).

---

## 10. Limiting

✅ Fully covered: `limit [to] N [tasks]` and `limit groups [to] N [tasks]`
(`query.lua:try_limits`).

---

## 11. Line continuation

✅ Covered, including the `\\` literal-backslash vs. single-`\` continuation
distinction (`query.lua:join_continuations`).

---

## 12. Recurrence (engine, affects `is recurring` / `recurrence` filters only)

◐ The recurrence engine is ~80% of RFC-5545 (per README/AUDIT_NOTES). Missing:
`COUNT`, `UNTIL`, `BYSETPOS`, multi-weekday `BYDAY`, and other rrule features.
This affects *generating* the next occurrence more than *querying*; the
`is recurring` / `recurrence includes …` filters work on whatever rule text
was parsed.

---

## Summary table

| Area | Status | Severity |
|---|---|---|
| `filter/sort/group by function` (custom JS) | ✅ Done (external engine) | — |
| `group by … reverse` (+ multi-group arrays) | ✅ Done | — |
| Placeholders `{{query.file.*}}` | ❌ Missing | **High** |
| Presets (`preset`, `{{preset.*}}`) | ❌ Missing | Medium |
| Query File Defaults (`TQ_*`) | ❌ Missing | Medium |
| Numbered date ranges (`YYYY-Www`, `YYYY-mm`, `YYYY-Qq`, `YYYY`) | ❌ Missing | Medium |
| `tags regex matches` | ❌ Missing | Low |
| Boolean delimiters `[...]` / `{...}` | ❌ Missing | Low |
| Inline comments `{{! … }}` | ❌ Missing | Low |
| Regex = Lua patterns, not JS regex | ◐ Divergent | Medium |
| Natural-language single dates (`next monday`, `in two weeks`, …) | ◐ Limited | Medium |
| Boolean operator precedence (all equal) | ◐ Divergent | Low (parenthesize) |
| Date/`happens` grouper heading format | ◐ Divergent | Low |
| Layout toggles with no Neovim equivalent (tree/toolbar/buttons) | ❌/◐ | Low (N/A by platform) |
| `explain` full renderer | ◐ Partial | Low |
| Recurrence (RFC-5545 completeness) | ◐ ~80% | Low (query impact) |

---

## Changelog

**Custom functions `filter/sort/group by function`** (new modules `js.lua`,
`js/harness.mjs`). Implemented via an external JS engine (Deno recommended; Node
/ Bun supported), batched one call per query block, with graceful degradation
when no engine is installed. The `task`/`query` object model and a minimal
moment formatter are reproduced to match obsidian-tasks' documented surface and
return-value rules. Also delivered alongside: **`group by … reverse`** and
**multi-group arrays** (a grouper may place a task in several groups). Threaded a
`query.file.*` context through `query.run` from `render.lua`/`init.lua`. Tests:
`js/harness.test.mjs` (27), `test_js.lua` (52), `test_js_engine.lua` (8, real
round-trip under Neovim). All green on Node v22 / Neovim 0.11.

**Fixed: keyword-less date ranges** (`filter.lua`). Previously
`created last week`, `created this week`, `happens this week`, and bare
absolute ranges like `due 2026-01-01 2026-12-31` produced
`⚠ Unknown instruction` because the keyword-less branch of `_date_filter`
accepted only a single ISO date. The official `DateField.filterRegExp` makes
the operator optional and defaults to the inclusive `in <date range>`
behavior. `_date_filter` now interprets the post-keyword remainder as a date
range first (then a bare ISO date), via a shared `mk_range` helper reused by
both the explicit `in` branch and the keyword-less branch. 11 new tests in
`test_filter.lua` (now 67 passing).
