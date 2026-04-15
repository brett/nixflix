{ config, lib, ... }:
with lib;
let
  cfg = config.nixflix.microvm;
in
mkIf cfg.enable {
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.useNetworkd = true;

  systemd.network = {
    enable = true;

    netdevs."10-nixflix-br0" = {
      netdevConfig = {
        Kind = "bridge";
        Name = cfg.network.bridge;
      };
    };

    networks."10-nixflix-br0" = {
      matchConfig.Name = cfg.network.bridge;
      address = [ "${cfg.network.hostAddress}/24" ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
      };
    };

    # Attach tap interfaces to the bridge.
    # QEMU creates tap* interfaces; cloud-hypervisor creates vm-* interfaces.
    networks."20-nixflix-tap" = {
      matchConfig.Name = "tap* vm-*";
      networkConfig.Bridge = cfg.network.bridge;
    };
  };

  # VMs use the host bridge IP for DNS. Host-initiated connections (nginx,
  # probes) get return traffic via conntrack — DNS is the only port that needs
  # an explicit INPUT rule.
  networking.firewall.extraInputRules = ''
    ip saddr ${cfg.network.subnet} udp dport 53 accept
    ip saddr ${cfg.network.subnet} tcp dport 53 accept
  '';

  # systemd-resolved's stub listener defaults to 127.0.0.53 only.
  # Add the bridge IP so VMs that send DNS queries to the host get answers.
  services.resolved = {
    enable = true;
    settings.Resolve.DNSStubListenerExtra = cfg.network.hostAddress;
  };

  # Unconditional masquerade works for both plain-internet and VPN (wg0-mullvad) egress.
  networking.nftables = {
    enable = lib.mkDefault true;
    tables.nixflix-microvm-nat = {
      family = "ip";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${cfg.network.subnet} masquerade
        }

        chain forward {
          type filter hook forward priority filter; policy drop;
          ct state established,related accept
          # oifname != bridge allows VM→internet on any egress (direct or wg0-mullvad).
          iifname "${cfg.network.bridge}" oifname != "${cfg.network.bridge}" accept
        }
      '';
    };
  };
}
