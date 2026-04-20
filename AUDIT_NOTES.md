# Audit Notes

This document summarises the bugs identified and fixed during the code
audit of the pre-Opus version of nvim-tasks. Each entry identifies the
module(s) affected and the nature of the fix.

---

## Data-correctness bugs (would produce wrong results)

### [filter.lua] Boolean expression parser was almost entirely broken
The old `_boolean` helper only matched two handwritten regex shapes
(`(a) OP (b)` and `NOT (a)`). It could not handle nesting like
`((a) OR (b)) AND (c)`, chaining like `(a) AND (b) AND (c)`, or
double-negation like `NOT NOT (a)`. Any query more complex than two
operands would silently produce `nil` (no matches).

Fixed by implementing a proper tokenizer (paren/quote-depth aware) and
a recursive-descent parser with a left-associative binary op loop and
right-associative NOT prefix. 21 prototype tests cover nesting, NOT
chains, quoted atoms, and filters containing spaces or punctuation in
group bodies. 56 integration tests in `test_filter.lua` exercise the
parser against real filter predicates.

### [filter.lua] Regex `/pattern/flags` syntax was not honoured
The regex filter used `rm:match("^/(.+)/i?$")` — the `i?` becomes part
of the *pattern body*, not a flag. Case-insensitive patterns with `/i`
never worked. Additionally, `parse_filter` lowercases the whole query
line before dispatching, so any regex pattern was already destroyed by
the time the regex branch ran.

Fixed by extracting the regex value from the original-case line (`l`)
and parsing `/pattern/flags` into two parts. Only `i` is recognised
(lowercases both pattern and value). Documented the Lua-vs-JS-regex
caveat and recommend `includes` / `does not include` for substring
searching.

### [filter.lua] `starts before X` was wrong for tasks with no start date
Obsidian Tasks' `StartDateField.filterResultIfFieldMissing()` returns
`true` — a task without a start date is considered to have already
started, so it should pass `starts before`/`starts on or before X`.
nvim-tasks returned `false`, excluding those tasks.

Fixed by adding a `missing_default` option to `_date_filter`, set to
`true` only for the `starts` keyword.

### [filter.lua] `happens` only checked the first non-nil of due/scheduled/start
The implementation collapsed three dates to one via `due or scheduled
or start_date`, meaning only the first non-nil value was compared.
`HappensDateField.getFilter` in obsidian-tasks is documented as "return
true if ANY of the dates matches."

Fixed by using an `any_of` mode that iterates over all three dates
(excluding nils). Test: `happens before X` now returns true when only
`scheduled` is set, or only `start_date`, in addition to `due`.

### [filter.lua] Priority filter missed `priority is above/below X`
The regex `^priority is (.+)` greedily captured the rest of the line,
so `priority is above high` parsed as `priority == "above high"`
(always false). The separate `above`/`below` branches only matched
`priority above X` (no `is`).

Fixed by normalising the line (stripping optional `is`) and matching
`above`/`below`/`not` as explicit op words. Both `priority is above
high` and `priority above high` now work.

### [task.lua] Trailing tags were dropped from the description
`- [ ] Buy milk #urgent #shopping` parsed to `description = "Buy milk"`
with tags `{"#urgent", "#shopping"}`, losing the placement of those
tags in the description. Round-tripping produced
`- [ ] Buy milk #urgent #shopping` (correct!) by pure luck — when the
tags list happens to be in `task.tags` in the right order and
`serialize` re-appends them. But any editing of tags (including the
wizard) would destroy the order.

Fixed by tracking trailing tags separately during parsing, then
appending them back to the description before final tag extraction.
Matches `DefaultTaskSerializer.deserialize`'s `trailingTags` behaviour.

### [task.lua] Tag regex was ASCII-only
The old tag class `#[%w/_%-]+` rejected any non-English tag (e.g.
`#緊急`). Obsidian Tasks accepts any character except whitespace and
the set `! @ # $ % ^ & * ( ) , . ? " : { } | < >`.

Fixed by replacing the class with the negated set
`[^%s!@#$%%^&*(),.?":{}|<>]+`. Lua's byte-oriented matching passes
UTF-8 continuation bytes (>= 0x80) through the negated class because
every excluded byte is ASCII.

### [task.lua] URL fragments became tags
The old gmatch over the description picked up `#section` in
`https://example.com/page#section`. The obsidian-tasks regex uses
`(^|\s)#...` to require a space (or start of string) before the hash.

Fixed by prepending a space to the description and matching
`%s(#...)` in the gmatch. URL fragments no longer produce tags.

