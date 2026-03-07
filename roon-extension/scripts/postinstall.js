#!/usr/bin/env node

// Node.js 22+ ships a built-in WebSocket that lacks .on() and .ping() methods
// required by the Roon API's transport layer. This postinstall script patches
// the transport-websocket.js file to force-use the 'ws' package instead.

const fs = require("fs");
const path = require("path");

const targetFile = path.join(
  __dirname,
  "..",
  "node_modules",
  "@roonlabs",
  "node-roon-api",
  "transport-websocket.js"
);

if (!fs.existsSync(targetFile)) {
  console.log("postinstall: transport-websocket.js not found, skipping patch");
  process.exit(0);
}

const content = fs.readFileSync(targetFile, "utf8");
const patchLine = "global.WebSocket = require('ws');";

if (content.includes(patchLine)) {
  console.log("postinstall: WebSocket patch already applied");
  process.exit(0);
}

const patched = `// Patched by postinstall: Force 'ws' package for Node.js 22+ compatibility\n${patchLine}\n\n${content}`;
fs.writeFileSync(targetFile, patched);
console.log("postinstall: Patched transport-websocket.js to use 'ws' package");
