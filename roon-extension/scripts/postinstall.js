#!/usr/bin/env node

// Postinstall patches for upstream bugs in @roonlabs/node-roon-api.
// These are applied automatically after `npm install`.

const fs = require("fs");
const path = require("path");

const roonApiDir = path.join(
  __dirname,
  "..",
  "node_modules",
  "@roonlabs",
  "node-roon-api"
);

// Patch 1: Force 'ws' package for Node.js 22+ compatibility
// Node.js 22+ ships a built-in WebSocket that lacks .on() and .ping() methods
// required by the Roon API's transport layer.
const wsFile = path.join(roonApiDir, "transport-websocket.js");
if (fs.existsSync(wsFile)) {
  const content = fs.readFileSync(wsFile, "utf8");
  const patchLine = "global.WebSocket = require('ws');";
  if (content.includes(patchLine)) {
    console.log("postinstall: WebSocket patch already applied");
  } else {
    const patched = `// Patched: Force 'ws' package for Node.js 22+ compatibility\n${patchLine}\n\n${content}`;
    fs.writeFileSync(wsFile, patched);
    console.log("postinstall: Patched transport-websocket.js to use 'ws' package");
  }
} else {
  console.log("postinstall: transport-websocket.js not found, skipping");
}

// Patch 2: Fix bugs in sood.js stop() method
// Bug 1: clearInterval(interface_timer) missing 'this.' — timer never cleared
// Bug 2: 'for (ip in ...)' without var/let throws ReferenceError in strict mode
const soodFile = path.join(roonApiDir, "sood.js");
if (fs.existsSync(soodFile)) {
  let content = fs.readFileSync(soodFile, "utf8");
  let patched = false;

  if (content.includes("clearInterval(interface_timer)")) {
    content = content.replace(
      "clearInterval(interface_timer)",
      "clearInterval(this.interface_timer)"
    );
    patched = true;
  }

  if (content.includes("for (ip in this._multicast)")) {
    content = content.replace(
      "for (ip in this._multicast)",
      "for (var ip in this._multicast)"
    );
    patched = true;
  }

  if (patched) {
    fs.writeFileSync(soodFile, content);
    console.log("postinstall: Patched sood.js stop() bugs");
  } else {
    console.log("postinstall: sood.js patches already applied");
  }
} else {
  console.log("postinstall: sood.js not found, skipping");
}