### [task.lua] VS16 quantifier was broken (NEW, discovered during testing)
The pattern `vim.pesc(VS16) .. "?"` — where VS16 is the 3-byte UTF-8
sequence `EF B8 8F` — made the `?` apply only to the *last byte*
(`8F`). The resulting pattern required the first two bytes `EF B8` to
be present. Hand-typed emojis that lack VS16 (the common case)
therefore **never matched**: priority parsing, every date field,
recurrence, ID, on-completion, and depends-on were all broken for
tasks without VS16 bytes.

Fixed by stripping VS16 from the line up front (it's a purely cosmetic
rendering hint with no semantic meaning) and simplifying every
downstream pattern to match the bare emoji. `string.char(0xEF, 0xB8,
0x8F)` is used instead of `"\xEF\xB8\x8F"` for portability across
Lua 5.1 and LuaJIT.

### [sort.lua] `sort by status.type` used alphabetical order
The old comparator returned `config.status_type(a) < config.status_type(b)`,
giving alphabetical order (CANCELLED < DONE < IN_PROGRESS < ...). The
obsidian-tasks status-type sort uses a numeric prefix:
IN_PROGRESS=1, TODO=2, ON_HOLD=3, DONE=4, CANCELLED=5, NON_TASK=6.
Users running `sort by status.type` expected in-progress work to
surface first.

Fixed with an explicit `STATUS_TYPE_ORDER` table.

### [sort.lua] `sort by random` could crash the sort (NEW, found during review)
The comparator `function() return math.random() < 0.5 end` is not a
valid sort function — it violates `table.sort`'s transitivity
requirement and Neovim's Lua can raise
`"invalid order function for sorting"` for non-trivial lists.

Fixed by making `random` a terminal sorter: if it appears anywhere in
the sorters list, perform a Fisher-Yates shuffle once and return,
ignoring other sorters.

---

## Configuration/compatibility bugs

### [config.lua] `resolve_vault_paths()` picked the wrong Obsidian global
The implementation read `Obsidian.workspace.path`, which is the
*workspace* path and may be a sub-directory of the vault. Tasks placed
elsewhere in the vault would be invisible.

Fixed by preferring `Obsidian.dir` (vault root), then
`Obsidian.workspace.root`, then `Obsidian.workspace.path` as a last
resort.

### [config.lua] Default status table diverged from obsidian-tasks
Defaults were `>` for On Hold and `~` for Non-Task (ON_HOLD cycles to
`x`; NON_TASK cycles to ` `). Obsidian Tasks' defaults are `h` for On
Hold, `Q` for Non-Task (cycles to `A`). Tasks round-tripping between
Obsidian and Neovim would have their status symbols silently mutated
if the user had accepted defaults on both sides.

Fixed by aligning with the Obsidian defaults. Users who want `>` can
override `statuses` in `setup()`.

---

## API-usage bugs

### [ui.lua + render.lua] Every `Snacks.notify` call was malformed
The code used `Snacks.notify(msg, "info", { title = ... })`. The
documented signature is `Snacks.notify(msg, opts)` where `opts.level`
carries the level. The extra positional argument silently shadowed
`opts`, so **every notification lost both its level and title**.
Warn-level notifications rendered as info; errors rendered as info.

Fixed every call site to use either `Snacks.notify(msg, { level =
"warn", title = "nvim-tasks" })` or `Snacks.notify.info/.warn/.error`
helpers. Also added a `vim.notify` fallback for when snacks isn't
installed (previously the module would crash on load).

### [ui.lua] Top-level `require("snacks")` was fragile
`ui.lua` did `local Snacks = require("snacks")` at module scope. Under
lazy-loading, if any module required `ui` before snacks had been
registered, the whole plugin failed to load.

Fixed by replacing the top-level require with a lazy `snacks()`
accessor and fallbacks to `vim.ui.input` / `vim.ui.select` /
`vim.notify` for every call site.

### [ui.lua] Wizard mixed `vim.ui.select` with Snacks inputs
The create/edit wizard used `Snacks.input` for text fields but
`vim.ui.select` for the priority step. On configurations where
`vim.ui.select` is not replaced by snacks, the priority step opened a
dropdown while other steps opened snacks floats — inconsistent UX and
different cancellation behaviour.

Fixed by routing the priority step through the same `select_with_fallback`
helper used elsewhere. Also added a "keep current priority" first entry
so editing an existing task doesn't require re-selecting priority.

### [ui.lua] Tag input parser silently mangled tags with special chars
The wizard's tag parser was `word:gsub("^#", ""):gsub("[specials]",
"")`, which would turn `#work!bad` into `#workbad` by stripping the
invalid chars mid-tag.

Fixed by matching the longest valid-tag prefix from each input word
using the same character class as the main parser. `#work!bad` now
becomes `#work` (and ignores the rest), matching expected behaviour.

### [render.lua] `check_render_markdown()` warned unconditionally
Called once at setup time, before render-markdown.nvim's own setup()
may have run. The warning always fired if render-markdown was
installed, even when the user had already added `'tasks'` to
`code.disable`.

