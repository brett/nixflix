{ config, lib, ... }:
with lib;
let
  cfg = config.nixflix.microvm;

  # VMs default to vpnBypass = false (route through VPN), matching the non-microVM
  # mullvad-exclude opt-out model. Services that must reach the internet set vpnBypass = true.
  bypassAddresses = mapAttrsToList (_name: vmCfg: vmCfg.address) (
    filterAttrs (
      _name: vmCfg: vmCfg.vpnBypass or false
    ) config.nixflix.globals.microVMHostConfigurations
  );
in
# Marks 0x00000f41 / 0x6d6f6c65 match Mullvad's per-app exclude mechanism.
mkIf (cfg.enable && config.nixflix.mullvad.enable && bypassAddresses != [ ]) {
  networking.nftables.tables.nixflix-microvm-vpn-bypass = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority -100; policy accept;
        ${concatMapStrings (addr: ''
          ip saddr ${addr} ct mark set 0x00000f41;
          ip saddr ${addr} meta mark set 0x6d6f6c65;
        '') bypassAddresses}
      }

      # Mark host-originated traffic to the bridge subnet with the Mullvad bypass
      # mark so that nginx and other host processes can reach microVM services.
      # Without this, Mullvad's policy routing (ip rule: not fwmark → VPN table)
      # drops packets destined for 10.100.0.0/24 since that subnet is not in the
      # VPN routing table.
      chain output {
        type route hook output priority mangle; policy accept;
        ip daddr ${cfg.network.subnet} ct mark set 0x00000f41;
        ip daddr ${cfg.network.subnet} meta mark set 0x6d6f6c65;
      }
    '';
  };
}
