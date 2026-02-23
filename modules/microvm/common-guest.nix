# Common guest configuration shared across all microVMs
# Provides: users/groups, virtiofs mounts, networking, minimal system config

# This is a function that takes custom arguments and returns a NixOS module
{
  hostConfig, # Host configuration passed from guest module
  serviceName,
}:

# Return a NixOS module
{ lib, pkgs, ... }:

with lib;

let
  # Use hostConfig to access host's nixflix configuration
  inherit (hostConfig.nixflix) globals;
  microvmCfg = hostConfig.nixflix.microvm;

  # Get service-specific config
  svcCfg = hostConfig.nixflix.${serviceName};
  stateDir = "${hostConfig.nixflix.stateDir}/${serviceName}";

  # Get IP address for this service
  serviceAddress = microvmCfg.addresses.${serviceName};
in
{
  # Basic system configuration
  system.stateVersion = "24.11";
  networking.hostName = serviceName;

  # Minimal package set
  environment.systemPackages = with pkgs; [
    curl
    jq
  ];

  # User and group configuration with fixed UIDs/GIDs.
  # In microVM guests, all services run under their own user but the shared
  # "media" group, so they can all read/write shared media and downloads dirs.
  users =
    let
      userName = svcCfg.user or serviceName;
    in
    {
      # Create users
      users = {
        ${userName} = {
          isSystemUser = true;
          group = "media";
          home = mkDefault stateDir;
        }
        // optionalAttrs (hasAttr userName globals.uids) { uid = globals.uids.${userName}; };

        # Create root user (required for system)
        root = {
          uid = 0;
          group = "root";
          home = "/root";
        };
      };

      # Create groups
      groups = {
        # Shared media group with fixed GID — all services use this as primary group
        media.gid = globals.gids.media;

        # Root group
        root.gid = 0;
      };
    };

  # virtiofs mounts for shared storage
  microvm.shares = [
    # Media directory (shared across all services)
    {
      source = hostConfig.nixflix.mediaDir;
      mountPoint = hostConfig.nixflix.mediaDir;
      tag = "media";
      proto = "virtiofs";
    }
    # Downloads directory (shared across all services)
    {
      source = hostConfig.nixflix.downloadsDir;
      mountPoint = hostConfig.nixflix.downloadsDir;
      tag = "downloads";
      proto = "virtiofs";
    }
    # Service-specific state directory
    {
      source = stateDir;
      mountPoint = stateDir;
      tag = "state";
      proto = "virtiofs";
    }
  ];

  # Network configuration
  # Use mkForce to override defaults and prevent dhcpcd conflicts
  networking = {
    useDHCP = mkForce false; # Disable dhcpcd
    useNetworkd = mkForce true; # Use systemd-networkd exclusively
    firewall.enable = false; # Host firewall handles security
    # Disable predictable interface names so the interface is always eth0.
    # Required because virtiofs shares cause requirePci=true in microvm.nix,
    # meaning the network device is virtio-net-pci, which would otherwise get
    # a predictable name like enp0s3 that doesn't match our networkd config.
    usePredictableInterfaceNames = false;
  };

  systemd.network = {
    enable = true;
    networks."10-eth0" = {
      matchConfig.Name = "eth0";
      address = [
        "${serviceAddress}/24"
      ];
      gateway = [ microvmCfg.network.hostAddress ];
      dns = [
        "1.1.1.1"
        "8.8.8.8"
      ];
      networkConfig = {
        IPv6AcceptRA = false;
        DHCP = "no";
      };
    };
  };

  # Minimal systemd configuration
  systemd.settings.Manager.DefaultTimeoutStartSec = "900s";
}
