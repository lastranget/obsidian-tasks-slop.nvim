This was matched with feature parity of https://github.com/obsidian-tasks-group/obsidian-tasks at commit 4ac2e5a

## External consumer: vault Obsidian-Sync script (don't break this API)

A script **outside this repo** drives the plugin headlessly and depends on a
small set of module functions as a stable, public-ish API. Treat these as a
contract — if you rename/move them or change their shapes, update the consumer
too, or you silently break it (it runs unattended, so failures are quiet).

- **Consumer:** `~/vaults/Main/scripts/sf_vm_obsidian_sync.sh` (a wrapper around
  `ob-sync-safe` that, every 5 min, recomputes the task count of the first
  ```` ```tasks ```` block in `~/vaults/Main/views/work tasks moc.md` and writes
  the number to `~/vaults/Main/eink/nosync_count.md`).
- **How it calls in:** `nvim --clean -l <helper.lua> <vault> <queryfile> <plugin_dir> <plenary_dir>`.
  It `--clean`s (no user `init.lua`), prepends the plugin + plenary dirs to
  `runtimepath`, then `require`s the modules directly. It never calls
  `require("nvim-tasks").setup()` (avoids the snacks/init dependency), only the
  pieces below.

### The relied-on surface (keep backward compatible)

| Call | Contract the consumer needs to keep working |
|------|---------------------------------------------|
| `require("nvim-tasks.config").setup{ vault_paths = { root } }` | `vault_paths` stays the way to point the scanner at a vault root without obsidian.nvim's `Obsidian` global being present. |
| `require("nvim-tasks.task").find_query_blocks(bufnr)` | Returns a list of `{ start, finish, query_lines }` **in document order** — index `1` is the first ```` ```tasks ```` block. `query_lines` is the list of raw lines inside the fence. |
| `require("nvim-tasks.vault").scan(force)` | **Synchronous** full-vault task scan (plenary.scandir). Must stay callable with no UI / no event-loop pumping after `config.setup`. |
| `require("nvim-tasks.query").run(query_lines, tasks, ctx)` | Returns `{ groups, total_count, error_messages, query }`. `total_count` is the count shown in the rendered banner (`*── N tasks ──*`) — that number is what the consumer writes out. `ctx = { file_path = <queryfile> }`. |

If you must change any of the above, prefer keeping a thin compatibility shim, or
hunt down and update the helper Lua embedded in that shell script in the same
change. The query the script reads happens to be the *first* block, so don't
reorder/strip the count banner semantics of `total_count` either.

See also `~/repos/tasks/CLAUDE.md` ("External consumers") for the workspace-level
note.
