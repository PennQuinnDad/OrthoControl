const http = require("http");
const RoonApi = require("@roonlabs/node-roon-api");
const RoonApiTransport = require("node-roon-api-transport");
const WebSocket = require("ws");
const fs = require("fs-extra");

// Load config
let config;
try {
  config = fs.readJsonSync("./config.json");
} catch (e) {
  console.error(
    e.code === "ENOENT"
      ? 'config.json not found. Copy config.example.json to config.json and set your zone name.'
      : `Failed to parse config.json: ${e.message}`
  );
  process.exit(1);
}
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

// All known zones — kept in sync via subscribe_zones
let allZones = {};

function getZoneList() {
  return Object.values(allZones).map((z) => ({
    zone_id: z.zone_id,
    display_name: z.display_name,
    state: z.state,
    outputs: (z.outputs || []).map((o) => ({
      output_id: o.output_id,
      display_name: o.display_name,
      volume: o.volume?.value ?? null,
    })),
  }));
}

function getTargetZoneStatus() {
  const zone = allZones[targetZoneId] || null;
  const nowPlaying = zone?.now_playing;
  return {
    connected: !!(transport && targetZoneId),
    zone_name: targetZoneName,
    zone_id: targetZoneId,
    volume: zone?.outputs?.[0]?.volume?.value ?? null,
    state: zone?.state ?? null,
    now_playing: nowPlaying
      ? {
          title: nowPlaying.three_line?.line1 ?? null,
          artist: nowPlaying.three_line?.line2 ?? null,
          album: nowPlaying.three_line?.line3 ?? null,
          image_key: nowPlaying.image_key ?? null,
          length: nowPlaying.length ?? null,
          seek_position: zone.seek_position ?? null,
        }
      : null,
  };
}

// Select a zone by zone_id. Returns true if the zone exists.
function selectZone(zoneId) {
  const zone = allZones[zoneId];
  if (!zone) return false;

  targetZoneId = zone.zone_id;
  targetOutputId = zone.outputs?.[0]?.output_id || null;
  targetZoneName = zone.display_name;
  console.log(`Zone switched to "${targetZoneName}" (output: ${targetOutputId})`);

  // Persist the selection
  config.zone_name = targetZoneName;
  fs.writeJson("./config.json", config, { spaces: 4 }).catch((err) => {
    console.warn(`Failed to persist zone selection: ${err.message}`);
  });

  broadcastState();
  return true;
}

