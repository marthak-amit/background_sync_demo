#!/usr/bin/env node
// Usage: node tools/analyze_gaps.js export.json [--from <ms>] [--to <ms>] [--ontime <sec>=75]
// export.json = Firebase console > Realtime Database > devices/<deviceId> (or .../logs) > Export JSON.
// Prints, per appState, the record count, max gapSeconds, and % of writes that arrived on time.
const fs = require("fs");
const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith("--") && !/^\d+$/.test(a));
const opt = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 ? Number(args[i + 1]) : d; };
if (!file) { console.error("usage: analyze_gaps.js export.json [--from ms] [--to ms] [--ontime sec]"); process.exit(1); }

const from = opt("from", 0), to = opt("to", Infinity), onTime = opt("ontime", 75);
let root = JSON.parse(fs.readFileSync(file, "utf8"));
const logs = root.logs ?? root.devices ?? root; // accept a few export shapes
let rows = [];
const collect = (o) => {
  for (const v of Object.values(o ?? {})) {
    if (v && typeof v === "object" && "clientTime" in v) rows.push(v);
    else if (v && typeof v === "object") collect(v);
  }
};
collect(logs);
rows = rows.filter((r) => r.clientTime >= from && r.clientTime <= to).sort((a, b) => a.clientTime - b.clientTime);
if (rows.length < 2) { console.error("not enough records"); process.exit(1); }

const stats = {};
const add = (k, gap) => {
  const s = (stats[k] ??= { n: 0, max: 0, late: 0 });
  s.n++; s.max = Math.max(s.max, gap); if (gap > onTime) s.late++;
};
for (let i = 1; i < rows.length; i++) {
  const gap = (rows[i].clientTime - rows[i - 1].clientTime) / 1000; // recomputed, not trusted
  add(rows[i].appState, gap); add("ALL", gap);
}
const spanMin = (rows.at(-1).clientTime - rows[0].clientTime) / 60000;
console.log(`records=${rows.length} span=${spanMin.toFixed(1)} min expected~${Math.round(spanMin)} ` +
  `coverage=${((rows.length / Math.max(1, Math.round(spanMin))) * 100).toFixed(1)}% on-time threshold=${onTime}s`);
console.log("appState".padEnd(18), "writes".padStart(7), "max gap(s)".padStart(11), "% on-time".padStart(10));
for (const [k, s] of Object.entries(stats).sort()) {
  console.log(k.padEnd(18), String(s.n).padStart(7), s.max.toFixed(0).padStart(11),
    (((s.n - s.late) / s.n) * 100).toFixed(1).padStart(10));
}
const missing = []; // gaps > 90s, as highlighted red in the app
for (let i = 1; i < rows.length; i++) {
  const g = (rows[i].clientTime - rows[i - 1].clientTime) / 1000;
  if (g > 90) missing.push(`${new Date(rows[i - 1].clientTime).toISOString()} -> ${new Date(rows[i].clientTime).toISOString()} (${g.toFixed(0)}s, resumed as ${rows[i].appState})`);
}
if (missing.length) console.log("\nGaps > 90s:\n  " + missing.join("\n  "));
