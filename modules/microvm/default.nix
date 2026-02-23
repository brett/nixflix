# Main microVM module for Nixflix
# Provides optional per-service microVM isolation

{ microvm }:
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.nixflix.microvm;
  nixflixCfg = config.nixflix;

  # List of all services that support microVM mode
  supportedServices = [
    "postgres" # Infrastructure service
    "sonarr"
    "sonarr-anime"
    "radarr"
    "lidarr"
    "prowlarr"
    "sabnzbd"
    "jellyfin"
    "jellyseerr"
  ];

  # Filter to only enabled services that have microVM enabled
  enabledMicrovmServices = filter (
    svc: (nixflixCfg.${svc}.enable or false) && (nixflixCfg.${svc}.microvm.enable or cfg.enable)
  ) supportedServices;

  # Map service names to their guest module files
  serviceGuestModules = {
    postgres = ./guests/postgres.nix;
    sonarr = ./guests/arr-service.nix;
    sonarr-anime = ./guests/arr-service.nix;
    radarr = ./guests/arr-service.nix;
    lidarr = ./guests/arr-service.nix;
    prowlarr = ./guests/arr-service.nix;
    sabnzbd = ./guests/sabnzbd.nix;
    jellyfin = ./guests/jellyfin.nix;
    jellyseerr = ./guests/jellyseerr.nix;
  };
in
{
  imports = [
    microvm.nixosModules.host # Import microvm.nix host module
    ./addresses.nix
    ./network.nix
    ./vpn-routing.nix
  ];

  options.nixflix.microvm = {
    enable = mkEnableOption "MicroVM isolation for Nixflix services" // {
      description = ''
        Enable microVM isolation for all Nixflix services.
        Each service runs in its own isolated virtual machine for enhanced security.

        Individual services can override this with `nixflix.<service>.microvm.enable`.
      '';
    };

    hypervisor = mkOption {
      type = types.enum [
        "qemu"
        "cloud-hypervisor"
      ];
      default = "cloud-hypervisor";
      description = ''
        Hypervisor to use for all microVMs.

        - `qemu`: More mature, better tested, slightly higher overhead (has PCI issues with microvm machine type)
        - `cloud-hypervisor`: Lighter weight, faster startup, requires newer kernel, proper virtio support
      '';
    };

    network = {
      bridge = mkOption {
        type = types.str;
        default = "nixflix-br0";
        description = "Name of the bridge interface for microVM networking";
      };

      subnet = mkOption {
        type = types.str;
        default = "10.100.0.0/24";
        description = ''
          Subnet for the microVM network.
          Services will be assigned static IPs within this subnet.
        '';
      };

      hostAddress = mkOption {
        type = types.str;
        default = "10.100.0.1";
        description = "IP address of the host on the microVM bridge";
      };
    };

    defaults = {
      vcpus = mkOption {
        type = types.int;
        default = 2;
        description = "Default number of vCPUs per microVM";
      };

      memoryMB = mkOption {
        type = types.int;
        default = 1024;
        description = "Default memory in MB per microVM";
      };
    };
  };

  config = mkIf (cfg.enable && nixflixCfg.enable) {
    # Ensure required kernel modules are available
    boot.kernelModules = [
      "tun"
      "tap"
      "kvm-intel"
      "kvm-amd"
    ];

    # Enable microvm host support
    microvm.host.enable = true;

    # Configure qemu-bridge-helper to allow our bridge
    environment.etc."qemu/bridge.conf".text = ''
      allow ${cfg.network.bridge}
    '';

    # Generate microvm.vms configuration for each enabled service
    microvm.vms = mkMerge (
      map (serviceName: {
        ${serviceName} = import serviceGuestModules.${serviceName} {
          inherit
            config
            lib
            pkgs
            serviceName
            microvm
            ;
        };
      }) enabledMicrovmServices
    );

    # Assertions to help users
    assertions = [
      {
        assertion = cfg.enable -> (hasAttr "microvm" config && hasAttr "host" config.microvm);
        message = ''
          MicroVM support requires the microvm.nix flake input.
          Please ensure your flake.nix includes:

            inputs.microvm = {
              url = "github:astro/microvm.nix";
              inputs.nixpkgs.follows = "nixpkgs";
            };
        '';
      }
      {
        assertion = !cfg.enable || length enabledMicrovmServices > 0 -> cfg.enable;
        message = ''
          No services are enabled with microVM support.
          Either enable some services or disable nixflix.microvm.enable.
        '';
      }
    ];
  };
}
