______________________________________________________________________

## title: MicroVM Isolation

# MicroVM Isolation

Nixflix supports running each service in its own isolated microVM for enhanced security and resource isolation. This is an optional feature that can be enabled globally or per-service.

!!! info "Beta Feature"
MicroVM support is currently in beta. While fully functional, some advanced features like per-service VPN bypass are still being refined.

!!! tip "First Time Setup?"
If you're setting up Nixflix for the first time, start with the [Getting Started Guide](index.md) which explains when to use microVMs and provides complete configuration examples.

## Prerequisites

Before enabling microVM support, ensure your system meets these requirements:

- **Hardware virtualization support** (Intel VT-x or AMD-V)

  ```bash
  # Check if your CPU supports virtualization
  grep -E 'vmx|svm' /proc/cpuinfo
  # Should return results. If empty, enable VT-x/AMD-V in BIOS.
  ```

- **KVM kernel modules** (usually enabled by default on NixOS)

  ```bash
  # Verify KVM is available
  ls -la /dev/kvm
  # Should show: crw-rw-rw- 1 root kvm ... /dev/kvm
  ```

- **Sufficient resources** - Each microVM requires dedicated CPU and memory:

  - Minimum: 2 vCPUs + 1GB RAM per service
  - Recommended: 4+ core CPU with 8GB+ total RAM for a full stack

- **NixOS with flakes enabled** - microvm.nix is loaded as a flake dependency

## Overview

When microVM mode is enabled, each Nixflix service runs in its own lightweight virtual machine with:

- **Complete isolation** - Each service runs in a separate VM
- **Dedicated resources** - Configurable CPU and memory per service
- **Shared storage** - virtiofs for hardlink-compatible file sharing
- **Network connectivity** - Bridge networking with static IPs
- **VPN routing** - Traffic routes through host's Mullvad VPN

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│                        HOST                              │
│  ┌─────────────┐  ┌─────────────┐                        │
│  │  Mullvad    │  │ PostgreSQL  │                        │
│  │  VPN        │  │  :5432      │                        │
│  └─────────────┘  └─────────────┘                        │
│         │                │                                │
│  ┌──────┴────────────────┴────────────────────────┐      │
│  │        nixflix-br0 (10.100.0.1/24)             │      │
│  └───┬────────┬────────┬────────┬────────┬────────┘      │
│      │        │        │        │        │                │
│  ┌───┴───┐┌───┴───┐┌───┴───┐┌───┴───┐┌───┴───┐          │
│  │Sonarr ││Radarr ││Prowl. ││SABnzbd││Jelly- │          │
│  │.10    ││.12    ││.14    ││.20    ││fin.30 │          │
│  └───────┘└───────┘└───────┘└───────┘└───────┘          │
└──────────────────────────────────────────────────────────┘
```

## Quick Start

### Enable for All Services

```nix
{
  nixflix = {
    enable = true;

    # Enable microVM mode globally
    microvm.enable = true;
    microvm.hypervisor = "cloud-hypervisor";  # or "qemu"

    # All enabled services will run in microVMs
    sonarr.enable = true;
    radarr.enable = true;
    jellyfin.enable = true;
  };
}
```

### Selective MicroVM Deployment

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    sonarr.enable = true;        # Runs in microVM
    radarr.enable = true;        # Runs in microVM

    # Disable microVM for Jellyfin (e.g., for GPU access)
    jellyfin = {
      enable = true;
      microvm.enable = false;    # Runs on host
    };
  };
}
```

## Configuration Options

### Global Options

Configure defaults for all microVMs:

```nix
{
  nixflix.microvm = {
    enable = true;

    # Hypervisor selection
    hypervisor = "cloud-hypervisor";  # or "qemu"

    # Network configuration
    network = {
      bridge = "nixflix-br0";
      subnet = "10.100.0.0/24";
      hostAddress = "10.100.0.1";
    };

    # Default resources for all microVMs
    defaults = {
      vcpus = 2;
      memoryMB = 1024;
    };
  };
}
```

### Per-Service Options

Override defaults for specific services:

```nix
{
  nixflix = {
    microvm.enable = true;

    sonarr = {
      enable = true;
      # Use default resources (2 vCPUs, 1024 MB)
    };

    jellyfin = {
      enable = true;
      # Give Jellyfin more resources for transcoding
      microvm = {
        enable = true;
        vcpus = 4;
        memoryMB = 2048;
      };
    };

    radarr = {
      enable = true;
      # Custom IP address (optional)
      microvm.address = "10.100.0.50";
    };
  };
}
```

## Static IP Addresses

Each service gets a predictable static IP address:

| Service | Default IP | Port |
|----------------|----------------|-------|
| Sonarr | 10.100.0.10 | 8989 |
| Sonarr-anime | 10.100.0.11 | 8990 |
| Radarr | 10.100.0.12 | 7878 |
| Lidarr | 10.100.0.13 | 8686 |
| Prowlarr | 10.100.0.14 | 9696 |
| SABnzbd | 10.100.0.20 | 8080 |
| Jellyfin | 10.100.0.30 | 8096 |
| Jellyseerr | 10.100.0.31 | 5055 |

