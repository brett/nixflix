# VPN routing configuration for microVM traffic
# Controls which microVMs route through Mullvad VPN vs bypass it

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

  # Services that should bypass VPN (vpn.enable = false)
  bypassServices = filter (svc: !(nixflixCfg.${svc}.vpn.enable or false)) microvmServices;

  # Services that should route through VPN (vpn.enable = true)
in
{
  config = mkIf (cfg.enable && nixflixCfg.mullvad.enable) {
    # Note: VPN routing for microVMs is handled at the NAT level
    # All microVM traffic goes through the host's NAT, which then
    # routes to either the VPN interface or the default gateway
    # based on routing rules.

    # Since Mullvad creates a VPN interface (wg0-mullvad) and sets
    # it as the default route, traffic from microVMs will automatically
    # go through the VPN unless we explicitly mark it for bypass.

    # For VPN bypass, we need to:
    # 1. Mark packets from bypass services
    # 2. Route marked packets through the non-VPN interface

    networking.nftables = {
      enable = mkDefault true;
      tables.nixflix-microvm-vpn = mkIf (length bypassServices > 0) {
        family = "inet";
        content = ''
          # Mangle table for marking packets that should bypass VPN
          chain prerouting {
            type filter hook prerouting priority mangle; policy accept;

            ${concatMapStringsSep "\n" (svc: ''
              # ${svc}: bypass VPN
              ip saddr ${nixflixCfg.${svc}.microvm.address} mark set 0x1
            '') bypassServices}
          }

          chain postrouting {
            type filter hook postrouting priority mangle; policy accept;
          }
        '';
      };
    };

    # Add routing policy for marked packets to bypass VPN
    # This requires setting up a separate routing table
    networking.iproute2.enable = true;

    # TODO: The complete VPN bypass implementation requires:
    # 1. A separate routing table for non-VPN routes
    # 2. IP rules to direct marked packets to that table
    # 3. Routes in that table to use the non-VPN interface
    #
    # This is left as a future enhancement. For now, all microVM
    # traffic will route through the VPN when Mullvad is enabled.
    # Users who need VPN bypass for specific services should either:
    # - Disable microVM for those services (they'll use mullvad-exclude on host)
    # - Or disable Mullvad entirely
  };
}
