#!/bin/sh
# frigate-mqtt-watchdog
#
# Watches for a live MQTT connection between Frigate and its broker by
# tracking the age of the last received frigate/stats message. If no
# stats message has been seen within STALE_THRESHOLD seconds, restarts
# the Frigate container via the Docker socket.
#
# This exists to work around a known upstream bug in Frigate's MQTT
# client (paho-mqtt), where the client can get stuck in a state where
# it never attempts to reconnect after the broker restarts or a
# connection is otherwise lost. See design.md for full background.
#
# Required environment variables:
#   MQTT_HOST          - hostname/IP of the MQTT broker
#   MQTT_PORT          - MQTT broker port (usually 1883)
#   CHECK_INTERVAL      - seconds between staleness checks
#   STALE_THRESHOLD     - seconds since last stats message before
#                         considering the connection dead
#   FAIL_THRESHOLD       - consecutive stale checks required before
#                         triggering a restart
#   FRIGATE_CONTAINER   - name of the Frigate container to restart

set -u

echo "$(date -Iseconds) frigate-mqtt-watchdog v${APP_VERSION:-unknown} starting"

apk add --no-cache mosquitto-clients >/dev/null 2>&1

STATE_FILE=/tmp/last_stats_seen
date +%s > "$STATE_FILE"

# Runs a persistent mosquitto_sub subscription to frigate/stats in the
# background. -R suppresses the initial retained message on subscribe,
# so a broker restart that reloads a stale retained value from disk
# does not get mistaken for a live, healthy connection. Every line
# received updates STATE_FILE with the current timestamp.
start_subscriber() {
  mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "frigate/stats" -R 2>/dev/null | \
    while IFS= read -r _; do date +%s > "$STATE_FILE"; done &
  SUB_PID=$!
}

start_subscriber
fail_count=0

while true; do
  sleep "$CHECK_INTERVAL"

  now=$(date +%s)
  last=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  elapsed=$((now - last))

  if [ "$elapsed" -lt "$STALE_THRESHOLD" ]; then
    fail_count=0
  else
    fail_count=$((fail_count + 1))
    echo "$(date -Iseconds) no stats in ${elapsed}s (threshold ${STALE_THRESHOLD}s), fail_count=${fail_count}"
  fi

  if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
    echo "$(date -Iseconds) restarting ${FRIGATE_CONTAINER}"
    docker restart "$FRIGATE_CONTAINER"
    fail_count=0
    date +%s > "$STATE_FILE"
    sleep 90
  fi

  # Restart the background subscriber if it died for any reason
  # (broker unreachable long enough for mosquitto_sub to exit, etc.)
  if ! kill -0 "$SUB_PID" 2>/dev/null; then
    start_subscriber
  fi
done