Access services from the host:

```bash
# Sonarr API
curl http://10.100.0.10:8989/api/v3/system/status

# Radarr web interface
firefox http://10.100.0.12:7878
```

## Storage and Hardlinks

MicroVMs use **virtiofs** to share storage with the host, which fully supports hardlinks for [TRaSH guide compatibility](https://trash-guides.info/File-and-Folder-Structure/Hardlinks-and-Instant-Moves/).

### Shared Directories

Each microVM mounts:

- `/data/media` - Media libraries (shared)
- `/data/downloads` - Download directories (shared)
- `/data/.state/<service>` - Service-specific state (isolated)

### Hardlink Example

```bash
# On host — write a file to the shared downloads directory
echo "test" > /data/downloads/file.txt

# Sonarr (running in its microVM) will see /data/downloads/file.txt
# via virtiofs and can hardlink it to the media directory.
# Hardlinks created by microVM services appear on the host with the same inode:
stat -c '%i' /data/downloads/file.txt
stat -c '%i' /data/media/tv/show/file.txt
# Both show the same inode number
```

Hardlinks work seamlessly across microVMs because all VMs share the same underlying virtiofs filesystem, enabling efficient instant moves for completed downloads.

## VPN Integration

When Mullvad VPN is enabled, microVM traffic routes through the host's VPN tunnel by default.

### Basic VPN Setup

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    # Enable Mullvad VPN
    mullvad = {
      enable = true;
      accountNumber = { _secret = "/run/secrets/mullvad-account"; };
      autoConnect = true;
      killSwitch.enable = true;
    };

    # All services will route through VPN
    sonarr.enable = true;
    radarr.enable = true;
  };
}
```

### Per-Service VPN Control

```nix
{
  nixflix = {
    mullvad.enable = true;
    microvm.enable = true;

    # Route through VPN (default for most services)
    radarr = {
      enable = true;
      vpn.enable = true;
    };

    # Bypass VPN (default for *arr services to avoid Cloudflare blocks)
    sonarr = {
      enable = true;
      vpn.enable = false;
    };
  };
}
```

!!! warning "VPN Bypass Limitation"
Full per-service VPN bypass in microVM mode requires additional routing table configuration. Currently, all microVM traffic routes through the VPN when Mullvad is enabled.

```
**Workaround:** Disable microVM for services that need VPN bypass - they'll use `mullvad-exclude` on the host.
```

## PostgreSQL Integration

PostgreSQL can run on the host with microVMs connecting via TCP:

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    # PostgreSQL on host
    postgres.enable = true;

    # Services connect via TCP to 10.100.0.1:5432
    sonarr.enable = true;
    radarr.enable = true;
  };
}
```

PostgreSQL automatically:

- Listens on the bridge interface (10.100.0.1)
- Allows connections from the microVM subnet
- Uses `scram-sha-256` authentication

## Hypervisor Options

### cloud-hypervisor (Default)

```nix
nixflix.microvm.hypervisor = "cloud-hypervisor";
```

- ✅ Lighter weight
- ✅ Faster startup (~5–8s faster on multi-VM tests)
- ✅ Lower memory overhead
- ⚠️ Requires kernel 5.4+

### QEMU

```nix
nixflix.microvm.hypervisor = "qemu";
```

- ✅ More mature and widely tested
- ✅ Supports `type = "bridge"` network interfaces
- ⚠️ Slightly higher overhead

## Resource Planning

### Default Resources

Each microVM gets by default:

- **2 vCPUs**
- **1024 MB RAM**

### Recommended Allocations

| Service | vCPUs | Memory | Notes |
|------------|-------|--------|-------|
| Sonarr | 2 | 1024 | Default is fine |
| Radarr | 2 | 1024 | Default is fine |
| Prowlarr | 2 | 1024 | Default is fine |
| SABnzbd | 2 | 1024 | Increase for large downloads |
| Jellyfin | 4 | 2048 | Increase for transcoding |
| Jellyseerr | 2 | 1024 | Default is fine |

### Example: High-Performance Setup

```nix
{
  nixflix = {
    microvm = {
      enable = true;
      defaults = {
        vcpus = 2;
        memoryMB = 1024;
      };
    };

    # Override for Jellyfin
    jellyfin.microvm = {
      vcpus = 6;
      memoryMB = 4096;
    };

    # Override for SABnzbd
    sabnzbd.microvm = {
      vcpus = 4;
      memoryMB = 2048;
    };
  };
}
```

## Management and Monitoring

### Check MicroVM Status

```bash
# List all microVMs
systemctl list-units 'microvm@*'

# Check specific service
systemctl status microvm@sonarr.service

# View logs
journalctl -u microvm@sonarr.service -f
```

### Access MicroVM Shell

!!! warning "machinectl Not Supported with QEMU"
`machinectl shell` does **not** work with QEMU-based microVMs — QEMU microvms do not register with systemd-machined. Use the host's network access instead:

