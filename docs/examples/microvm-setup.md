______________________________________________________________________

## title: MicroVM Setup Examples

# MicroVM Setup Examples

Complete examples for deploying Nixflix services in microVMs.

## Basic MicroVM Setup

Minimal configuration to get started with microVM isolation:

```nix
{ config, pkgs, ... }:

{
  imports = [
    # Add nixflix to your imports
  ];

  nixflix = {
    enable = true;

    # Enable microVM isolation
    microvm.enable = true;

    # Basic *arr stack
    prowlarr = {
      enable = true;
      config.apiKey = { _secret = "/run/secrets/prowlarr-apikey"; };
    };

    sonarr = {
      enable = true;
      config.apiKey = { _secret = "/run/secrets/sonarr-apikey"; };
    };

    radarr = {
      enable = true;
      config.apiKey = { _secret = "/run/secrets/radarr-apikey"; };
    };

    sabnzbd = {
      enable = true;
      settings.misc.api_key = { _secret = "/run/secrets/sabnzbd-apikey"; };
    };
  };
}
```

## Full Stack with PostgreSQL

Complete media server with database backend:

```nix
{ config, pkgs, ... }:

{
  nixflix = {
    enable = true;

    # Enable microVMs
    microvm = {
      enable = true;
      hypervisor = "cloud-hypervisor";
    };

    # PostgreSQL on host
    postgres.enable = true;

    # Media directories
    mediaDir = "/data/media";
    downloadsDir = "/data/downloads";
    stateDir = "/data/.state";

    # Full *arr stack
    prowlarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/prowlarr-apikey"; };
        hostConfig = {
          username = "admin";
          password = { _secret = "/run/secrets/prowlarr-password"; };
        };
      };
    };

    sonarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/sonarr-apikey"; };
        hostConfig = {
          username = "admin";
          password = { _secret = "/run/secrets/sonarr-password"; };
        };
      };
    };

    radarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/radarr-apikey"; };
        hostConfig = {
          username = "admin";
          password = { _secret = "/run/secrets/radarr-password"; };
        };
      };
    };

    lidarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/lidarr-apikey"; };
        hostConfig = {
          username = "admin";
          password = { _secret = "/run/secrets/lidarr-password"; };
        };
      };
    };

    sabnzbd = {
      enable = true;
      settings.misc = {
        host = "0.0.0.0";
        port = 8080;
        api_key = { _secret = "/run/secrets/sabnzbd-apikey"; };
      };
    };

    jellyfin = {
      enable = true;
      # Disable microVM for GPU access
      microvm.enable = false;
      encoding.enableHardwareEncoding = true;
    };

    jellyseerr = {
      enable = true;
      apiKey = { _secret = "/run/secrets/jellyseerr-apikey"; };
    };
  };
}
```

## Custom Resource Allocation

Optimize resource usage for your hardware:

```nix
{
  nixflix = {
    enable = true;

    microvm = {
      enable = true;

      # Defaults for most services
      defaults = {
        vcpus = 2;
        memoryMB = 1024;
      };
    };

    # Lightweight services use defaults
    prowlarr.enable = true;
    sonarr.enable = true;
    radarr.enable = true;

    # SABnzbd gets more resources for unpacking
    sabnzbd = {
      enable = true;
      microvm = {
        vcpus = 4;
        memoryMB = 2048;
      };
      settings.misc.api_key = { _secret = "/run/secrets/sabnzbd-apikey"; };
    };

    # Jellyseerr minimal resources
    jellyseerr = {
      enable = true;
      microvm = {
        vcpus = 1;
        memoryMB = 512;
      };
      apiKey = { _secret = "/run/secrets/jellyseerr-apikey"; };
    };
  };
}
```

## With Mullvad VPN

