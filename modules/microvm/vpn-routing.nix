# VPN routing configuration for microVM traffic
# Controls which microVMs route through Mullvad VPN vs bypass it
#
# Strategy: piggyback on Mullvad's own bypass routing infrastructure.
# Setting ct mark 0x00000f41 + meta mark 0x6d6f6c65 causes Mullvad to route
# matching packets through its bypass table (same mechanism used by mullvad-exclude
# for processes and by Tailscale integration — see mullvad.nix for examples).
# No custom routing tables or ip rules are needed.

{ config, lib, ... }:

with lib;

let
  cfg = config.nixflix.microvm;
  nixflixCfg = config.nixflix;

  # Services that support microVM mode
  supportedServices = [
    "sonarr"
    "sonarr-anime"
    "radarr"
    "lidarr"
    "prowlarr"
    "sabnzbd"
    "jellyfin"
    "jellyseerr"
  ];

  # Build list of enabled microVM services with their VPN settings
  microvmServices = filter (
    svc: (nixflixCfg.${svc}.enable or false) && (nixflixCfg.${svc}.microvm.enable or cfg.enable)
  ) supportedServices;

  # Services that should bypass VPN (vpn.enable = false, the default for *arr services)
  bypassServices = filter (svc: !(nixflixCfg.${svc}.vpn.enable or false)) microvmServices;
in
{
  config = mkIf (cfg.enable && nixflixCfg.mullvad.enable) {
    networking.nftables = {
      enable = mkDefault true;
      tables.nixflix-microvm-vpn = mkIf (length bypassServices > 0) {
        family = "inet";
        content = ''
          # Mark packets from bypass-VPN microVMs with Mullvad's bypass marks.
          # Priority -150 runs before Mullvad's own mangle rules (priority -100).
          chain prerouting {
            type filter hook prerouting priority -150; policy accept;

            ${concatMapStringsSep "\n" (svc: ''
              # ${svc}: bypass VPN
              ip saddr ${nixflixCfg.${svc}.microvm.address} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            '') bypassServices}
          }

          # Also mark return traffic to bypass-VPN VMs so reply packets don't
          # get reinjected into the VPN tunnel.
          chain output {
            type route hook output priority -150; policy accept;

            ${concatMapStringsSep "\n" (svc: ''
              # ${svc}: bypass VPN (return path)
              ip daddr ${nixflixCfg.${svc}.microvm.address} ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            '') bypassServices}
          }
        '';
      };
    };
  };
}
