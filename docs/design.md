# frigate-mqtt-watchdog — Design Document

**Host:** drakebay (Frigate) / ojochal (Mosquitto)
**Stack:** `frigate` (Portainer)
**Status:** deployed, stable

---

## 1. Problem

Frigate runs on drakebay; Mosquitto (the MQTT broker used for Frigate's
Home Assistant integration) runs on ojochal. Splitting these across
two hosts introduced two distinct failure modes that don't exist when
both services live in the same Compose stack.

### 1.1 Startup race

If Frigate starts before Mosquitto is reachable, Frigate's MQTT client
fails its first connection attempt and never retries. Since Frigate
and Mosquitto are on different hosts, Compose's `depends_on` can't
help — it only orders startup within a single stack/host, and offers
no cross-host readiness gate.

### 1.2 No reconnect after broker restart

If Mosquitto restarts (or the connection otherwise drops) after
Frigate has already connected, Frigate detects the disconnect but
never attempts to reconnect. Frigate continues running normally in
every other respect (video capture, detection, recording all keep
working), but MQTT publishing — and therefore all event/status
propagation to Home Assistant — silently stops until Frigate itself
is restarted.

### 1.3 Root cause

Both symptoms trace back to a single, confirmed upstream defect. Per
Frigate maintainer `hawkeye217` (GitHub Discussion
[#23390](https://github.com/blakeblackshear/frigate/discussions/23390)):

> "You may be hitting a known issue with the upstream package Frigate
> uses for MQTT, `paho`... We'll be refactoring MQTT for Frigate 0.19,
> which will work around the upstream issue."

The MQTT socket can land in a `CLOSE_WAIT` state that `paho-mqtt`
never detects or recovers from on its own. There is currently no
Frigate configuration option to force reconnection attempts — this is
a client-library limitation, not a settings gap.

Related upstream paho-mqtt issues: eclipse-paho/paho.mqtt.python
[#871](https://github.com/eclipse-paho/paho.mqtt.python/issues/871),
[#894](https://github.com/eclipse-paho/paho.mqtt.python/issues/894),
[#785](https://github.com/eclipse-paho/paho.mqtt.python/issues/785).

This is a **stopgap for both failure modes**, expected to become
unnecessary once Frigate 0.19's MQTT refactor ships.

---

## 2. Implementation

The fix has two independent parts, addressing the two failure modes
separately. They are complementary, not redundant — each covers a
scenario the other can't.

### 2.1 Startup-race fix: entrypoint wait-loop (on Frigate itself)

The Frigate container's entrypoint is overridden to block before
`exec /init` (Frigate's s6-overlay PID 1) until Mosquitto's port is
reachable:

```
until timeout 1 bash -c 'cat < /dev/null > /dev/tcp/192.168.0.9/1883' 2>/dev/null; do
  sleep 2
done
exec /init
```

This guarantees Frigate never even attempts its first MQTT connection
before the broker is reachable, sidestepping the "never retries a
failed first connection" behavior entirely. See
`src/frigate-entrypoint-snippet.yml`.

Note: this requires `bash` to be present in the Frigate image (true
for the stock image and confirmed working on the
`frigate-panther-npu:merged` custom build in use here).

### 2.2 Runtime-reconnect fix: frigate-mqtt-watchdog (sidecar container)

A small sidecar container polls for evidence of a live MQTT link and
force-restarts the Frigate container if that evidence goes stale.
This is what "frigate-mqtt-watchdog" refers to.

**Design iterations and why the current approach was chosen:**

1. **First attempt — poll the retained `frigate/available` LWT topic.**
   Rejected: Mosquitto persists retained messages to disk. If
   Mosquitto itself is restarted (not just disconnected), it reloads
   the last retained value on startup — which could be a stale
   `online` from before the outage, since nothing was running to flip
   it to `offline`. This produced false negatives (looked healthy when
   it wasn't) during broker-restart testing.

2. **Second attempt — poll for one live `frigate/stats` message per
   check cycle**, using `-R` to ignore retained values and a `timeout`
   to bound the wait. Rejected: the timeout window (`WAIT_SECONDS`)
   has to be sized correctly against Frigate's actual stats publish
   interval. If the timeout is shorter than the real interval, every
   check cycle spuriously fails even with a perfectly healthy
   connection — this caused Frigate to be restarted every couple of
   minutes during initial testing, disrupting live camera detection.

3. **Final approach — persistent background subscriber with a
   staleness timestamp.** A single long-lived `mosquitto_sub`
   subscription runs for the life of the container, updating a
   timestamp file on every message received. The main loop simply
   checks how long it's been since that timestamp last updated,
   independent of exactly when Frigate happens to publish. This
   avoids the timing-window fragility of approach #2 entirely, and
   isn't fooled by stale retained state the way approach #1 was.

**Threshold sizing:** Frigate's default `stats_interval` is 60s (not
overridden in this config). `STALE_THRESHOLD` is set to ~3x that
(200s) to absorb normal jitter — e.g. CPU/NPU load spikes delaying a
publish — without false-triggering, while still catching a genuine
outage within a few minutes.

**Why no `depends_on` on Frigate:** the watchdog must be able to
operate independently of Frigate's own container state — that's the
whole point of an external supervisor. `depends_on` only affects
startup ordering on a single `docker compose up`, not ongoing
supervision, and could stall the watchdog's own startup during the
exact startup-race scenario it needs to help recover from.

---

## 3. Build

### Files

| File | Purpose |
|---|---|
| `src/watchdog.sh` | The watchdog script itself |
| `src/docker-compose.watchdog.yml` | Compose service definition for the sidecar |
| `src/frigate-entrypoint-snippet.yml` | Complementary startup-race fix on the frigate service (for reference) |

### How it works

- Base image: `docker:cli` (Alpine-based, includes the `docker` CLI
  binary, runs as root by default — no `sudo` needed inside the
  container to reach the Docker socket).
- `mosquitto-clients` is installed at container start via `apk add`
  (not baked into a custom image — keeps this a drop-in sidecar with
  no image maintenance burden).
- The Docker socket is bind-mounted read-only so the script can issue
  `docker restart <container>` against the host's Docker daemon.
- A background `mosquitto_sub -t frigate/stats -R` subscription
  updates `/tmp/last_stats_seen` on every message.
- The main loop wakes every `CHECK_INTERVAL` seconds, compares the
  current time against that timestamp, and increments a failure
  counter if the gap exceeds `STALE_THRESHOLD`.
- On reaching `FAIL_THRESHOLD` consecutive stale checks, it runs
  `docker restart frigate` and pauses 90s before resuming checks, to
  give Frigate time to fully reconnect before being re-evaluated.
- If the background subscriber process dies for any reason, it's
  restarted automatically on the next loop iteration.

### Environment variables

| Variable | Value used | Notes |
|---|---|---|
| `MQTT_HOST` | `192.168.0.9` | ojochal |
| `MQTT_PORT` | `1883` | |
| `CHECK_INTERVAL` | `60` | seconds between staleness checks |
| `STALE_THRESHOLD` | `200` | seconds since last stats message before considered dead (~3x default 60s stats_interval) |
| `FAIL_THRESHOLD` | `1` | consecutive stale checks before restart — kept at 1 since STALE_THRESHOLD already builds in jitter margin |
| `FRIGATE_CONTAINER` | `frigate` | must match actual container name |

---

## 4. Install / Setup

1. **Create the watchdog directory on drakebay** (kept separate from
   Frigate's own config mount to avoid mixing unrelated files into
   `/opt/homeassistant/frigate/config`, which is bind-mounted directly
   into the Frigate container):

   ```bash
   sudo mkdir -p /opt/homeassistant/frigate/watchdog
   ```

2. **Copy `watchdog.sh` into place** and make it executable:

   ```bash
   sudo cp src/watchdog.sh /opt/homeassistant/frigate/watchdog/watchdog.sh
   sudo chmod +x /opt/homeassistant/frigate/watchdog/watchdog.sh
   ```

3. **Add the watchdog service** to the same Portainer stack as
   `frigate`, using `src/docker-compose.watchdog.yml` as the service
   block. Adjust `MQTT_HOST` / `FRIGATE_CONTAINER` if either changes.

4. **Confirm the Frigate entrypoint override** (`src/frigate-entrypoint-snippet.yml`)
   is already in place on the `frigate` service — this is the
   complementary startup-race fix and should exist independent of the
   watchdog.

5. **Deploy:**

   ```bash
   sudo docker compose up -d --force-recreate frigate-mqtt-watchdog
   ```

6. **Verify no false positives under normal operation** before trusting
   it — let it run for 10-15 minutes and confirm no `no stats in...`
   or restart log lines appear:

   ```bash
   docker logs frigate-mqtt-watchdog -f
   ```

7. **Test both failure modes deliberately** once idle-stable:
   - Stop the `mosquitto` container on ojochal, wait a couple of
     minutes, restart it. Confirm the watchdog logs a stale detection
     and restarts `frigate`, and that `frigate/available` flips back
     to `online` afterward.
   - (Startup race is exercised naturally any time drakebay reboots
     before ojochal is up — no separate test needed if the entrypoint
     wait-loop is in place.)

### Known limitation

Recovery time for the broker-restart case is bounded by
`STALE_THRESHOLD` + the 90s post-restart cooldown — realistically a
couple of minutes worst case. This is an external supervisor reacting
to an absence of evidence, not a real client-side reconnect, so it
will never be as fast as MQTT clients with correctly implemented
reconnect logic (e.g. Z-Wave JS, Zigbee2MQTT, ring-mqtt, Home
Assistant's own MQTT integration, all observed to reconnect cleanly on
this network). Tightening the thresholds further is possible but
trades against false-positive risk under NPU/CPU load spikes; not
pursued further since Mosquitto's actual uptime on ojochal has been
reliable and doesn't warrant the tradeoff.

### Revisit

Re-evaluate whether this watchdog is still needed once Frigate 0.19
ships its MQTT refactor (tracked via the GitHub discussion linked in
§1.3).