````
```bash
# Check if a service port is reachable (e.g. Sonarr)
curl http://10.100.0.10:8989/api/v3/system/status \
  -H 'X-Api-Key: <your-api-key>'

# View service logs via the microVM journal service on host
journalctl -u microvm@sonarr.service -f
```

If your hypervisor is `cloud-hypervisor`, vsock-based shell access may be available with additional configuration (`microvm.vsock.cid`).
````

### Restart Services

```bash
# Restart Sonarr microVM
systemctl restart microvm@sonarr.service

# Restart all microVMs
systemctl restart 'microvm@*.service'
```

## Troubleshooting

### MicroVM Won't Start

Check the kernel modules:

```bash
# Verify KVM is available
lsmod | grep kvm

# Load modules manually if needed
modprobe kvm-intel  # or kvm-amd
```

### Network Connectivity Issues

Verify bridge configuration:

```bash
# Check bridge exists
ip link show nixflix-br0

# Verify bridge IP
ip addr show nixflix-br0

# Check NAT rules
iptables -t nat -L -n -v
```

### Service Can't Connect to PostgreSQL

Verify PostgreSQL is listening on the bridge interface:

```bash
# Check PostgreSQL is listening on the bridge address
ss -tln | grep 5432

# Test TCP reachability from host to postgres microVM
timeout 5 bash -c '</dev/tcp/10.100.0.2/5432' && echo OK || echo FAILED
```

### Hardlinks Not Working

virtiofs mounts are configured by the nixflix module — verify the microVM started correctly:

```bash
# Check the microVM service is running
systemctl status microvm@sonarr.service

# Check microVM logs for virtiofs mount errors
journalctl -u microvm@sonarr.service | grep -i 'virtiofs\|mount\|share'
```

## Performance Considerations

### CPU

- Each microVM adds ~50-100 MB overhead
- Overcommit vCPUs is safe (2 vCPUs per VM on a 4-core host works fine)

### Memory

- Plan for: (number of services × memory per VM) + 1 GB host overhead
- Example: 5 services × 1 GB + 1 GB = 6 GB total RAM needed

### Disk I/O

- virtiofs has minimal overhead for sequential I/O
- Hardlinks work identically to native filesystem

## Migration Guide

### From Standard to MicroVM

1. **Backup your configuration and data**

1. **Enable microVM mode:**

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;  # Add this line

    # Existing services unchanged
    sonarr.enable = true;
    radarr.enable = true;
  };
}
```

3. **Rebuild and switch:**

```bash
sudo nixos-rebuild switch
```

4. **Verify services:**

```bash
systemctl status microvm@sonarr.service
curl http://10.100.0.10:8989/api/v3/system/status
```

### Rollback to Standard

Simply disable microVM mode:

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = false;  # Disable microVMs

    # Services continue working on host
    sonarr.enable = true;
    radarr.enable = true;
  };
}
```

## Limitations

### Current Limitations

1. **GPU Passthrough** - Not yet implemented for Jellyfin hardware transcoding

   - **Workaround:** Disable microVM for Jellyfin

1. **VPN Bypass** - Per-service VPN bypass requires additional routing configuration

   - **Workaround:** Disable microVM for services needing bypass

1. **Nested Virtualization** - Host must support KVM

   - **Requirement:** Hardware virtualization enabled in BIOS

### Future Enhancements

- [ ] GPU device passthrough for Jellyfin
- [ ] Complete VPN bypass implementation via routing tables
- [ ] Support for firecracker hypervisor
- [ ] Resource usage monitoring dashboard

## Best Practices

1. **Start Simple** - Enable microVM for one service first, verify it works
1. **Monitor Resources** - Use `htop` to ensure adequate CPU/RAM
1. **Plan Networking** - Reserve IP addresses if adding custom services
1. **Test Backups** - Verify backup/restore procedures with microVMs
1. **Use Defaults** - Override resources only when needed

## FAQ

### Why use microVMs?

- **Security:** Isolate services from each other
- **Resource Control:** Limit CPU/memory per service
- **Clean Separation:** Each service in its own environment
- **Easier Debugging:** Isolated logs and processes

### Do microVMs affect performance?

Minimal impact:

- ~50-100 MB RAM overhead per VM
- ~1-2% CPU overhead
- Storage I/O nearly identical to native
- Network latency: \<1ms within host

### Can I mix microVM and host services?

Yes! Disable microVM per-service:

```nix
nixflix = {
  microvm.enable = true;      # Default to microVMs
  sonarr.enable = true;       # Runs in microVM
  jellyfin.microvm.enable = false;  # Runs on host
};
```

### How do I access services from outside the host?

Use nginx reverse proxy on the host, or forward ports:

```nix
networking.firewall = {
  allowedTCPPorts = [ 8989 ];  # Expose Sonarr
};

# DNAT to forward external traffic to microVM
networking.nat.forwardPorts = [{
  sourcePort = 8989;
  destination = "10.100.0.10:8989";
}];
```

## See Also

- [Basic Setup Example](../examples/basic-setup.md)
- [TRaSH Guides](https://trash-guides.info/)
- [microvm.nix Project](https://github.com/astro/microvm.nix)
