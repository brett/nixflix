---
title: MicroVM Setup Example
---

# MicroVM Setup Example

Nixflix supports running each service in an isolated [microVM](https://github.com/astro/microvm.nix)
via the optional `nixosModules.microvm` module. Each VM gets its own static IP on a private bridge,
hard process isolation, and automatic VPN bypass so Starr services are never routed through a VPN.

## Requirements

- KVM hardware support (`/dev/kvm` available on the host)
- `nixosModules.microvm` imported alongside `nixosModules.default`

## Flake Setup

```nix
{
  description = "My NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixflix, microvm, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        nixflix.nixosModules.default          # standard nixflix (unchanged)
        (nixflix.nixosModules.microvm microvm) # opt-in microvm support
      ];
    };
  };
}
```

## Minimal MicroVM Configuration

```nix
{
  nixflix = {
    enable = true;
    mediaDir = "/data/media";
    stateDir = "/data/.state";

    # Global microvm settings (all optional — defaults shown)
    microvm = {
      enable = true;
      hypervisor = "cloud-hypervisor"; # or "qemu"
      network = {
        bridge = "nixflix-br0";
        subnet = "10.100.0.0/24";
        hostAddress = "10.100.0.1";
      };
    };

    postgres = {
      enable = true;
      microvm.enable = true; # PostgreSQL runs in its own VM (10.100.0.2)
    };

    sonarr = {
      enable = true;
      microvm.enable = true; # Sonarr VM at 10.100.0.10
      config = {
        apiKey = { _secret = config.sops.secrets."sonarr/api_key".path; };
        hostConfig.password = { _secret = config.sops.secrets."sonarr/password".path; };
      };
    };

    radarr = {
      enable = true;
      microvm.enable = true; # Radarr VM at 10.100.0.12
      config = {
        apiKey = { _secret = config.sops.secrets."radarr/api_key".path; };
        hostConfig.password = { _secret = config.sops.secrets."radarr/password".path; };
      };
    };

    nginx = {
      enable = true;
      addHostsEntries = true;
    };
  };
}
```

## What Happens Automatically

### Networking

- A bridge interface `nixflix-br0` (`10.100.0.0/24`) is created on the host via systemd-networkd.
- Each VM gets a tap interface attached to the bridge and a static IP from the address table below.
- NAT masquerade is applied via nftables so VMs can reach the internet through the host.

### VPN Bypass

All VMs receive Mullvad bypass nftables marks by default (`0x00000f41` / `0x6d6f6c65`), routing
them around the VPN. This follows TRaSH Guides recommendations: Starr services and Jellyfin should
**not** run behind a VPN, even when the host has Mullvad enabled.

qBittorrent is the exception — it explicitly opts out of bypass so torrent traffic always routes
through the VPN.

### Host Systemd Units

When `nixflix.<service>.microvm.enable = true`, the corresponding host-side systemd units are replaced
with lightweight stubs:

- `<service>.service` — no-op, waits for `<service>-ready.service`
- `<service>-config.service`, `<service>-rootfolders.service`, etc. — no-ops (run inside the VM)
- `<service>-ready.service` — polls the VM's HTTP API until it responds, then signals ready

Supporting oneshots (API configuration, root folder setup, quality profiles) run inside the VM on
first boot and thereafter.

### nginx

nginx proxies are automatically updated to point at the VM's static IP instead of `localhost`.
No manual configuration is required.

### Secrets

Secrets managed by [sops-nix](https://github.com/Mic92/sops-nix) or
[agenix](https://github.com/ryantm/agenix) work transparently in microVM mode. If you have
declared secrets with either tool, Nixflix automatically virtiofs-mounts the host's decrypted
secrets directory into every guest VM at the same path — so `{ _secret = "/run/secrets/foo"; }`
works identically whether a service is running on the host or in a microVM.

No additional configuration is required. Detection is automatic:

- sops-nix (`/run/secrets`) is shared when `config.sops.secrets` is non-empty
- agenix (`/run/agenix`) is shared when `config.age.secrets` is non-empty

## Static IP Address Table

Default subnet `10.100.0.0/24`:

| Service | Address |
|---------|---------|
| Host | `10.100.0.1` |
| PostgreSQL | `10.100.0.2` |
| Sonarr | `10.100.0.10` |
| Sonarr Anime | `10.100.0.11` |
| Radarr | `10.100.0.12` |
| Lidarr | `10.100.0.13` |
| Prowlarr | `10.100.0.14` |
| SABnzbd | `10.100.0.20` |
| qBittorrent | `10.100.0.21` |
| Jellyfin | `10.100.0.30` |
| Jellyseerr | `10.100.0.31` |

Addresses are derived from `nixflix.microvm.network.subnet` and available as
`nixflix.microvm.addresses.<service>`. Override any address via
`nixflix.<service>.microvm.address`.

## VM Sizing

Set global defaults for all VMs, then override per-service as needed:

```nix
nixflix.microvm.defaults = {
  vcpus = 1;      # applied to every VM unless overridden
  memoryMB = 512;
};

# Override for individual services
nixflix.jellyfin.microvm.memoryMB = 2048;
nixflix.postgres.microvm.memoryMB = 1024;
nixflix.sonarr.microvm.vcpus = 2;
```

Jellyfin defaults to 2 vCPUs / 1024 MB regardless of `microvm.defaults`, since it requires more
resources for transcoding.

## Full Stack Example

The following runs every service in its own VM:

```nix
{
  nixflix = {
    enable = true;
    mediaDir = "/data/media";
    stateDir = "/data/.state";

    microvm.enable = true;

    postgres.microvm.enable = true;
    sonarr.microvm.enable = true;
    sonarr-anime.microvm.enable = true;
    radarr.microvm.enable = true;
    lidarr.microvm.enable = true;
    prowlarr.microvm.enable = true;
    usenetClients.sabnzbd.microvm.enable = true;
    torrentClients.qbittorrent.microvm.enable = true;
    jellyfin.microvm.enable = true;
    jellyseerr.microvm.enable = true;

    # ... service-specific config (apiKey, password, etc.)
    # ... nginx, mullvad, recyclarr as normal
  };
}
```

All inter-service connections (arr→postgres, arr→prowlarr, arr→download clients, jellyseerr→arr)
are wired automatically using the static VM IP addresses.

## Troubleshooting

**VM fails to start**: Check `journalctl -u microvm@sonarr.service` on the host.

**Service unreachable**: Check `journalctl -u sonarr-ready.service` — it polls the VM API and
logs each attempt with the HTTP status code.

**Database connection issues**: The arr services include a `wait-for-db` gate inside the VM that
polls PostgreSQL every 2 seconds for up to 5 minutes before starting the service.

**First boot is slow**: First-boot database migrations can take several minutes. The
`<service>-ready` oneshot has a 10-minute timeout. Subsequent boots are fast.
