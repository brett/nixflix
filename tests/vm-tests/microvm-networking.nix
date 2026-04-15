# MicroVM networking test: bridge created, NAT rules correct, tap attaches to
# bridge, and actual host-to-VM TCP connectivity works.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-networking-skip" { } ''
    echo "microvm-networking: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-networking-test";

    nodes.machine =
      { pkgs, ... }:
      {
        # dig: verify DNS queries to the bridge IP get responses
        environment.systemPackages = [ pkgs.dnsutils ];

        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 3;
        virtualisation.memorySize = 3072;

        nixflix = {
          enable = true;

          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
            network = {
              bridge = "nixflix-br0";
              subnet = "10.100.0.0/24";
              hostAddress = "10.100.0.1";
            };
          };

          postgres = {
            enable = true;
            microvm.enable = true;
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed("mkdir -p /data/.state/postgres /data/media /data/downloads")

      # --- Host-side network infrastructure ---

      # Bridge must exist with the configured host address
      machine.wait_until_succeeds(
          "ip addr show nixflix-br0 | grep '10.100.0.1'",
          timeout=60
      )

      # IP forwarding must be enabled for VM egress
      machine.succeed("cat /proc/sys/net/ipv4/ip_forward | grep -q 1")

      # NAT table must exist with masquerade and forward rules
      result = machine.succeed("nft list table ip nixflix-microvm-nat")
      assert "masquerade" in result, "NAT masquerade rule not found in nixflix-microvm-nat"
      assert "nixflix-br0" in result, "Bridge forward rule not found in nixflix-microvm-nat"
      assert "10.100.0.0/24" in result, "Subnet not found in NAT postrouting rule"

      # --- DNS resolver on host bridge IP ---

      # network.nix enables resolved unconditionally when microvm is enabled
      machine.wait_for_unit("systemd-resolved.service", timeout=60)

      # DNSStubListenerExtra must bind the stub to the bridge IP (UDP port 53).
      # VMs set DNS=10.100.0.1; if nothing listens here their DNS is broken.
      machine.wait_until_succeeds(
          "ss -lnuH src 10.100.0.1:53 | grep -q .",
          timeout=30
      )

      # Confirm the stub actually answers DNS queries.
      # 'localhost' is synthesised from /etc/hosts — no upstream DNS needed.
      machine.succeed("dig +short @10.100.0.1 localhost | grep -q 127.0.0.1")

      print("DNS resolver on bridge IP verified")

      # --- VM startup and tap attachment ---

      machine.wait_for_unit("microvm@postgres.service", timeout=600)

      # networkd's "tap* vm-*" match rule attaches tap interfaces to the bridge automatically.
      machine.wait_until_succeeds(
          "bridge link show | grep -q vm-postgres",
          timeout=60
      )

      # --- Actual host-to-VM connectivity ---

      # ICMP reachability proves bridge/tap/routing are working at IP level.
      machine.succeed("ping -c 3 -W 2 10.100.0.2")

      # The postgres VM firewall allows port 5432 from service VM IPs and the host bridge.
      machine.succeed("bash -c 'echo >/dev/tcp/10.100.0.2/5432'")

      print("microvm-networking: bridge, NAT, tap attachment, IP reachability, DNS resolver, and postgres firewall all verified")
    '';
  }
