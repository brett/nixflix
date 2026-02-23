---
title: Getting Started
---

!!! tip "Quick Start"

    New to Nixflix? Start with the [Installation Guide](getting-started/index.md) or explore the [Basic Setup Example](examples/basic-setup.md).

# Nixflix

Nixflix is a declarative media server configuration manager for NixOS. The aim of the project is to automate all of the connective tissue required to get get Starr and Jellyfin services ([Sonarr](https://github.com/Sonarr/Sonarr), [Radarr](https://github.com/Radarr/Radarr), [Lidarr](https://github.com/Lidarr/Lidarr), [Prowlarr](https://github.com/Prowlarr/Prowlarr), [Jellyfin](https://github.com/jellyfin/jellyfin), [Jellyseerr](https://github.com/seerr-team/seerr)) working together. I want users to be able to configure this module and it just works.

!!! warning "Alpha Software"
    This project is alpha-almost-beta-software. Please expect breaking changes until the [1.0 milestone](https://github.com/kiriwalawren/nixflix/milestone/1) is achieved.

## Why Nixflix?

Dreading the thought of configuring a media server from scratch. Again...

Nixflix makes it so you never have to again!

Managing media server configuration can be very painful:

- **No version control** for settings
- **Tedious navigation** through UI systems
- **And annoying interservice** Configuration

All of these services have APIs, surely we can use this to automate the whole thing.

Nixflix is:

- ✅ **Opionated** — Don't you hate having to think for yourself?
- ✅ **API-based** — Nixflix uses official REST APIs of each service (with a couple minor exceptions)
- ✅ **Idempotent** — All services safely execute repeatedly
- ✅ **Commanding** — Your code is _the_ source of truth, no need to fear drift

## Quick Example

=== "Standard Setup"

    ```nix
    {
      nixflix = {
        enable = true;
        mediaDir = "/data/media";
        stateDir = "/data/.state/services";

        sonarr = {
          enable = true;
          config.apiKey = {_secret = "/run/secrets/sonarr-api-key";};
        };

        prowlarr = {
          enable = true;
          config.apiKey = {_secret = "/run/secrets/prowlarr-api-key";};
        };

        sabnzbd = {
          enable = true;
          settings.misc.api_key = {_secret = "/run/secrets/sabnzbd-api-key";};
        };

        jellyfin.enable = true;
      };
    }
    ```

=== "With MicroVM Isolation"

    ```nix
    {
      nixflix = {
        enable = true;

        # Enable microVM isolation for enhanced security
        microvm.enable = true;

        mediaDir = "/data/media";
        stateDir = "/data/.state/services";

        sonarr = {
          enable = true;
          config.apiKey = {_secret = "/run/secrets/sonarr-api-key";};
        };

        prowlarr = {
          enable = true;
          config.apiKey = {_secret = "/run/secrets/prowlarr-api-key";};
        };

        sabnzbd = {
          enable = true;
          settings.misc.api_key = {_secret = "/run/secrets/sabnzbd-api-key";};
        };

        jellyfin.enable = true;
      };
    }
    ```

## Features

- ✅ **Declarative Configuration** - All services configured via NixOS options
- ✅ **API-Based Management** - Automatic configuration through service REST APIs
- ✅ **PostgreSQL Integration** - Optional database backend for all *arr services
- ✅ **Mullvad VPN Support** - Built-in VPN with kill switch and custom DNS
- ✅ **MicroVM Isolation** - Run each service in its own isolated virtual machine
- ✅ **TRaSH Guides** - Default configuration follows TRaSH guidelines
- ✅ **Unified Theming** - All services can be themed consistently
- ✅ **Hardlink Support** - Efficient instant moves for media files

## Next Steps

- [Installation](getting-started/index.md) - Add Nixflix to your NixOS configuration
- [MicroVM Isolation](getting-started/microvm.md) - Optional per-service isolation
- [Examples](examples/basic-setup.md) - Copy-paste ready configurations
- [Reference](reference/index.md) - Complete documentation of all options
