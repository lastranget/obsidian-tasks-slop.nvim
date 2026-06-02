// harness.mjs — evaluate Obsidian-Tasks-style `... by function` expressions.
//
// This is the JavaScript counterpart to the official plugin's
// `src/Scripting/Expression.ts`, which compiles each query expression with
// `new Function('task', 'query', 'return <expr>')` and runs it per task. We do
// the same here, but the host is a standalone JS engine (Deno by default; Node
// and Bun also work) driven by `lua/nvim-tasks/js.lua`.
//
// Protocol (all JSON, one shot per query):
//   stdin  : { tasks: [<serialized task>...], query: {...},
//             instructions: [ { id, kind: "filter"|"sort"|"group", expr } ] }
//   stdout : { results: { "<id>": [<per-task value>...] },
//             errors:  { "<id>": "<message>" } }
//
// Safety: when run under Deno with no permission flags, expressions cannot
// touch the filesystem, network, env, or spawn processes — arbitrary text
// pulled from a user's notes is contained by construction.

// ---------------------------------------------------------------------------
// Runtime-agnostic stdin reader (Deno / Bun / Node).
// ---------------------------------------------------------------------------
async function readAllStdin() {
  if (typeof Deno !== "undefined" && Deno.stdin) {
    return await new Response(Deno.stdin.readable).text();
  }
  if (typeof Bun !== "undefined" && Bun.stdin) {
    return await Bun.stdin.text();
  }
  // Node.js
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

// ---------------------------------------------------------------------------
// Minimal moment.js-compatible date layer.
//
// We implement only the format tokens and helpers that the obsidian-tasks docs
// actually use in `group by function` / `sort by function` examples. Unknown
// tokens are echoed literally, and `[...]` escapes literal text (as in moment).
// Dates are date-only (no clock); time tokens render as zero.
// ---------------------------------------------------------------------------
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"];
const MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function pad2(n) { return (n < 10 ? "0" : "") + n; }

// Parse a strict YYYY-MM-DD string into a local-midnight Date, or null.
function parseISODate(s) {
  if (typeof s !== "string") return null;
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return null;
  const d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  // Reject overflowed dates (e.g. 2026-02-31).
  if (d.getFullYear() !== Number(m[1]) || d.getMonth() !== Number(m[2]) - 1 || d.getDate() !== Number(m[3])) {
    return null;
  }
  return d;
}

// Longest-token-first replacement honoring [literal] escape sequences.
function formatDate(date, fmt) {
  if (!date) return "";
  const tokens = [
    ["YYYY", () => String(date.getFullYear())],
    ["YY", () => pad2(date.getFullYear() % 100)],
    ["MMMM", () => MONTHS[date.getMonth()]],
    ["MMM", () => MONTHS_SHORT[date.getMonth()]],
    ["MM", () => pad2(date.getMonth() + 1)],
    ["M", () => String(date.getMonth() + 1)],
    ["DD", () => pad2(date.getDate())],
    ["Do", () => ordinal(date.getDate())],
    ["D", () => String(date.getDate())],
    ["dddd", () => WEEKDAYS[date.getDay()]],
    ["ddd", () => WEEKDAYS_SHORT[date.getDay()]],
    ["HH", () => "00"], ["H", () => "0"],
    ["mm", () => "00"], ["m", () => "0"],
    ["ss", () => "00"], ["s", () => "0"],
  ];
  let out = "";
  let i = 0;
  while (i < fmt.length) {
    if (fmt[i] === "[") {
      const end = fmt.indexOf("]", i + 1);
      if (end !== -1) { out += fmt.slice(i + 1, end); i = end + 1; continue; }
    }
    let matched = false;
    for (const [tok, fn] of tokens) {
      if (fmt.startsWith(tok, i)) { out += fn(); i += tok.length; matched = true; break; }
    }
    if (!matched) { out += fmt[i]; i += 1; }
  }
  return out;
}

function ordinal(n) {
  const s = ["th", "st", "nd", "rd"], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

function startOfToday() {
  const n = new Date();
  return new Date(n.getFullYear(), n.getMonth(), n.getDate());
}

// Whole-day signed difference (a - b) in days.
function dayDiff(a, b) {
  return Math.round((a.getTime() - b.getTime()) / 86400000);
}

// A small moment()-like object covering the comparison + format methods used
// in the docs (e.g. `task.due.moment?.isSameOrBefore(moment(), 'day')`).
function makeMoment(date) {
  if (!date) return null;
  const self = {
    toDate: () => new Date(date.getTime()),
    clone: () => makeMoment(new Date(date.getTime())),
    format: (fmt) => formatDate(date, fmt || "YYYY-MM-DDTHH:mm:ss"),
    isSame: (o) => dayDiff(date, o.toDate()) === 0,
    isBefore: (o) => dayDiff(date, o.toDate()) < 0,
    isAfter: (o) => dayDiff(date, o.toDate()) > 0,
    isSameOrBefore: (o) => dayDiff(date, o.toDate()) <= 0,
    isSameOrAfter: (o) => dayDiff(date, o.toDate()) >= 0,
    toString: () => formatDate(date, "YYYY-MM-DD"),
  };
  return self;
}

// Expose moment() globally so expressions can call it like the real plugin.
globalThis.moment = (arg) => {
  if (arg === undefined || arg === null) return makeMoment(startOfToday());
  if (typeof arg === "string") return makeMoment(parseISODate(arg));
  if (arg instanceof Date) return makeMoment(arg);
  if (arg && typeof arg.toDate === "function") return makeMoment(arg.toDate());
  return makeMoment(startOfToday());
};

// PropertyCategory-like result for `.category` / `.fromNow`. `groupText` carries
// a hidden `%%sortOrder%%` prefix so grouped headings sort correctly, matching
// obsidian-tasks' convention.
function category(date) {
  let name, sortOrder;
  if (!date) { name = "Undated"; sortOrder = 4; }
  else {
    const diff = dayDiff(date, startOfToday());
    if (diff < 0) { name = "Overdue"; sortOrder = 1; }
    else if (diff === 0) { name = "Today"; sortOrder = 2; }
    else { name = "Future"; sortOrder = 3; }
  }
  return propertyCategory(name, sortOrder);
}

function fromNow(date) {
  if (!date) return propertyCategory("", 0);
  const diff = dayDiff(date, startOfToday());
  let name;
  if (diff === 0) name = "today";
  else if (diff === 1) name = "in a day";
  else if (diff > 1) name = `in ${diff} days`;
  else if (diff === -1) name = "a day ago";
  else name = `${-diff} days ago`;
  // Offset sortOrder so earlier dates sort first and it stays a positive-ish key.
  return propertyCategory(name, diff);
}

function propertyCategory(name, sortOrder) {
  return {
    name,
    sortOrder,
    get groupText() { return `%%${sortOrder}%%${name}`; },
    toString() { return name; },
  };
}

// ---------------------------------------------------------------------------
// TasksDate wrapper — what `task.due` / `task.scheduled` / ... resolve to.
// Null-safe: a missing date is still a valid TasksDate whose formatters return
// the fallback, mirroring obsidian-tasks' TasksDate.
// ---------------------------------------------------------------------------
class TasksDate {
  constructor(iso) {
    this._iso = iso || null;
    this._date = iso ? parseISODate(iso) : null;
  }
  get moment() { return this._date ? makeMoment(this._date) : null; }
  get category() { return category(this._date); }
  get fromNow() { return fromNow(this._date); }
  format(fmt, fallback = "") { return this._date ? formatDate(this._date, fmt) : fallback; }
  formatAsDate(fallback = "") { return this._date ? formatDate(this._date, "YYYY-MM-DD") : fallback; }
  formatAsDateAndTime(fallback = "") { return this._date ? formatDate(this._date, "YYYY-MM-DD HH:mm") : fallback; }
  toISOString() { return this._date ? formatDate(this._date, "YYYY-MM-DD") : ""; }
  toString() { return this.formatAsDate(""); }
}

// Earliest of a set of ISO strings (used to synthesize `task.happens`).
function earliestISO(isos) {
  let best = null;
  for (const s of isos) {
    if (!s) continue;
    if (best === null || s < best) best = s;
  }
  return best;
}

// Turn a serialized task (plain JSON from Lua) into the object an expression
// sees. Scalars/arrays (description, tags, urgency, priorityNumber, status, …)
// are pre-computed by the Lua side and used as-is — JS String/Array/Number
// methods then work natively. Only the date fields need wrapping.
function wrapTask(t) {
  const obj = Object.assign({}, t);
  obj.due = new TasksDate(t.due);
  obj.start = new TasksDate(t.start);
  obj.scheduled = new TasksDate(t.scheduled);
  obj.created = new TasksDate(t.created);
  obj.done = new TasksDate(t.done);
  obj.cancelled = new TasksDate(t.cancelled);
  obj.happens = new TasksDate(earliestISO([t.start, t.scheduled, t.due]));
  return obj;
}

// ---------------------------------------------------------------------------
// Expression compilation + per-instruction evaluation.
// ---------------------------------------------------------------------------
function compile(expr) {
  // Mirror Expression.ts: if the user already wrote `return`, use the body
  // verbatim; otherwise wrap the single expression. Parenthesize so that
  // object-literal returns and ternaries parse correctly.
  const body = /\breturn\b/.test(expr) ? expr : `return (${expr});`;
  return new Function("task", "query", body);
}

function coerceSortKey(v) {
  if (v === null || v === undefined) return null;
  if (typeof v === "number") return Number.isNaN(v) ? null : v;
  if (typeof v === "string") return v;
  if (typeof v === "boolean") return v ? 0 : 1; // true sorts before false
  if (v instanceof TasksDate) return v.toISOString() || null;
  if (v && typeof v.toDate === "function") return formatDate(v.toDate(), "YYYY-MM-DD");
  return String(v);
}

function coerceGroup(v) {
  if (Array.isArray(v)) return v.map((h) => (h === null || h === undefined ? "" : String(h)));
  if (v === null || v === undefined) return [];
  if (typeof v === "number" && !Number.isInteger(v)) return [v.toFixed(5)];
  return [String(v)];
}

function evaluate(payload) {
  const results = {};
  const errors = {};
  const tasks = payload.tasks.map(wrapTask);
  const query = payload.query || {};

  for (const ins of payload.instructions) {
    let fn;
    try {
      fn = compile(ins.expr);
    } catch (e) {
      errors[ins.id] = `Failed parsing expression "${ins.expr}": ${e && e.message ? e.message : e}`;
      results[ins.id] = null;
      continue;
    }

    const arr = new Array(tasks.length);
    let insError = null;
    for (let i = 0; i < tasks.length; i++) {
      let v;
      try {
        v = fn(tasks[i], query);
      } catch (e) {
        if (!insError) insError = `Failed evaluating expression "${ins.expr}": ${e && e.message ? e.message : e}`;
        arr[i] = ins.kind === "group" ? ["Error"] : ins.kind === "filter" ? false : null;
        continue;
      }
      if (ins.kind === "filter") {
        if (typeof v === "boolean") {
          arr[i] = v;
        } else {
          if (!insError) insError = `filtering function must return true or false. This returned "${String(v)}".`;
          arr[i] = false;
        }
      } else if (ins.kind === "sort") {
        arr[i] = coerceSortKey(v);
      } else {
        arr[i] = coerceGroup(v);
      }
    }
    if (insError) errors[ins.id] = insError;
    results[ins.id] = arr;
  }

  return { results, errors };
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------
async function main() {
  const raw = await readAllStdin();
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    process_stdout(JSON.stringify({ results: {}, errors: { _fatal: "invalid JSON payload" } }));
    return;
  }
  const out = evaluate(payload);
  process_stdout(JSON.stringify(out));
}

function process_stdout(s) {
  if (typeof Deno !== "undefined" && Deno.stdout) {
    Deno.stdout.write(new TextEncoder().encode(s));
  } else {
    // Node / Bun
    process.stdout.write(s);
  }
}

// Export the internals for the harness self-test. When imported with the
// `__HARNESS_TEST__` global set, we skip main() so the test can drive
// `evaluate()` directly without reading stdin.
export { evaluate, formatDate, TasksDate, parseISODate };

if (!globalThis.__HARNESS_TEST__) {
  main();
}
