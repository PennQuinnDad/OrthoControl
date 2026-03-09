const http = require("http");
const RoonApi = require("@roonlabs/node-roon-api");
const RoonApiTransport = require("node-roon-api-transport");
const fs = require("fs-extra");

// Load config
const config = fs.readJsonSync("./config.json");
const HTTP_PORT = Number(config.http_port) || 9330;
const VOLUME_STEP = Number(config.volume_step) || 2;
const MAX_BODY_SIZE = 1024; // 1KB limit for POST bodies
const VALID_COMMANDS = ["play_pause", "next", "prev", "volume_up", "volume_down"];

let transport = null;
let targetZoneId = null;
let targetOutputId = null;
let targetZoneName = null;
let reconnectTimer = null;
const RECONNECT_DELAY = 15000; // 15s before restarting discovery

function findTargetZone() {
  if (!transport || !transport._zones) return;
  const zone = Object.values(transport._zones).find(
    (z) => z.display_name === config.zone_name
  );
  if (zone) {
    const prevId = targetZoneId;
    targetZoneId = zone.zone_id;
    targetOutputId = zone.outputs?.[0]?.output_id || null;
    targetZoneName = zone.display_name;
    if (prevId !== targetZoneId) {
      console.log(
        `Target zone "${config.zone_name}" selected (output: ${targetOutputId})`
      );
    }
  } else {
    // Zone not available — clear stale references
    if (targetZoneId) {
      console.warn(`Zone "${config.zone_name}" is no longer available`);
    }
    targetZoneId = null;
    targetOutputId = null;
    targetZoneName = null;
  }
}

// Roon setup — v1.2.3 uses constructor callbacks, not .on() events
const roon = new RoonApi({
  extension_id: "com.ericanderson.ortho-remote",
  display_name: "Ortho Remote",
  display_version: "1.0.0",
  publisher: "Eric Anderson",
  email: "ortho-remote@github.com",

  core_found: function (core) {
    console.log("Roon Core found:", core.display_name);
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    transport = core.services.RoonApiTransport;

    transport.subscribe_zones((response, msg) => {
      if (response === "Subscribed" || response === "Changed") {
        // Always re-check — handles zone add/remove/rename
        findTargetZone();
      }
    });
  },

  core_lost: function (core) {
    console.log("Roon Core lost — will restart discovery in 15s");
    transport = null;
    targetZoneId = null;
    targetOutputId = null;
    targetZoneName = null;

    // After sleep, SOOD UDP sockets go stale. The built-in periodic_scan
    // sends queries on dead sockets that never get responses. Force a
    // full restart of discovery to create fresh sockets.
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      restartDiscovery();
    }, RECONNECT_DELAY);
  },
});

roon.init_services({ required_services: [RoonApiTransport] });
roon.start_discovery();

// Force-restart SOOD discovery with fresh UDP sockets.
// Called when core_lost fires and the built-in periodic_scan fails to reconnect.
function restartDiscovery() {
  console.log("Restarting SOOD discovery (fresh sockets)...");
  try {
    if (roon._sood) {
      roon._sood.stop();
      roon._sood = null;
      roon._sood_conns = {};
    }
  } catch (e) {
    console.warn("Error stopping SOOD:", e.message);
  }
  roon.start_discovery();
}

// Function to send Roon commands
function handleCommand(command, count) {
  if (!transport || !targetZoneId) return false;
  count = Math.max(1, Math.min(100, Math.floor(Number(count) || 1)));

  switch (command) {
    case "play_pause":
      transport.control(targetZoneId, "playpause", (err) => {
        if (err) console.warn(`play_pause failed: ${err}`);
      });
      break;
    case "next":
      transport.control(targetZoneId, "next", (err) => {
        if (err) console.warn(`next failed: ${err}`);
      });
      break;
    case "prev":
      transport.control(targetZoneId, "previous", (err) => {
        if (err) console.warn(`prev failed: ${err}`);
      });
      break;
    case "volume_up":
      if (!targetOutputId) return false;
      transport.change_volume(
        targetOutputId,
        "relative",
        count * VOLUME_STEP,
        (err) => {
          if (err) console.warn(`volume_up failed: ${err}`);
        }
      );
      break;
    case "volume_down":
      if (!targetOutputId) return false;
      transport.change_volume(
        targetOutputId,
        "relative",
        -(count * VOLUME_STEP),
        (err) => {
          if (err) console.warn(`volume_down failed: ${err}`);
        }
      );
      break;
    default:
      return false;
  }
  return true;
}

// HTTP server for OrthoControl communication
const server = http.createServer((req, res) => {
  res.setHeader("Content-Type", "application/json");

  if (req.method === "GET" && req.url === "/status") {
    const zone =
      transport && targetZoneId && transport._zones
        ? transport._zones[targetZoneId]
        : null;

    res.end(
      JSON.stringify({
        connected: !!(transport && targetZoneId),
        zone_name: targetZoneName,
        zone_id: targetZoneId,
        volume: zone?.outputs?.[0]?.volume?.value ?? null,
        state: zone?.state ?? null,
      })
    );
    return;
  }

  if (req.method === "POST" && req.url === "/command") {
    let body = "";
    let bodySize = 0;

    req.on("data", (chunk) => {
      bodySize += chunk.length;
      if (bodySize > MAX_BODY_SIZE) {
        res.statusCode = 413;
        res.end(JSON.stringify({ ok: false, error: "Request body too large" }));
        req.destroy();
        return;
      }
      body += chunk;
    });

    req.on("error", () => {
      res.statusCode = 400;
      res.end(JSON.stringify({ ok: false, error: "Request error" }));
    });

    req.on("end", () => {
      try {
        const parsed = JSON.parse(body);
        const command = String(parsed.command || "");
        const count = Number(parsed.count) || 1;

        if (!VALID_COMMANDS.includes(command)) {
          res.statusCode = 400;
          res.end(
            JSON.stringify({
              ok: false,
              error: `Invalid command. Valid: ${VALID_COMMANDS.join(", ")}`,
            })
          );
          return;
        }

        const ok = handleCommand(command, count);
        res.statusCode = ok ? 200 : 503;
        res.end(JSON.stringify({ ok, command, count }));
      } catch (e) {
        res.statusCode = 400;
        res.end(JSON.stringify({ ok: false, error: "Invalid JSON" }));
      }
    });
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: "Not found" }));
});

server.listen(HTTP_PORT, "127.0.0.1", () => {
  console.log(`HTTP server listening on http://127.0.0.1:${HTTP_PORT}`);
});

// Graceful shutdown
function shutdown() {
  console.log("Shutting down...");
  server.close();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