Route microVM traffic through VPN:

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    # Mullvad VPN configuration
    mullvad = {
      enable = true;
      accountNumber = { _secret = "/run/secrets/mullvad-account"; };
      autoConnect = true;
      location = ["us" "nyc"];
      killSwitch = {
        enable = true;
        allowLan = true;
      };
      dns = ["1.1.1.1" "8.8.8.8"];
    };

    # Services with VPN routing
    prowlarr = {
      enable = true;
      vpn.enable = true;  # Use VPN for indexers
      config.apiKey = { _secret = "/run/secrets/prowlarr-apikey"; };
    };

    # Services bypassing VPN (default for *arr)
    sonarr = {
      enable = true;
      vpn.enable = false;  # Bypass to avoid Cloudflare blocks
      config.apiKey = { _secret = "/run/secrets/sonarr-apikey"; };
    };

    radarr = {
      enable = true;
      vpn.enable = false;
      config.apiKey = { _secret = "/run/secrets/radarr-apikey"; };
    };
  };
}
```

## Hybrid Deployment

Mix microVM and host-based services:

```nix
{
  nixflix = {
    enable = true;

    # Enable microVMs globally
    microvm.enable = true;

    # Most services in microVMs (inherit global setting)
    prowlarr.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
    lidarr.enable = true;
    sabnzbd.enable = true;
    jellyseerr.enable = true;

    # Jellyfin on host for GPU transcoding
    jellyfin = {
      enable = true;
      microvm.enable = false;  # Override: run on host
      encoding = {
        enableHardwareEncoding = true;
        hardwareAccelerationApi = "vaapi";
      };
    };
  };
}
```

## With Nginx Reverse Proxy

Expose services through nginx:

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    # Enable nginx reverse proxy
    nginx.enable = true;

    prowlarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/prowlarr-apikey"; };
        hostConfig.urlBase = "/prowlarr";
      };
    };

    sonarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/sonarr-apikey"; };
        hostConfig.urlBase = "/sonarr";
      };
    };

    radarr = {
      enable = true;
      config = {
        apiKey = { _secret = "/run/secrets/radarr-apikey"; };
        hostConfig.urlBase = "/radarr";
      };
    };
  };

  # Additional nginx configuration
  services.nginx = {
    virtualHosts."media.example.com" = {
      enableACME = true;
      forceSSL = true;
      locations = {
        "/prowlarr" = {
          proxyPass = "http://10.100.0.14:9696";
        };
        "/sonarr" = {
          proxyPass = "http://10.100.0.10:8989";
        };
        "/radarr" = {
          proxyPass = "http://10.100.0.12:7878";
        };
      };
    };
  };
}
```

## Cloud-Hypervisor Setup

Use cloud-hypervisor for lighter weight VMs:

```nix
{
  nixflix = {
    enable = true;

    microvm = {
      enable = true;
      # Use cloud-hypervisor instead of QEMU
      hypervisor = "cloud-hypervisor";

      defaults = {
        vcpus = 2;
        memoryMB = 768;  # Lower memory overhead
      };
    };

    # Your services
    prowlarr.enable = true;
    sonarr.enable = true;
    radarr.enable = true;
  };

  # Ensure kernel version is compatible (5.4+)
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
```

## Complete Production Setup

Full-featured production configuration:

