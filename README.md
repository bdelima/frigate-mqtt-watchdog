# frigate-mqtt-watchdog

Sidecar container that watches for a live MQTT connection between
[Frigate](https://frigate.video/) and its broker, and force-restarts
the Frigate container if that connection has silently gone dead.

## Why

Frigate's `paho-mqtt` client has a confirmed upstream bug
([Discussion #23390](https://github.com/blakeblackshear/frigate/discussions/23390))
where it never reconnects after the broker restarts or a connection
otherwise drops, and never retries a failed first connection either.
This bites hardest when Frigate and the MQTT broker run on separate
hosts. This watchdog is a stopgap until Frigate 0.19's MQTT refactor
fixes it upstream.

Full design rationale, rejected approaches, and threshold tuning
notes: [`docs/design.md`](docs/design.md).

## Image

Published to Docker Hub as
[`bdelima/frigate-mqtt-watchdog`](https://hub.docker.com/r/bdelima/frigate-mqtt-watchdog),
built for `linux/amd64` and `linux/arm64`.

## Usage

See [`docker-compose.watchdog.yml`](docker-compose.watchdog.yml) for a
ready-to-use Compose service block. Docker socket access (read-only)
is required so the watchdog can issue `docker restart` against the
Frigate container.

### Environment variables

| Variable | Default | Required | Notes |
|---|---|---|---|
| `MQTT_HOST` | — | yes | MQTT broker hostname/IP |
| `MQTT_PORT` | `1883` | no | |
| `CHECK_INTERVAL` | `60` | no | seconds between staleness checks |
| `STALE_THRESHOLD` | `200` | no | seconds since last `frigate/stats` message before the connection is considered dead (~3x Frigate's default 60s `stats_interval`) |
| `FAIL_THRESHOLD` | `1` | no | consecutive stale checks before restarting Frigate |
| `FRIGATE_CONTAINER` | `frigate` | no | must match the actual Frigate container name |

`MQTT_HOST` has no default — the script runs with `set -u` and will
fail loudly on startup if it's unset, rather than silently watching
the wrong broker.

### Complementary fix: startup race

This watchdog handles the runtime-reconnect failure mode. The
startup-race failure mode (Frigate starting before the broker is
reachable) is handled separately, by an entrypoint override on the
Frigate service itself — see
[`docs/frigate-entrypoint-snippet.yml`](docs/frigate-entrypoint-snippet.yml).
Both fixes are needed; they cover different scenarios.

## Releasing

Bumping `VERSION` on `main` triggers
[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml),
which builds and pushes the image to Docker Hub and cuts a matching
GitHub Release.
