// Self-test for harness.mjs. Runtime-agnostic: run with any installed engine:
//   deno run js/harness.test.mjs
//   node js/harness.test.mjs
//   bun  js/harness.test.mjs
//
// Sets __HARNESS_TEST__ before importing so the harness skips its stdin main()
// and we can drive evaluate() directly.

globalThis.__HARNESS_TEST__ = true;
const { evaluate, formatDate, parseISODate } = await import("./harness.mjs");

let pass = 0, fail = 0;
function check(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; console.log("PASS " + name); }
  else { fail++; console.log(`FAIL ${name}: got ${g}, want ${w}`); }
}

function run(kind, expr, tasks, query = {}) {
  const out = evaluate({ tasks, query, instructions: [{ id: 1, kind, expr }] });
  return { result: out.results[1], error: out.errors[1] };
}

// Minimal serialized tasks (what js.lua would send).
const t = (o) => Object.assign({
  description: "", descriptionWithoutTags: "", heading: null, hasHeading: false,
  tags: [], priorityName: "Normal", priorityNumber: 3, urgency: 0,
  isDone: false, isRecurring: false, recurrenceRule: "", id: "", dependsOn: [],
  originalMarkdown: "", lineNumber: 0, listMarker: "-",
  status: { symbol: " ", name: "Todo", type: "TODO", nextSymbol: "x" },
  file: { path: "", filename: "", filenameWithoutExtension: "", folder: "/", root: "/", pathWithoutExtension: "" },
  due: null, start: null, scheduled: null, created: null, done: null, cancelled: null,
}, o);

// ---------------------------------------------------------------------------
// filter by function
// ---------------------------------------------------------------------------
{
  const tasks = [t({ tags: ["#a", "#b"] }), t({ tags: ["#a"] }), t({ tags: [] })];
  const { result } = run("filter", "task.tags.length > 1", tasks);
  check("filter: tags.length > 1", result, [true, false, false]);
}
{
  const tasks = [t({ priorityNumber: 1 }), t({ priorityNumber: 3 })];
  const { result } = run("filter", "task.priorityNumber === 1", tasks);
  check("filter: priorityNumber === 1", result, [true, false]);
}
{
  // Non-boolean return is rejected → false + instruction error.
  const tasks = [t({ description: "hi" })];
  const { result, error } = run("filter", "task.description", tasks);
  check("filter: non-boolean → false", result, [false]);
  check("filter: non-boolean → error set", typeof error === "string" && error.includes("true or false"), true);
}
{
  // String methods work natively.
  const tasks = [t({ description: "Buy milk", descriptionWithoutTags: "Buy milk" })];
  const { result } = run("filter", "task.description.includes('milk')", tasks);
  check("filter: String.includes", result, [true]);
}

// ---------------------------------------------------------------------------
// sort by function
// ---------------------------------------------------------------------------
{
  const tasks = [t({ urgency: 2 }), t({ urgency: 1 }), t({ urgency: 3 })];
  const { result } = run("sort", "task.urgency", tasks);
  check("sort: numeric keys", result, [2, 1, 3]);
}
{
  const tasks = [t({ isDone: true }), t({ isDone: false })];
  const { result } = run("sort", "task.isDone", tasks);
  check("sort: boolean → true(0) before false(1)", result, [0, 1]);
}
{
  const tasks = [t({ description: "Zebra" }), t({ description: "Apple" })];
  const { result } = run("sort", "task.description", tasks);
  check("sort: string keys", result, ["Zebra", "Apple"]);
}

// ---------------------------------------------------------------------------
// group by function
// ---------------------------------------------------------------------------
{
  const tasks = [t({ status: { type: "TODO" } }), t({ status: { type: "DONE" } })];
  const { result } = run("group", "task.status.type", tasks);
  check("group: single string → [str]", result, [["TODO"], ["DONE"]]);
}
{
  const tasks = [t({ tags: ["#a", "#b"] })];
  const { result } = run("group", "task.tags", tasks);
  check("group: array → multiple groups", result, [["#a", "#b"]]);
}
{
  const tasks = [t({})];
  const { result } = run("group", "null", tasks);
  check("group: null → [] (omitted)", result, [[]]);
}
{
  const tasks = [t({ urgency: 1.23456789 })];
  const { result } = run("group", "task.urgency", tasks);
  check("group: float → toFixed(5)", result, [["1.23457"]]);
}
{
  const tasks = [t({ isDone: true }), t({ isDone: false })];
  const { result } = run("group", "task.isDone ? 'Action Required' : 'Done'", tasks);
  check("group: ternary", result, [["Action Required"], ["Done"]]);
}

// ---------------------------------------------------------------------------
// Date layer: formatDate, TasksDate.format / category / fromNow / moment
// ---------------------------------------------------------------------------
{
  const d = parseISODate("2026-06-02");
  check("formatDate: YYYY-MM-DD", formatDate(d, "YYYY-MM-DD"), "2026-06-02");
  check("formatDate: MMMM D, YYYY", formatDate(d, "MMMM D, YYYY"), "June 2, 2026");
  check("formatDate: MMM", formatDate(d, "MMM"), "Jun");
  check("formatDate: [literal] escape", formatDate(d, "[Week] YYYY"), "Week 2026");
  // dddd validated against JS Date's own weekday (the array formatDate indexes).
  const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  check("formatDate: dddd", formatDate(d, "dddd"), weekdays[new Date(2026, 5, 2).getDay()]);
}
{
  // task.due.format in a group expression.
  const tasks = [t({ due: "2026-06-02" }), t({ due: null })];
  const { result } = run("group", "task.due.format('YYYY-MM-DD', 'no date')", tasks);
  check("group: TasksDate.format with fallback", result, [["2026-06-02"], ["no date"]]);
}
{
  // category.name is deterministic relative to run time: today → "Today".
  const today = formatDate(new Date(), "YYYY-MM-DD");
  const tasks = [t({ due: today })];
  const { result } = run("group", "task.due.category.name", tasks);
  check("group: category today", result, [["Today"]]);
}
{
  // category.groupText carries the hidden sort prefix.
  const today = formatDate(new Date(), "YYYY-MM-DD");
  const { result } = run("group", "task.due.category.groupText", [t({ due: today })]);
  check("group: category.groupText prefix", result, [["%%2%%Today"]]);
}
{
  // moment comparison: a clearly-past date is on-or-before today.
  const tasks = [t({ due: "2000-01-01" })];
  const { result } = run("filter", "task.due.moment.isSameOrBefore(moment(), 'day')", tasks);
  check("filter: TasksDate.moment.isSameOrBefore(moment())", result, [true]);
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------
{
  // Runtime throw → result false (filter) + instruction error recorded.
  const tasks = [t({})];
  const { result, error } = run("filter", "task.nope.boom === 1", tasks);
  check("filter: runtime throw → false", result, [false]);
  check("filter: runtime throw → error set", typeof error === "string" && error.length > 0, true);
}
{
  // Parse error → results null + instruction error.
  const out = evaluate({ tasks: [t({})], query: {}, instructions: [{ id: 9, kind: "filter", expr: "task.(" }] });
  check("parse error → results null", out.results[9], null);
  check("parse error → error set", typeof out.errors[9] === "string", true);
}
{
  // group runtime throw → ['Error'] heading (matches obsidian-tasks).
  const { result } = run("group", "task.nope.boom", [t({})]);
  check("group: runtime throw → ['Error']", result, [["Error"]]);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail > 0) {
  if (typeof Deno !== "undefined") Deno.exit(1);
  else process.exit(1);
}
