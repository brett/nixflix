# MicroVM guest configuration for Jellyfin

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
  svcCfg = hostConfig.nixflix.jellyfin;
  stateDir = "${hostConfig.nixflix.stateDir}/jellyfin";

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

    # Enable only Jellyfin in the guest
    nixflix = {
      enable = true;
      jellyfin = {
        enable = true;
        # Inherit user config so the admin assertion passes and setup services work
        inherit (svcCfg) users;
        # Inherit network config for consistent port/baseUrl
        network = {
          inherit (svcCfg.network) internalHttpPort internalHttpsPort baseUrl;
        };
      };

      # Use the same directories as the host
      inherit (hostConfig.nixflix) mediaDir downloadsDir stateDir;

      # Copy relevant host configuration
      inherit (hostConfig.nixflix) serviceDependencies;

      # Note: microVM options don't exist in guest since we import nixflix with microvm = null
    };

    # Jellyfin's ExecStartPost (jellyfin-wait-ready) polls until the API is up,
    # which can take several minutes on first boot in nested virtualisation.
    # Override the service timeout so systemd doesn't kill the startup sequence.
    systemd.services.jellyfin.serviceConfig.TimeoutStartSec = mkForce 900;

    # TODO: GPU passthrough for hardware transcoding
    # This would require additional configuration:
    # - Passing through GPU device to microVM
    # - Configuring proper permissions
    # For now, users who need GPU transcoding should disable microVM for Jellyfin:
    # nixflix.jellyfin.microvm.enable = false;

    # Hypervisor selection
    microvm.hypervisor = microvmCfg.hypervisor;

    # vCPUs and memory (Jellyfin may need more resources for transcoding)
    microvm.vcpu = svcCfg.microvm.vcpus or microvmCfg.defaults.vcpus;
    microvm.mem = svcCfg.microvm.memoryMB or microvmCfg.defaults.memoryMB;

    # Network interfaces
    # Use "tap" type; host systemd-networkd auto-attaches TAP to bridge
    microvm.interfaces = [
      {
        type = "tap";
        id = "vm-jellyfin";
        mac = generateMac "jellyfin";
      }
    ];

    # TODO: Device passthrough for GPU
    # microvm.devices = mkIf (svcCfg.encoding.enableHardwareEncoding or false) [
    #   {
    #     bus = "pci";
    #     path = "/sys/devices/..."; # Would need to be configurable
    #   }
    # ];
  };
}
