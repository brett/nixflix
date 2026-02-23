---
title: Getting Started
---

# Getting Started

This guide shows how to add Nixflix to your NixOS configuration using flakes.

## Prerequisites

- NixOS with flakes enabled
- Git for version control
- Basic familiarity with NixOS modules
- Some form of secrets management, like [sops-nix](https://github.com/Mic92/sops-nix)
- **(Optional)** Hardware virtualization support (KVM) if using microVM isolation

## Enable Flakes

If you haven't already enabled flakes, add this to your configuration:

```nix
{
  nix.settings.experimental-features = ["nix-command" "flakes"];
}
```

## Adding Nixflix to Your Flake

Add Nixflix as an input to your `flake.nix`:

```nix
{
  description = "My NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixflix = {
      url = "github:kiriwalawren/nixflix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixflix,
    ...
  }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        nixflix.nixosModules.default
      ];
    };
  };
}
```

## Choosing Your Deployment Mode

Nixflix supports two deployment modes. Choose one before your initial configuration:

### Standard Deployment

Services run directly on your host system.

**Use when:**

- You want the simplest setup with lowest overhead
- You need GPU passthrough for Jellyfin hardware transcoding
- Your system doesn't support hardware virtualization
- You're running on resource-constrained hardware

**Pros:** Simple, lower resource usage, direct GPU access
**Cons:** Services share the same system, no resource isolation

### MicroVM Deployment (Beta)

Each service runs in its own lightweight virtual machine.

**Use when:**

- You want enhanced security through service isolation
- You need resource limits per service (CPU/memory caps)
- You're running on a powerful system with virtualization support
- You want to experiment with different configurations safely

**Pros:** Strong isolation, resource limits, safer experimentation
**Cons:** Higher resource usage, no GPU passthrough (yet), requires KVM

**Check KVM support:**
```bash
# Check if your CPU supports virtualization
grep -E 'vmx|svm' /proc/cpuinfo

# If nothing is returned, enable VT-x/AMD-V in your BIOS
```

!!! tip "Easy to Switch"
    You can switch between modes later by toggling `nixflix.microvm.enable` and rebuilding. Your service configurations remain the same.

## Configuration Examples

Choose the deployment mode that fits your needs:

=== "Standard Deployment"

    ```nix
    {
      nixflix = {
        enable = true;

        # Directory configuration
        mediaDir = "/data/media";
        stateDir = "/data/.state";

        # Optional features
        nginx.enable = true;      # Reverse proxy for all services
        postgres.enable = true;   # Shared database for Arr services

        # Media management services
        sonarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."sonarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."sonarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        radarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."radarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."radarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        prowlarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."prowlarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."prowlarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        # Download client
        sabnzbd = {
          enable = true;
          settings.misc = {
            api_key = {_secret = config.sops.secrets."sabnzbd/api_key".path;};
            nzb_key = {_secret = config.sops.secrets."sabnzbd/nzb_key".path;};
          };
        };

        # Media server
        jellyfin = {
          enable = true;
          users.admin = {
            policy.isAdministrator = true;
            password = {_secret = config.sops.secrets."jellyfin/admin_password".path;};
          };
        };
      };
    }
    ```

=== "MicroVM Deployment"

    ```nix
    {
      nixflix = {
        enable = true;

        # Enable microVM isolation
        microvm = {
          enable = true;
          hypervisor = "qemu";  # or "cloud-hypervisor"

          # Optional: customize network (these are defaults)
          network = {
            bridge = "nixflix-br0";
            subnet = "10.100.0.0/24";
            hostAddress = "10.100.0.1";
          };

          # Optional: customize default resources
          defaults = {
            vcpus = 2;
            memoryMB = 1024;
          };
        };

        # Directory configuration (same as standard)
        mediaDir = "/data/media";
        stateDir = "/data/.state";

        # Optional features (PostgreSQL runs on host, services connect via network)
        nginx.enable = true;
        postgres.enable = true;

        # Service configuration is identical to standard deployment
        sonarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."sonarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."sonarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        radarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."radarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."radarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        prowlarr = {
          enable = true;
          config = {
            apiKey = {_secret = config.sops.secrets."prowlarr/api_key".path;};
            hostConfig = {
              username = "admin";
              password = {_secret = config.sops.secrets."radarr/password".path;};
              authenticationMethod = "forms";
            };
          };
        };

        sabnzbd = {
          enable = true;
          settings.misc = {
            api_key = {_secret = config.sops.secrets."sabnzbd/api_key".path;};
            nzb_key = {_secret = config.sops.secrets."sabnzbd/nzb_key".path;};
          };
        };

        # Example: Disable microVM for Jellyfin to use GPU transcoding
        jellyfin = {
          enable = true;
          microvm.enable = false;  # Runs on host for GPU access
          users.admin = {
            policy.isAdministrator = true;
            password = {_secret = config.sops.secrets."jellyfin/admin_password".path;};
          };
        };
      };
    }
    ```

=== "Hybrid Deployment"

    Mix microVM and standard deployment based on your needs:

    ```nix
    {
      nixflix = {
        enable = true;

        # Enable microVM by default
        microvm.enable = true;
        microvm.hypervisor = "qemu";

        mediaDir = "/data/media";
        stateDir = "/data/.state";
        nginx.enable = true;
        postgres.enable = true;

        # These run in microVMs (isolated)
        sonarr.enable = true;
        radarr.enable = true;
        prowlarr.enable = true;
        sabnzbd.enable = true;

        # Jellyfin runs on host for GPU transcoding
        jellyfin = {
          enable = true;
          microvm.enable = false;  # Override: run on host
          users.admin = {
            policy.isAdministrator = true;
            password = {_secret = config.sops.secrets."jellyfin/admin_password".path;};
          };
        };

        # Jellyseerr also on host (lighter service, doesn't need isolation)
        jellyseerr = {
          enable = true;
          microvm.enable = false;
          apiKey = {_secret = config.sops.secrets."jellyseerr/api_key".path;};
        };
      };
    }
    ```

## Next Steps

- Review the [Basic Setup Example](../examples/basic-setup.md) for a complete configuration
- **If using microVMs:** Read the [MicroVM Guide](microvm.md) for advanced configuration
- See the [Options Reference](../reference/index.md) for all available settings
- Learn about [Secrets Management](../examples/secrets.md) for API keys and passwords
