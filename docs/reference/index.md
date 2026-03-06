---
title: Reference
---

# Options Reference

This section contains automatically generated documentation for all Nixflix configuration options.

## How to Read This Reference

Each option is documented with:

- **Description**: What the option does
- **Type**: The data type expected (string, boolean, list, etc.)
- **Default**: The default value if not specified
- **Example**: Example usage
- **Declared in**: Links to the source file where the option is defined

## Available Sections

### Core

- [Core Options](core/index.md) - Top-level Nixflix configuration

### Media Management

- [Jellyseerr](jellyseerr/index.md) - Requests management
- [Sonarr](sonarr/index.md) - TV show management
- [Sonarr Anime](sonarr-anime/index.md) - Anime management
- [Radarr](radarr/index.md) - Movie management
- [Lidarr](lidarr/index.md) - Music management
- [Prowlarr](prowlarr/index.md) - Indexer management

### Media Server

- [Jellyfin](jellyfin/index.md) - Media streaming server

### Download Clients

- [Downloadarr](downloadarr/index.md)

#### Usenet

- [SABnzbd](usenetClients/sabnzbd/index.md)

#### BitTorrent

- [qBittorrent](torrentClients/qbittorrent/index.md)

### Infrastructure

- [Mullvad VPN](mullvad/index.md) - VPN configuration
- [PostgreSQL](postgres/index.md) - Database configuration
- [Recyclarr](recyclarr/index.md) - TRaSH guides automation

### MicroVM Isolation (opt-in)

Import `nixflix.nixosModules.microvm` to enable microVM support. Each service then gains a `microvm` sub-option:

- `nixflix.microvm` - Global settings (hypervisor, network bridge, subnet, VPN bypass)
- `nixflix.<service>.microvm.enable` - Run this service in an isolated VM
- `nixflix.<service>.microvm.address` - Static IP (defaults from `nixflix.microvm.addresses.<service>`)
- `nixflix.<service>.microvm.vcpus` / `.memoryMB` - VM sizing

See the [MicroVM Setup Example](../examples/microvm-setup.md) for usage.
