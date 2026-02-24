# Bridge network configuration for microVM host
# Sets up bridge interface, NAT, and firewall rules using systemd-networkd

{ config, lib, ... }:

with lib;

let
  cfg = config.nixflix.microvm;
  nixflixCfg = config.nixflix;
in
{
  config = mkIf cfg.enable {
    # Use systemd-networkd just for bridge and tap interfaces
    systemd.network.enable = true;

    # Create bridge interface using systemd-networkd
    systemd.network.netdevs."20-${cfg.network.bridge}".netdevConfig = {
      Kind = "bridge";
      Name = cfg.network.bridge;
    };

    # Configure bridge IP and settings
    systemd.network.networks."20-${cfg.network.bridge}" = {
      matchConfig.Name = cfg.network.bridge;
      addresses = [
        { Address = "${cfg.network.hostAddress}/24"; }
      ];
      networkConfig = {
        # Allow bridge to come up without any ports attached
        ConfigureWithoutCarrier = true;
      };
    };

    # CRITICAL: Auto-attach TAP interfaces to bridge
    # Match any tap interface (tap*, vm-*, etc.)
    systemd.network.networks."21-microvm-tap" = {
      matchConfig.Name = "tap* vm-*";
      networkConfig.Bridge = cfg.network.bridge;
    };

    # NAT and forwarding for microVM internet access using nftables.
    # Unconditional masquerade (no oifname filter) handles both the plain-internet
    # path (default route) and the Mullvad VPN path (wg0-mullvad) transparently —
    # the kernel picks the correct source address based on which interface is used.
    # VPN bypass traffic is marked by vpn-routing.nix so Mullvad routes it outside
    # the tunnel without any extra routing tables needed here.
    networking.nftables = {
      enable = mkDefault true;
      tables.nixflix-microvm-nat = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            ip saddr ${cfg.network.subnet} masquerade
          }

          chain forward {
            type filter hook forward priority filter; policy accept;
            iifname "${cfg.network.bridge}" accept
            oifname "${cfg.network.bridge}" ct state established,related accept
          }
        '';
      };
    };

    # Trust the microVM bridge so the host can reach guests
    networking.firewall.trustedInterfaces = [ cfg.network.bridge ];

    # Enable IP forwarding (required for NAT)
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 0; # Disable IPv6 forwarding for now
    };
  };
}
