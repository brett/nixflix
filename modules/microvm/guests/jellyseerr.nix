# MicroVM guest configuration for Jellyseerr

{
  config,
  lib,
  serviceName,
  ...
}:

with lib;

let
  # Host config
  hostConfig = config;
  microvmCfg = hostConfig.nixflix.microvm;
  svcCfg = hostConfig.nixflix.jellyseerr;
  stateDir = "${hostConfig.nixflix.stateDir}/jellyseerr";

  # Generate MAC address deterministically
  generateMac =
    name:
    let
      hash = builtins.hashString "sha256" name;
      macSuffix = substring 0 10 hash;
    in
    "02:00:00:${substring 0 2 macSuffix}:${substring 2 2 macSuffix}:${substring 4 2 macSuffix}";
in
{
  # MicroVM configuration
  autostart = true;
  restartIfChanged = true;

  config = {
    imports = [
      # Import the main nixflix module
      (import ../../default.nix { microvm = null; })

      # Import common guest configuration
      (import ../common-guest.nix {
        hostConfig = config;
        inherit serviceName;
      })
    ];

    # Enable only Jellyseerr in the guest
    nixflix = {
      enable = true;
      jellyseerr = {
        enable = true;
        inherit (svcCfg) user;
        group = "media";
        # Inherit API key and port from host so the service starts correctly
        inherit (svcCfg) apiKey port;
      };

      # Use the same directories as the host
      inherit (hostConfig.nixflix) mediaDir downloadsDir stateDir;

      # Copy relevant host configuration
      inherit (hostConfig.nixflix) serviceDependencies;

      # Note: microVM options don't exist in guest since we import nixflix with microvm = null
    };

    # Hypervisor selection
    microvm.hypervisor = microvmCfg.hypervisor;

    # vCPUs and memory
    microvm.vcpu = svcCfg.microvm.vcpus or microvmCfg.defaults.vcpus;
    microvm.mem = svcCfg.microvm.memoryMB or microvmCfg.defaults.memoryMB;

    # Network interfaces
    # Use "tap" type; host systemd-networkd auto-attaches TAP to bridge
    microvm.interfaces = [
      {
        type = "tap";
        id = "vm-jellyseerr";
        mac = generateMac "jellyseerr";
      }
    ];
  };
}