```nix
{ config, pkgs, ... }:

{
  # Secret management (use agenix, sops-nix, or similar)
  age.secrets = {
    prowlarr-apikey.file = ./secrets/prowlarr-apikey.age;
    sonarr-apikey.file = ./secrets/sonarr-apikey.age;
    radarr-apikey.file = ./secrets/radarr-apikey.age;
    lidarr-apikey.file = ./secrets/lidarr-apikey.age;
    sabnzbd-apikey.file = ./secrets/sabnzbd-apikey.age;
    jellyseerr-apikey.file = ./secrets/jellyseerr-apikey.age;
    mullvad-account.file = ./secrets/mullvad-account.age;
  };

  nixflix = {
    enable = true;

    # MicroVM configuration
    microvm = {
      enable = true;
      hypervisor = "cloud-hypervisor";

      network = {
        bridge = "nixflix-br0";
        subnet = "10.100.0.0/24";
        hostAddress = "10.100.0.1";
      };

      defaults = {
        vcpus = 2;
        memoryMB = 1024;
      };
    };

    # Storage paths
    mediaDir = "/mnt/storage/media";
    downloadsDir = "/mnt/storage/downloads";
    stateDir = "/var/lib/nixflix";

    # PostgreSQL backend
    postgres.enable = true;

    # VPN configuration
    mullvad = {
      enable = true;
      accountNumber = { _secret = config.age.secrets.mullvad-account.path; };
      autoConnect = true;
      location = ["us" "nyc"];
      killSwitch = {
        enable = true;
        allowLan = true;
      };
    };

    # Indexer
    prowlarr = {
      enable = true;
      config = {
        apiKey = { _secret = config.age.secrets.prowlarr-apikey.path; };
        hostConfig = {
          username = "admin";
          password = { _secret = config.age.secrets.prowlarr-apikey.path; };
          urlBase = "/prowlarr";
        };
      };
    };

    # TV Shows
    sonarr = {
      enable = true;
      vpn.enable = false;
      config = {
        apiKey = { _secret = config.age.secrets.sonarr-apikey.path; };
        hostConfig = {
          username = "admin";
          password = { _secret = config.age.secrets.sonarr-apikey.path; };
          urlBase = "/sonarr";
        };
      };
    };

    # Movies
    radarr = {
      enable = true;
      vpn.enable = false;
      config = {
        apiKey = { _secret = config.age.secrets.radarr-apikey.path; };
        hostConfig = {
          username = "admin";
          password = { _secret = config.age.secrets.radarr-apikey.path; };
          urlBase = "/radarr";
        };
      };
    };

    # Music
    lidarr = {
      enable = true;
      vpn.enable = false;
      config = {
        apiKey = { _secret = config.age.secrets.lidarr-apikey.path; };
        hostConfig = {
          username = "admin";
          password = { _secret = config.age.secrets.lidarr-apikey.path; };
          urlBase = "/lidarr";
        };
      };
    };

    # Download client
    sabnzbd = {
      enable = true;
      microvm = {
        vcpus = 4;
        memoryMB = 2048;
      };
      settings.misc = {
        host = "0.0.0.0";
        port = 8080;
        api_key = { _secret = config.age.secrets.sabnzbd-apikey.path; };
        url_base = "/sabnzbd";
      };
    };

    # Media server (on host for GPU)
    jellyfin = {
      enable = true;
      microvm.enable = false;
      encoding = {
        enableHardwareEncoding = true;
        hardwareAccelerationApi = "vaapi";
      };
      network = {
        enableHttps = true;
        baseUrl = "/jellyfin";
      };
    };

    # Request management
    jellyseerr = {
      enable = true;
      apiKey = { _secret = config.age.secrets.jellyseerr-apikey.path; };
    };

    # TRaSH Guides integration
    recyclarr = {
      enable = true;
      sonarr.enable = true;
      radarr.enable = true;
    };

    # Reverse proxy
    nginx.enable = true;

    # Theme
    theme = {
      enable = true;
      name = "nord";
    };

    # Add users to media group
    mediaUsers = [ "alice" "bob" ];
  };

  # System configuration
  users.users = {
    alice.isNormalUser = true;
    bob.isNormalUser = true;
  };

  # Firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 80 443 ];
  };

  # Automatic updates (optional)
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
  };
}
```

## Troubleshooting Example Setups

### Debug Configuration

```nix
{
  nixflix = {
    enable = true;
    microvm.enable = true;

    # Single service for testing
    sonarr = {
      enable = true;
      openFirewall = true;  # For external access
      config.apiKey = { _secret = "/run/secrets/sonarr-apikey"; };
    };
  };

  # Enable logging
  systemd.services."microvm@sonarr" = {
    environment.SYSTEMD_LOG_LEVEL = "debug";
  };
}
```

### Verify Setup Script

```bash
#!/usr/bin/env bash
# verify-microvm-setup.sh

echo "=== Checking MicroVM Services ==="
systemctl list-units 'microvm@*' --state=running

echo -e "\n=== Checking Network ==="
ip addr show nixflix-br0
ip route | grep 10.100.0

echo -e "\n=== Testing Connectivity ==="
for service in sonarr radarr prowlarr; do
    case $service in
        sonarr) ip=10.100.0.10; port=8989 ;;
        radarr) ip=10.100.0.12; port=7878 ;;
        prowlarr) ip=10.100.0.14; port=9696 ;;
    esac
    echo -n "$service ($ip:$port): "
    timeout 2 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null && \
        echo "✓ reachable" || echo "✗ unreachable"
done

echo -e "\n=== Checking Storage (virtiofs via host journal) ==="
journalctl -u microvm@sonarr.service | grep -i 'virtiofs\|mount' | tail -5
```

## See Also

- [MicroVM Documentation](../getting-started/microvm.md) - Complete microVM guide
- [Basic Setup](basic-setup.md) - Standard (non-microVM) setup
- [Reference](../reference/index.md) - All configuration options