Fixed by reading render-markdown's runtime state
(`require("render-markdown.state").config.code.disable`) and only
warning when `'tasks'` is genuinely not disabled. Moved the check to
`render_buffer()` so it runs lazily and sees render-markdown's config
regardless of load order.

### [render.lua] Query block lines were not actually concealed
The "Conceal query lines" loop used `virt_text = {{""}}, virt_text_pos
= "overlay"` — an empty overlay that hides nothing. Users saw both the
query source **and** the rendered output, resulting in visible
duplication inside every `tasks` block.

Fixed by feature-detecting the `conceal_lines` extmark property
(Neovim 0.11+, PR #31324). On 0.11+ with `conceallevel >= 2`, the
entire block is concealed and the rendered output takes its place. On
older Neovim, falls back to the original overlay-border behaviour so
the rendered output still appears — the source remains visible, which
is strictly better than nothing.

### [render.lua] Status symbol was mapped to hardcoded display strings
The format function normalised every `ON_HOLD` task to `[h]` in the
render regardless of the source symbol (`>`, `h`, `^`, ...). Users
with custom status tables saw a rendered view that didn't match their
files, making symbols appear to change.

Fixed by displaying the actual source symbol: `[` + task.status_symbol + `]`.
DONE and CANCELLED still receive the `done` highlight group; others
use the default or priority-derived highlight.

---

## Portability / robustness

### [vault.lua] Hardcoded `/` path join
`find_files_rg` used `expanded .. "/" .. line`. On Windows this
produces forward-slashes (harmless for most Neovim paths but
inconsistent) and fails if `expanded` already ends in `/` (produces
`//` which can trip path-equality checks).

Fixed with a `joinpath` helper that prefers `vim.fs.joinpath`
(Neovim 0.10+) and falls back to a manual join that detects an
existing trailing separator.

### [filter.lua] Negated blocking filters re-parsed on every task
`is not blocking`/`is not blocked` called `parse_filter("is
blocking")` inside the predicate closure — the positive filter was
re-parsed once per task evaluated. Cheap but unnecessary.

Fixed by capturing the positive filter once at parse time.

---

## Deliberately not fixed

- `query.lua` uses Lua 5.2+ `goto continue` syntax. This is valid in
  LuaJIT (what Neovim uses) but rejected by `luac 5.1 -p`. Not changed
  because the plugin targets Neovim specifically.
- `scan_async` exists but is not wired into the default render
  pipeline. Kept for callers that need it; documented in the source
  comment on `vault.scan_async`.
- Recurrence end-of-month edge cases (e.g. "monthly starting Jan 31
  repeated in Feb"): `math.min(day, days_in_month)` approximates
  obsidian-tasks' day-step-back behaviour.
- `filter/sort/group by function`, placeholder expansion
  (`{{query.file.path}}`), and presets are documented as not
  implemented.

---

## Test coverage

114 tests added across three test files covering the highest-risk
modules:

- `test_filter.lua` — 56 tests: priority in every form, dates
  with starts-missing-default and happens-any-of, regex
  case-sensitive and `/i`, text filters, tags with/without `#`,
  booleans (nesting, chaining, double-NOT, AND NOT, OR NOT, XOR),
  status, blocking.
- `test_task.lua` — 24 tests: basic parse, trailing tags, mixed
  tags/dates, Unicode, URL rejection, done symbols, round-trips.
- `test_task2.lua` — 34 tests: every field in isolation (priority,
  6 dates incl. aliases, recurrence, ID, on-completion, depends-on,
  block-link), VS16 with/without, indented sub-items, numbered
  lists, Unicode descriptions, round-trips across full field
  combinations.

Tests use a mock `vim` global sufficient to satisfy `task.lua` and
`filter.lua` imports (neither requires plenary). To run:

    cd nvim-tasks/
    lua test_filter.lua
    lua test_task.lua
    lua test_task2.lua

---

## Deep-parity audit (Sessions 2–5)

After the initial bug-fix pass, a second audit did source-level line-by-line
comparison against obsidian-tasks, obsidian.nvim, and render-markdown.nvim.
This section catalogues every semantic gap found and the fix applied.

### [task.lua] Blockquote / Obsidian-callout indentation
Obsidian Tasks' `TaskRegularExpressions.indentationRegex = /^([\s\t>]*)/`
allows `>` in the indent prefix, which is how Obsidian callouts nest:

    > [!note]
    > - [ ] Task inside a callout

The old parser used `^(%s*)` and rejected the line outright. Fixed by
switching the indent class to `[%s>]*`. Subitem detection
(`exclude sub-items`) was updated in lockstep (see below).

### [task.lua] Numbered-list terminator quantifier bug
`%d+[.)]+` allowed `1..`, `1.)`, and `1)))` to parse as list markers.
Obsidian Tasks uses `[0-9]+[.)]` (no `+`), accepting only `1.` or `1)`.
Fixed.

### [task.lua] Multi-byte Unicode status symbols
`%[(.)%]` captured a single *byte*, so a 3-byte codepoint like `▸` would
be truncated and the remaining bytes leaked into the description. Fixed
by introducing a UTF-8 codepoint class (`[%z\1-\127\194-\244][\128-\191]*`)
matching obsidian-tasks' `/\[(.)\]/u`. ASCII, 2-byte (e.g. `¡`), 3-byte
(e.g. `▸`), and 4-byte (e.g. `🔥`) status symbols all round-trip correctly.

### [filter.lua] Keyword-less date form ("due 2026-04-20")
Obsidian's `DateField.filterRegExp` allows the keyword group to be empty,
so `due 2026-04-20` is equivalent to `due on 2026-04-20`. Mine required
an explicit keyword. Added a trailing match for a bare ISO date.

### [filter.lua] "in or before" / "in or after" date aliases
Obsidian treats these as synonyms for "on or before" / "on or after".
Added both aliases to `_date_filter`.

### [filter.lua] `exclude sub-items` missed blockquote top-level tasks
The old implementation was `return not t.indent or t.indent == ""`, which
worked for plain-indent sub-items but rejected tasks that are the *top-level*
item inside a callout/blockquote (indent `">"` or `"> "`). Replicated
obsidian-tasks' `ExcludeSubItemsField` logic exactly: find the last `>` in
the indent; pass if the remainder is empty or a single space.

### [filter.lua] / [group.lua] `root` field was not vault-relative
`task.file.root` in obsidian-tasks is the first segment of the vault-relative
path, but my implementation took the first segment of the absolute path —
which is `""` (the empty string before the leading `/`) for any absolute
path, making the filter useless. Both the filter and the grouper now strip
any configured `vault_paths` prefix before taking `split(rel, "/")[1]`.

### [group.lua] `backlink` grouper used display-only format
Obsidian Tasks emits grouper headings as full Markdown links:
`[[file#header|file > header]]` (with header) or `[[file]]` (without),
or `"Unknown Location"` when the task has no file path. The old impl
returned a plain `"file > header"` string, which renders as plain text in
Obsidian and loses click-to-navigate.

### [sort.lua] `sort by random` reshuffled every run
Obsidian Tasks uses a stable-per-day TinySimpleHash of
`currentDate + ' ' + description` so repeated queries on the same day
produce the same ordering (reviewers can still see something "random-looking"
without having tasks jump around as they scroll). My old Fisher-Yates
shuffle was freshly seeded each call. Fixed with a deterministic
FNV-style 31-bit hash.

### [sort.lua] No default sorters were applied
Obsidian Tasks' `Sort.defaultSorters()` appends
`[StatusType, Urgency, Due, Priority, Path]` after any user-supplied
sorters, so queries without an explicit `sort by` still produce a sensible
order (active-before-completed, urgent-first). My old impl returned
unsorted input. Fixed by composing user sorters with the same default
five.

### [sort.lua] `sort by description` did not strip leading Markdown
`DescriptionField.cleanDescription` strips leading `**bold**`, `*italic*`,
`==highlight==`, `__bold__`, `_italic_`, and resolves leading `[[link|alias]]`
(returning `alias`) before comparison. My old impl did a plain
`:lower()` comparison, so `**Alpha**` sorted after `Zebra`. Fixed with
`_clean_description` mirroring obsidian-tasks.

### [query.lua] `\\` line-continuation escape
Obsidian's `Scanner.ts` treats a single trailing `\` as "continue next
line" and `\\` as "literal trailing `\`, do not continue". The old impl
collapsed both into a continuation. Fixed by checking `\\%s*$` before
the single-`\` case.

### [config.lua] ON_HOLD default `next` symbol
Obsidian Tasks' `Status.ON_HOLD` default goes back to Todo when toggled
(`next = " "`). Mine was `next = "x"` (direct to Done), skipping the
user's On-Hold → Todo → Done cycle. Fixed.

### [config.lua] `resolve_vault_paths` — three-level Obsidian.nvim fallback
Verified the preference order `Obsidian.dir > Obsidian.workspace.root >
Obsidian.workspace.path > cwd` against obsidian.nvim's `workspace.lua:136`
(which sets `Obsidian.dir = workspace.root` during `Workspace.set`). Added
integration tests (`smoke_integration.lua`) exercising all five branches
plus a synthesised fake `obsidian.Path` metatable.

### [render.lua] render-markdown.nvim coordination
Verified against render-markdown.nvim's real `state.config.code.disable`
schema (which is `string[]`, though the code.lua annotation says
`boolean | string[]` — my code handles both). Added integration tests
exercising:
- render-markdown not installed → no-op
- `code.disable` contains `"tasks"` → no warning
- `code.disable` empty → one-time warning via `Snacks.notify` or
  `vim.notify`
- Repeated calls after warn → dedupe, no re-warn

### [recurrence.lua] Readability pass
The old implementation was functional but dense (24 lines of semicolon-
separated statements for `parse_rule`). Rewritten with one branch per
logical form, a shared `normalise_unit` helper, docblocks, and 25 new
targeted unit tests (`test_recurrence.lua`) covering every supported
shape: daily/weekly/monthly/yearly intervals, named weekdays, named
months with day-of-month, `when done`, `every weekday`.

Behavior is unchanged; this is a pure refactor.

### Test coverage summary after audit

| Suite                            | Tests |
|----------------------------------|-------|
| test_filter.lua  (Lua 5.1)       | 56    |
| test_task.lua    (Lua 5.1)       | 24    |
| test_task2.lua   (Lua 5.1)       | 34    |
| test_sort.lua    (Lua 5.1)       |  9    |
| test_recurrence.lua (Lua 5.1)    | 25    |
| smoke.lua        (real Neovim)   | 40    |
| smoke2.lua       (real Neovim)   | 42    |
| smoke_integration.lua (real Nvim)| 13    |
| **Total**                        | **243** |

All suites are green on LuaJIT 2.1 / Neovim 0.9.5. The Neovim smoke
tests use a hand-written plenary.nvim stub (path/scandir/job) located
at `../nvim-test/plenary-stub/`.

### Not yet addressed (deliberate)

- **Full RFC-5545 recurrence.** Obsidian wraps the `rrule` JS library
  for full RFC-5545 support (COUNT, UNTIL, BYSETPOS, multi-weekday BYDAY,
  etc.). Porting rrule to Lua is a substantial project; the README calls
  out the 80% coverage limit explicitly.
- **`filename includes .md` matches everything.** Obsidian Tasks has
  the same quirk (file extension is part of the value). Faithful.
- **`sort by urgency` ties.** Obsidian's default sorters include Urgency
  as the 2nd tiebreaker; we do too now. But note: if two tasks have
  identical urgency, due, priority, and path, the order depends on the
  input order (stable-ish). Same as obsidian-tasks.

---

## Sessions 7–8: workflow tests, bugs, performance

### [query.lua] `goto` / `continue` pattern refactored away
The old dispatch loop used `goto continue` labels to early-exit per-iteration.
This works on LuaJIT (Neovim's Lua) and Lua 5.2+ but fails `luac5.1 -p`.
Refactored into per-handler `try_X(q, line, l)` functions returning `true`
iff they consumed the line, so each branch can simply `return` out of the
per-iteration handler. Behavior unchanged; **every module in the plugin now
passes `luac5.1 -p`**, so the whole codebase is Lua 5.1 compatible.

### [config.lua] `recurrence_position` default was `"below"` — obsidian-tasks is `"above"`
Surfaced by the workflow test. Obsidian Tasks' `Task.handleNewStatusWithRecurrenceInUsersOrder`
returns `[nextTask, toggledTask]` — the newly-created recurrence instance appears
**above** the completed one by default. Users can reverse with the
`recurrenceOnNextLine` setting. My default was `"below"`, the opposite.
Fixed — new default is `"above"`. **This is a visible behavior change for
anyone upgrading from a pre-audit build.**

### [task.lua] Parse of `"Desc ✅ 2026-04-18 #tag1 #tag2"` produced double-spaced description
Surfaced by the round-trip stability test. Each iterative field-removal gsub leaves a
single trailing space; the trailing-tag restoration block blindly prepended
`" "` when re-appending tags to the description. Result: `"Desc  #tag1 #tag2"`
(double space). Fixed by stripping trailing whitespace off `remaining` before
the tag re-append. This matches obsidian-tasks' `DefaultTaskSerializer.deserialize`
which calls `.trim()` on every field removal.

Round-trip stability: serialize(parse(line)) == line for all tested shapes,
including callouts, numbered markers, done dates with tags, Unicode.

### [sort.lua] Schwartzian transform — 20x speedup on large corpora
Benchmark synthesised a 1000/5000-task corpus and measured query time.

Before:
- 1000 tasks, `sort by urgency`: 1840 ms
- 5000 tasks, `group by priority + sort by due`: 14290 ms

Each comparator closure recomputed urgency (parse date, math.floor, priority
multiplier) every call. `table.sort` does ~N log N comparisons × 2 calls per
comparison with multiple sorters = ~60,000 urgency calls per 1000-task sort.

Fix: Schwartzian transform. Before `table.sort`, build a decorated array
`{ task, key1, key2, … }` computing each sorter's key once per task. The
comparator then compares cheap precomputed values.

After:
- 1000 tasks, `sort by urgency`: 90 ms (~20x faster)
- 5000 tasks, `group by priority + sort by due`: 800 ms (~18x faster)

**Interface change:** `parse_sorter()` now returns `{ key, reverse }` table
rather than a bare comparator function. `sort.apply()` accepts both the new
table form and legacy callable comparators (applied as final tiebreakers).
This preserves backward compatibility with any external code that might have
imported `parse_sorter` directly.

### New test suites (sessions 7–8)

| Suite                      | Tests | Purpose                                          |
|----------------------------|-------|--------------------------------------------------|
| `smoke_workflow.lua`       | 84    | End-to-end toggle/recurrence/multi-block render  |
| `bench.lua`                | —     | Perf bench at 100/1000/5000 tasks (info only)    |
| `profile.lua`              | —     | Per-phase timing to identify hot code            |

### Test coverage at end of sessions 7–8

| Suite                            | Tests |
|----------------------------------|-------|
| test_filter.lua     (Lua 5.1)    | 56    |
| test_task.lua       (Lua 5.1)    | 24    |
| test_task2.lua      (Lua 5.1)    | 34    |
| test_sort.lua       (Lua 5.1)    |  9    |
| test_recurrence.lua (Lua 5.1)    | 25    |
| smoke.lua           (real Nvim)  | 40    |
| smoke2.lua          (real Nvim)  | 42    |
| smoke_integration.lua (real Nvim)| 13    |
| smoke_workflow.lua  (real Nvim)  | 84    |
| **Total**                        | **327** |

---

## Session 10: render bugs surfaced in real use

Two bugs surfaced when the plugin was installed on Tom's system and opened on
a real note with `tasks` blocks. Both were tightly coupled to how the plugin
is lazy-loaded and how Neovim's `conceal_lines` extmark feature interacts
with cursor movement.

### [init.lua] Lazy-load autocmd race — blocks didn't render on open

The old autocmd listened for `BufRead`/`BufEnter` on `*.md`. But with lazy.nvim
using `ft = "markdown"`, the plugin loads *after* `BufRead` has already fired
for the buffer that triggered the load. The autocmd got registered, but never
triggered for that buffer.

Reproduction: 0 extmarks placed on first open (instead of the expected 6+).

Fix: added `FileType` to the autocmd triggers AND a one-shot sweep in
`_setup_autocmds()` that walks `vim.api.nvim_list_bufs()` and renders any
already-loaded `*.md` buffer. This handles the load-after-open case cleanly.

### [render.lua] conceal_lines + cursor → rendered output disappears on navigate

On Neovim 0.11+ the old code used the `conceal_lines = ""` extmark to hide
the query block and placed a `virt_lines_above` extmark to show the rendered
output above it. This works visually — until the cursor enters the block.

Neovim's default behavior: when the cursor is on a concealed line,
`concealcursor` determines whether to reveal that specific line for editing.
The default `concealcursor` is empty → every mode reveals. So as soon as the
user navigates into the block, the concealed lines become visible one at a
time, causing the clean rendered overlay to flicker / tear. There's a
secondary problem too: virt_lines attached to a concealed line have known
interaction bugs on 0.11.x (Neovim issues #32744 and #33033).

Fix: changed the default render strategy from "conceal" to **"inline"** —
keep the source visible, place virt_lines below the closing fence. Works
identically on every Neovim version, cursor navigation is natural, users
can edit the query source in place.

The conceal strategy is still available as an opt-in via
`render_strategy = "conceal"` for users who understand the tradeoffs and
are on Nvim 0.11+ with `conceallevel >= 2`.

Also fixed a small positional bug: the previous inline fallback attached
virt_lines to `block.start` (the opening fence) instead of `block.finish`
(the closing fence). The rendered output now appears immediately below the
closing fence, which is where a reader's eye naturally expects results.

### New test coverage

| Suite                       | Tests | Purpose                                      |
|-----------------------------|-------|----------------------------------------------|
| `smoke_render.lua`          | 7     | Render-strategy defaults + lazy-load sweep   |

### Test coverage at end of session 10

| Suite                             | Tests |
|-----------------------------------|-------|
| test_filter.lua      (Lua 5.1)    | 56    |
| test_task.lua        (Lua 5.1)    | 24    |
| test_task2.lua       (Lua 5.1)    | 34    |
| test_sort.lua        (Lua 5.1)    |  9    |
| test_recurrence.lua  (Lua 5.1)    | 25    |
| smoke.lua            (real Nvim)  | 40    |
| smoke2.lua           (real Nvim)  | 42    |
| smoke_integration.lua (real Nvim) | 13    |
| smoke_workflow.lua   (real Nvim)  | 84    |
| smoke_render.lua     (real Nvim)  |  7    |
| **Total**                         | **334** |

---

## Sessions 11–12: buffer-replacement rendering architecture

A substantial architectural change, prompted by two user requirements that
surfaced in real use:

1. **Rendered output must be navigable** — cursor j/k across rendered tasks,
   not skip over them.
2. **Rendered output must be interactive** — `:TasksToggleDone` on a
   rendered task line should toggle that task, re-rendering to reflect.
3. **Visual must match render-markdown.nvim** — rendered tasks should look
   the same as any other task in the markdown buffer.

All three requirements demand the same architecture: render output as real
buffer lines, not virtual text.

### [render.lua] Complete rewrite — buffer-replacement

Each ```tasks``` block's source lines are REPLACED in the buffer with
real markdown text. render-markdown.nvim styles them consistently with
other tasks in the buffer.

Output format:

    *── 3 tasks ──*                             (italic count banner)

    #### Priority: high                         (level-4 heading = foldable)
    - [ ] Task desc ⏫ 📅 2026-04-20 [[src#H]]  (real task line + wiki-link)

    #### Priority: medium
    - [ ] Another 🔼 [[src]]

    *── end ──*

`####` group headings integrate with the user's existing treesitter
`foldexpr` — each group folds naturally without extra config.

Wiki-links `[[file#heading]]` are real text — `gf` and obsidian.nvim's
follow-link both jump to source.

State: module-level `M._state[bufnr]` table (not buffer variables —
msgpack serialization rejects sparse tables, and `task_origins` is sparse
since most output lines aren't tasks). BufWipeout autocmd cleans up.

Each rendered task line records its origin via an indexed entry in the
block's `task_origins` table: `task_origins[offset_within_block] =
{ file_path, line_number }`. Used by `origin_at_line(buf, lnum)` to
dispatch edits to the source file.

Block positions tracked via anchor extmarks (not raw line numbers) so
edits elsewhere in the buffer don't lose track of them.

### [render.lua] Save protection

`BufWritePre` (clear-to-source) + `BufWritePost` (re-render) autocmds
live inside render.lua itself as self-registering on module load — not
in `_setup_autocmds`. This matters because a caller loading render.lua
outside the plugin's setup() still gets save protection. Bug surfaced
in `smoke_buffer_render.lua` when the first run of the save-protection
test failed: the autocmds weren't wired up in isolated test mode.

Transient flag `M._was_rendered_for_save[bufnr]` bridges the Pre/Post
pair since `clear_buffer` removes the buffer from `M._state` between
them.

After save, every OTHER open rendered buffer is also refreshed — a
task change in `foo.md` might appear in a dashboard note rendered in
another buffer.

### [toggle.lua] Rendered-view dispatch

Every mutation command (`toggle_done`, `cycle_status`, `set_priority`,
`increase_priority`, `decrease_priority`, `set_date`) now checks for
rendered-buffer dispatch at the top:

  1. `resolve(bufnr, lnum)` calls `render.origin_at_line` to check
     whether the current line is a rendered task.
  2. If yes: load the origin file (via `bufadd` + `bufload`, invisible),
     resolve to source buffer/line, apply the mutation there.
  3. `commit_source_edit(src_buf)` writes the source file with `silent
     noautocmd write` (so we don't re-enter the Pre/Post chain), then
     invalidates the vault cache and calls `render.refresh_all()`.

Command-specific wrappers share a `mutate_priority` helper that takes
a pure function from task → nil, keeping each command's logic minimal.

### [config.lua] Removed obsolete `render_strategy` key

The "inline" vs "conceal" strategy distinction is gone — buffer-
replacement is the one path. Removed the config key entirely rather
than silently ignoring it, since the strategies it selected between no
longer exist.

### New test coverage

| Suite                       | Tests | Purpose                                          |
|-----------------------------|-------|--------------------------------------------------|
| `smoke_buffer_render.lua`   | 35    | Buffer-replacement rendering + toggle-dispatch   |

Covers: rendered layout (`####` headings, real `- [ ]` task lines, wiki-
link backlinks, italic count banner, NO virt_lines extmarks); clear
restores exact original source; toggle off → edit source → toggle on
reflects edits; `origin_at_line` returns `{file_path, line_number}` for
task lines and nil for non-task lines (headings, banners, blanks);
`toggle_done` on rendered task edits source file byte-for-byte (verified
by re-reading the file from disk); toggled task no longer appears as
`[ ]` in the re-rendered view (cross-buffer refresh); `:w` writes
original ```tasks``` source to disk, NOT rendered output.

### [smoke_render.lua] Retired

The session-10 smoke_render.lua tested "inline" strategy virt_lines
placement and "conceal" strategy conceal_lines placement. Neither
applies in the new architecture. Its scenarios are subsumed by
smoke_buffer_render.lua, so the file was deleted rather than rewritten.

### Test coverage at end of session 12

| Suite                             | Tests |
|-----------------------------------|-------|
| test_filter.lua      (Lua 5.1)    |  56   |
| test_task.lua        (Lua 5.1)    |  24   |
| test_task2.lua       (Lua 5.1)    |  34   |
| test_sort.lua        (Lua 5.1)    |   9   |
| test_recurrence.lua  (Lua 5.1)    |  25   |
| smoke.lua            (real Nvim)  |  40   |
| smoke2.lua           (real Nvim)  |  42   |
| smoke_integration.lua (real Nvim) |  13   |
| smoke_workflow.lua   (real Nvim)  |  84   |
| smoke_buffer_render.lua (real Nvim)| 35   |
| **Total**                         | **362** |

### Visible behavior differences from earlier versions

For anyone upgrading from the session-10 zip:

- **Rendered output is now real buffer text, not virt_lines.** Buffer line
  count changes when rendered vs. not rendered.
- **Source is HIDDEN when rendered.** Previously the ```tasks``` block stayed
  visible with virt_lines below it. Now it's replaced entirely.
- **Plugin commands on rendered tasks edit the source file.** Previously
  they'd either error (no-op because the rendered line wasn't a real task
  line) or operate on the rendered buffer directly (which was meaningless).
- **`render_strategy` config key is gone.** Buffer-replacement is the only
  strategy.
- **Saving a rendered buffer writes the original source to disk.** The file
  on disk never contains rendered output.

---

## Sessions 13-14: navigation commands + keymap prefix rebase

### [render.lua] `TasksGoto` and `TasksGotoSplit`

Two new navigation commands that leverage the existing `origin_at_line`
extmark lookup:

- `render.goto_source()` — reads the origin at the cursor, opens the source
  file via `:edit`, positions the cursor at exact `line_number`, centers
  with `zz`. Replaces the current window's buffer.
- `render.goto_source_split()` — same, but `belowright split` keeps the
  rendered dashboard visible in the original window.

Both clamp `line_number` to the target buffer's actual line count (in case
the source file changed since the render), and emit a clear notification
via Snacks.notify / vim.notify when the cursor isn't on a rendered task
line, rather than silently doing nothing.

