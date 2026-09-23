# frigate-mqtt-watchdog
#
# Bakes mosquitto-clients and the watchdog script into a docker:cli
# base image, so the published image is a self-contained drop-in
# sidecar -- no runtime `apk add` and no bind-mounted script needed.
# See docs/design.md for the full background on why this exists.

FROM docker:cli

RUN apk add --no-cache mosquitto-clients

COPY watchdog.sh /watchdog.sh
RUN chmod +x /watchdog.sh

ARG VERSION=unknown
ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/bdelima/frigate-mqtt-watchdog" \
      org.opencontainers.image.url="https://github.com/bdelima/frigate-mqtt-watchdog" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
ENV APP_VERSION="${VERSION}"

# Sane defaults for the tuning knobs; MQTT_HOST and FRIGATE_CONTAINER
# are host-specific and have no default -- watchdog.sh runs with
# `set -u` so it fails loudly if they're left unset rather than
# silently doing the wrong thing.
ENV MQTT_PORT=1883 \
    CHECK_INTERVAL=60 \
    STALE_THRESHOLD=200 \
    FAIL_THRESHOLD=1 \
    FRIGATE_CONTAINER=frigate

ENTRYPOINT ["/bin/sh", "/watchdog.sh"]
