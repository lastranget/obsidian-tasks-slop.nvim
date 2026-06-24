This was matched with feature parity of https://github.com/obsidian-tasks-group/obsidian-tasks at commit 4ac2e5a

## Library facade & external consumer (don't break this API)

`lua/nvim-tasks/lib.lua` is the **supported, editor-independent library API**
(`setup`/`scan`/`find_blocks`/`run`/`count`/`tasks`). It touches only the engine
modules (config, task, vault, query) — never render/toggle/ui — so it needs
plenary but not snacks, and registers no commands/keymaps/autocmds. It exists so
headless consumers don't have to poke module internals. **Treat `lib`'s function
names and shapes as a contract**: a real consumer runs unattended, so breakage is
silent.

- **Consumer:** `~/vaults/Main/scripts/sf_vm_obsidian_sync.sh` — a wrapper around
  `ob-sync-safe` that every 5 min rebuilds `~/vaults/Main/eink/display_shared.json`
  (header text from `eink/header.md`; `nosync_count` = count of the first
  ```` ```tasks ```` block in `views/work tasks moc.md`, mirrored to
  `eink/nosync_count.md`; `eink_tasks` = every task matching `(path includes
  nosync) AND (tag includes #eink)`).
- **How it calls in:** `nvim --clean -l <helper.lua> …`, prepending the plugin +
  plenary dirs to `runtimepath`, then `require("nvim-tasks.lib")`. It is
  **lib-only** (no fallback to internal modules), so the loaded install must
  carry `lib.lua` — bump it with `:Lazy update` after changing the plugin.

### The relied-on surface (keep backward compatible)

| Call | Contract the consumer needs to keep working |
|------|---------------------------------------------|
| `lib.setup{ vault_paths = { root } }` | points the scanner at a vault root without obsidian.nvim's `Obsidian` global; returns the module. |
| `lib.scan(force)` | **synchronous** full-vault task scan; callable with no UI / event-loop pumping. |
| `lib.find_blocks(source)` | `source` is a bufnr **or** a list of lines → `{ start, finish, query_lines }` **in document order** (index 1 = first ```` ```tasks ```` block). Lines path delegates to `task.find_query_blocks_in_lines`. |
| `lib.run(query, opts)` / `lib.count(query, opts)` | `query` is a string or line list; result `{ groups, total_count, error_messages, query }`. `total_count` is the rendered-banner figure (`*── N tasks ──*`). `opts.tasks` reuses a scan; `opts.file_path` sets `ctx`. |
| `lib.tasks(query, opts)` | flat, de-duplicated (by file_path+line) list of matching task objects. The consumer reads `description/raw/status_symbol/priority/due/scheduled/tags/file_path/line_number/preceding_header` and `task.is_done(t)` off these — keep those task fields stable too. |

If you must change any of the above, keep a thin shim, or update the helper Lua
embedded in that shell script in the same change.

See also `~/repos/tasks/CLAUDE.md` ("External consumers") for the workspace-level
note.