Rationale: `gf` on a `[[wiki-link]]` already takes the user to the source
file (and with obsidian.nvim, to the heading), but neither takes them to
the exact task line. The origin is already tracked; exposing it as a
command is a ~40-line addition that makes the navigation story feel
complete.

Shared `notify` helper moved up to module scope; deduplicated the inline
one previously inside `M.toggle`.

### [config.lua / init.lua / docs] Keymap prefix rebase `<leader>t` → `<leader>ot`

User preference: all default keymaps now use `<leader>ot` prefix instead
of `<leader>t`. Rationale: `<leader>t` is a common prefix for testing,
terminal, or tab commands in many users' existing setups; `<leader>ot`
("obsidian tasks") is more specific and less likely to collide.

Affects every default binding:

    toggle_done          <C-CR>       (unchanged — not prefixed)
    toggle_render        <leader>tr   → <leader>otr
    create_task          <leader>tc   → <leader>otc
    set_priority         <leader>tp   → <leader>otp
    set_due_date         <leader>td   → <leader>otd
    set_scheduled        <leader>ts   → <leader>ots
    set_start_date       <leader>tS   → <leader>otS
    cycle_status         <leader>tx   → <leader>otx
    increase_priority    <leader>t+   → <leader>ot+
    decrease_priority    <leader>t-   → <leader>ot-
    search_tasks         <leader>tF   → <leader>otF
    goto_source          <leader>tg   → <leader>otg
    goto_source_split    <leader>tG   → <leader>otG

