# MicroVM guest configuration for SABnzbd

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
  svcCfg = hostConfig.nixflix.sabnzbd;
  stateDir = "${hostConfig.nixflix.stateDir}/sabnzbd";

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

    # Enable only SABnzbd in the guest
    nixflix = {
      enable = true;
      sabnzbd = {
        enable = true;
        # Inherit service configuration from host, filtering out null values.
        # Override host to 0.0.0.0 so SABnzbd is reachable from outside the VM.
        settings = lib.recursiveUpdate (lib.filterAttrsRecursive (_: v: v != null) (
          svcCfg.settings or { }
        )) { misc.host = "0.0.0.0"; };
      };

      # Use the same directories as the host
      inherit (hostConfig.nixflix) mediaDir downloadsDir stateDir;

      # Copy relevant host configuration
      inherit (hostConfig.nixflix) serviceDependencies;

      # Note: microVM options don't exist in guest since we import nixflix with microvm = null
    };

    # SABnzbd doesn't use PostgreSQL, so no database config needed

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
        id = "vm-sabnzbd";
        mac = generateMac "sabnzbd";
      }
    ];
  };
}
