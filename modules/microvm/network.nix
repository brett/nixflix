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

    # NAT configuration for internet access
    # When Mullvad is enabled, this routes microVM traffic through the VPN
    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.network.bridge ];

      # Use the primary external interface
      # If Mullvad is enabled, this will be the wg0-mullvad interface
      # Otherwise, use the default gateway interface
      externalInterface =
        if nixflixCfg.mullvad.enable or false then
          "wg0-mullvad"
        else
          # Try to detect the default route interface
          # This is a fallback - users should configure this explicitly if needed
          mkDefault "eth0";
    };

    # Firewall configuration
    networking.firewall = {
      # Trust the microVM bridge - allow all traffic between host and guests
      trustedInterfaces = [ cfg.network.bridge ];

      # Allow forwarding for NAT
      extraCommands = ''
        # Determine external interface
        EXT_IF="${if nixflixCfg.mullvad.enable or false then "wg0-mullvad" else "eth0"}"

        # Allow forwarding from bridge to external interface
        iptables -A FORWARD -i ${cfg.network.bridge} -j ACCEPT
        iptables -A FORWARD -o ${cfg.network.bridge} -m state --state RELATED,ESTABLISHED -j ACCEPT

        # Add MASQUERADE rule for NAT (this is what was missing!)
        iptables -t nat -A POSTROUTING -s ${cfg.network.subnet} -o $EXT_IF -j MASQUERADE
      '';

      extraStopCommands = ''
        EXT_IF="${if nixflixCfg.mullvad.enable or false then "wg0-mullvad" else "eth0"}"

        iptables -D FORWARD -i ${cfg.network.bridge} -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o ${cfg.network.bridge} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s ${cfg.network.subnet} -o $EXT_IF -j MASQUERADE 2>/dev/null || true
      '';
    };

    # Enable IP forwarding (required for NAT)
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 0; # Disable IPv6 forwarding for now
    };
  };
}
