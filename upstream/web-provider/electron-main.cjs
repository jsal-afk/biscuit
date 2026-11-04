const { writeSync } = require("node:fs");

process.stdout.write = (() => true);
for (const method of ["clear", "count", "countReset", "debug", "dir", "dirxml", "group", "groupCollapsed", "groupEnd", "info", "log", "profile", "profileEnd", "table", "time", "timeEnd", "timeLog"]) {
  Object.defineProperty(console, method, { configurable: true, writable: true, value: () => {} });
}
for (const key of Object.keys(process.env)) {
  if (["HOME", "PATH", "TMPDIR", "LANG", "LC_ALL", "BISCUIT_CHATGPT_WEB_HOME", "BISCUIT_CHATGPT_WEB_DESCRIPTOR", "BISCUIT_CHATGPT_WEB_ELECTRON_PATH"].includes(key) !== true) delete process.env[key];
}
const fatal = () => {
  try { writeSync(1, '{"type":"fatal","category":"internal"}\n'); } catch {}
  process.exit(1);
};
process.on("uncaughtException", fatal);
process.on("unhandledRejection", fatal);
require("./electron-driver.cjs").start();
