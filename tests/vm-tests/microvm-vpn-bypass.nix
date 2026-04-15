# MicroVM VPN bypass test: nftables marks are present for VM subnet traffic.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-vpn-bypass-skip" { } ''
    echo "microvm-vpn-bypass: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-vpn-bypass-test";

    nodes.machine =
      { lib, pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 2;
        virtualisation.memorySize = 2048;

        nixflix = {
          enable = true;
          mullvad = {
            enable = true;
            accountNumber = "0000000000000000";
          };
          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
          };
          postgres = {
            enable = true;
            microvm.enable = true;
          };
          torrentClients.qbittorrent = {
            enable = true;
            microvm.enable = true;
            password = {
              _secret = pkgs.writeText "qbit-password" "testpassword123";
            };
          };
        };

        # Mock mullvad daemon (not available in test)
        systemd.services.mullvad-daemon.enable = lib.mkForce false;
        systemd.services.mullvad-config.enable = lib.mkForce false;
        services.mullvad-vpn.enable = lib.mkForce false;
      };

    testScript = ''
      start_all()

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("nftables.service")

      result = machine.succeed("nft list table ip nixflix-microvm-vpn-bypass")
      assert "0x00000f41" in result, "Mullvad bypass ct mark not found"
      assert "0x6d6f6c65" in result, "Mullvad bypass meta mark not found"
      assert "prerouting" in result, "Bypass marks not in prerouting chain"

      # Rules are per-VM IP. Postgres has vpnBypass = true (explicit), so it appears.
      # Default is vpnBypass = false, matching the non-microVM mullvad-exclude opt-out model.
      assert "10.100.0.2" in result, "Postgres VM IP not found in bypass rules (vpnBypass = true)"

      # The prerouting chain uses per-VM IPs; the output chain uses the subnet so that
      # host-originated traffic (nginx, etc.) can reach microVM services through Mullvad.
      prerouting = result.split("chain prerouting")[1].split("}")[0] if "chain prerouting" in result else ""
      assert "10.100.0.0/24" not in prerouting, (
          "Subnet-wide bypass rule found in prerouting — must be per-VM IP"
      )

      # qBittorrent has vpnBypass = false (routes through VPN); must not appear in prerouting.
      assert "10.100.0.21" not in prerouting, (
          "qBittorrent IP 10.100.0.21 found in prerouting bypass rules — should be excluded (vpnBypass=false)"
      )

      print("microvm-vpn-bypass: per-VM Mullvad bypass marks correctly configured")
    '';
  }
