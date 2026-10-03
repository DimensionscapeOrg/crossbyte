// Flat self-time ranking from an hxcpp profiler dump.
// node flat.js <profile.txt> [top=30]
// Lines "name total%/self%" start each function; indented lines under it
// are its callees. Self time is the second figure.
'use strict';
const fs = require('fs');
const [file, topArg] = process.argv.slice(2);
const top = +(topArg || 30);
const rows = [];
for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
  const m = /^(\S.*?) ([\d.]+)%\/([\d.]+)%$/.exec(line);
  if (m) rows.push({ name: m[1], total: +m[2], self: +m[3] });
}
rows.sort((a, b) => b.self - a.self);
let sum = 0;
for (const r of rows.slice(0, top)) {
  sum += r.self;
  console.log(r.self.toFixed(2).padStart(6) + '%  ' + r.total.toFixed(1).padStart(5) + '%  ' + r.name);
}
console.log('top ' + top + ' self total: ' + sum.toFixed(1) + '%');