README and helpfile updated in all three places they documented keymaps
(quickstart section, Configuration keymap block, and Commands table).

### New test coverage

| Suite                       | Tests | Purpose                                          |
|-----------------------------|-------|--------------------------------------------------|
| `smoke_goto.lua`            | 14    | goto_source and goto_source_split semantics      |

Covers: cursor lands on exact file + line; split creates one new window,
original stays; goto on banner/heading line is a no-op with notification;
goto in non-rendered buffer is a no-op with notification; line clamping
when source file shrunk after render.

### Test coverage at end of session 14

| Suite                              | Tests |
|------------------------------------|-------|
| test_filter.lua      (Lua 5.1)     |  56   |
| test_task.lua        (Lua 5.1)     |  24   |
| test_task2.lua       (Lua 5.1)     |  34   |
| test_sort.lua        (Lua 5.1)     |   9   |
| test_recurrence.lua  (Lua 5.1)     |  25   |
| smoke.lua            (real Nvim)   |  40   |
| smoke2.lua           (real Nvim)   |  42   |
| smoke_integration.lua (real Nvim)  |  13   |
| smoke_workflow.lua   (real Nvim)   |  84   |
| smoke_buffer_render.lua (real Nvim)|  35   |
| smoke_goto.lua       (real Nvim)   |  14   |
| **Total**                          | **376** |