function findTargetZone() {
  if (!transport) return;
  const zone = Object.values(allZones).find(
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

// --- WebSocket broadcast ---
const wsClients = new Set();

function broadcastState() {
  if (wsClients.size === 0) return;
  const message = JSON.stringify({
    event: "state",
    status: getTargetZoneStatus(),
    zones: getZoneList(),
  });
  for (const ws of wsClients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(message);
    }
  }
}

// Roon setup — v1.2.3 uses constructor callbacks, not .on() events
const roon = new RoonApi({
  extension_id: "com.ericanderson.ortho-remote",
  display_name: "Ortho Remote",
  display_version: "2.0.0",
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
      if (response === "Subscribed") {
        allZones = { ...transport._zones };
        findTargetZone();
        broadcastState();
      } else if (response === "Changed") {
        // Merge updates into our local copy
        if (msg.zones_added) {
          for (const z of msg.zones_added) allZones[z.zone_id] = z;
        }
        if (msg.zones_changed) {
          for (const z of msg.zones_changed) allZones[z.zone_id] = z;
        }
        if (msg.zones_removed) {
          for (const id of msg.zones_removed) delete allZones[id];
        }
        if (msg.zones_seek_changed) {
          for (const s of msg.zones_seek_changed) {
            if (allZones[s.zone_id]) {
              allZones[s.zone_id].seek_position = s.seek_position;
            }
          }
        }
        findTargetZone();
        broadcastState();
      }
    });
  },

  core_lost: function (core) {
    console.log("Roon Core lost — will restart discovery in 15s");
    transport = null;
    targetZoneId = null;
    targetOutputId = null;
    targetZoneName = null;
    allZones = {};

    broadcastState();

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

// Helper to read a JSON POST body
function readJsonBody(req, res, callback) {
  let body = "";
  let bodySize = 0;
  let responded = false;

  req.on("data", (chunk) => {
    if (responded) return;
    bodySize += chunk.length;
    if (bodySize > MAX_BODY_SIZE) {
      responded = true;
      res.statusCode = 413;
      res.end(JSON.stringify({ ok: false, error: "Request body too large" }));
      req.destroy();
      return;
    }
    body += chunk;
  });

  req.on("error", () => {
    if (responded) return;
    responded = true;
    res.statusCode = 400;
    res.end(JSON.stringify({ ok: false, error: "Request error" }));
  });

  req.on("end", () => {
    if (responded) return;
    responded = true;
    try {
      callback(JSON.parse(body));
    } catch (e) {
      res.statusCode = 400;
      res.end(JSON.stringify({ ok: false, error: "Invalid JSON" }));
    }
  });
}

// HTTP server for OrthoControl communication
const server = http.createServer((req, res) => {
  res.setHeader("Content-Type", "application/json");

  // GET /status — current target zone status
  if (req.method === "GET" && req.url === "/status") {
    res.end(JSON.stringify(getTargetZoneStatus()));
    return;
  }

  // GET /zones — list all available zones
  if (req.method === "GET" && req.url === "/zones") {
    res.end(
      JSON.stringify({
        zones: getZoneList(),
        selected_zone_id: targetZoneId,
      })
    );
    return;
  }

  // POST /zone — switch active zone  { "zone_id": "..." }
  if (req.method === "POST" && req.url === "/zone") {
    readJsonBody(req, res, (parsed) => {
      const zoneId = String(parsed.zone_id || "");
      if (!zoneId) {
        res.statusCode = 400;
        res.end(JSON.stringify({ ok: false, error: "zone_id is required" }));
        return;
      }
      const ok = selectZone(zoneId);
      res.statusCode = ok ? 200 : 404;
      res.end(
        JSON.stringify(
          ok
            ? { ok: true, zone_id: targetZoneId, zone_name: targetZoneName }
            : { ok: false, error: "Zone not found" }
        )
      );
    });
    return;
  }

  // POST /command — send transport/volume command
  if (req.method === "POST" && req.url === "/command") {
    readJsonBody(req, res, (parsed) => {
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
    });
    return;
  }

  res.statusCode = 404;
  res.end(JSON.stringify({ error: "Not found" }));
});

// WebSocket server — piggybacks on the HTTP server
const wss = new WebSocket.Server({ server, noServer: false });

wss.on("error", () => {
  // Handled by the HTTP server's error handler
});

wss.on("connection", (ws) => {
  wsClients.add(ws);
  console.log(`WebSocket client connected (${wsClients.size} total)`);

  // Send current state immediately on connect
  ws.send(
    JSON.stringify({
      event: "state",
      status: getTargetZoneStatus(),
      zones: getZoneList(),
    })
  );

  ws.on("close", () => {
    wsClients.delete(ws);
    console.log(`WebSocket client disconnected (${wsClients.size} total)`);
  });

  ws.on("error", () => {
    wsClients.delete(ws);
  });
});

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(`Port ${HTTP_PORT} already in use. Is another instance running?`);
  } else {
    console.error(`HTTP server error: ${err.message}`);
  }
  process.exit(1);
});

server.listen(HTTP_PORT, "127.0.0.1", () => {
  console.log(`HTTP server listening on http://127.0.0.1:${HTTP_PORT}`);
  console.log(`WebSocket available at ws://127.0.0.1:${HTTP_PORT}`);
});

// Graceful shutdown
function shutdown() {
  console.log("Shutting down...");
  if (reconnectTimer) clearTimeout(reconnectTimer);
  for (const ws of wsClients) ws.close();
  server.close(() => process.exit(0));
  // Force exit after 3s if server.close hangs
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
