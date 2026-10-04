# Attribution

This repository's own code is licensed under the MIT License (see `LICENSE`). It uses or builds on the third-party projects below, each under its own license and copyright; nothing here relicenses them.

## Frigate

- **Project:** [blakeblackshear/frigate](https://github.com/blakeblackshear/frigate)
- **License:** MIT (copyright Frigate, Inc.)
- **How it's used:** this watchdog monitors and restarts a separately-run Frigate container. No Frigate code is included.

## Docker CLI (base image)

- **Project:** [docker/cli](https://github.com/docker/cli), via the official `docker:cli` image
- **License:** Apache-2.0
- **How it's used:** base image; the watchdog uses the `docker` CLI to restart the container.

## Eclipse Mosquitto clients

- **Project:** [eclipse-mosquitto/mosquitto](https://github.com/eclipse-mosquitto/mosquitto)
- **License:** dual-licensed EPL-2.0 / EDL-1.0
- **How it's used:** `mosquitto-clients` is installed from Alpine's package repository at image build time; the watchdog uses it to observe the MQTT connection.

## Alpine Linux packages

- Packages installed by the Dockerfile carry their own licenses (see the package metadata inside the image).

## Trademarks

"Frigate" is a trademark of Frigate, Inc. This is an unofficial project, not affiliated with or endorsed by Frigate, Inc.
