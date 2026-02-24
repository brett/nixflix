# MicroVM VPN routing test - Verify nftables configuration for Mullvad bypass
#
# This test verifies that:
# 1. The nixflix-microvm-nat table is created with a masquerade rule
# 2. The nixflix-microvm-vpn table is created for bypass services
# 3. Bypass services (sonarr, prowlarr) have Mullvad bypass marks set
# 4. VPN services (radarr) do NOT have bypass marks
# 5. All services remain accessible regardless of VPN setting
#
# Note: We cannot test actual VPN bypass routing in NixOS test VMs (no real
# Mullvad connection), but we verify the nftables configuration is correct.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
}:

let
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
in
pkgsUnfree.testers.runNixOSTest {
  name = "microvm-vpn-routing";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        qemu.options = [ "-cpu host" ];
      };

      boot.kernelModules = [
        "kvm-intel"
        "kvm-amd"
      ];

      nixflix = {
        enable = true;
        microvm.enable = true;
        microvm.hypervisor = "qemu";

        # Enable Mullvad VPN
        # autoConnect = false so we don't try to reach Mullvad servers in the test
        mullvad.enable = true;
        mullvad.accountNumber = {
          _secret = pkgs.writeText "mullvad-account" "1234567890123456";
        };
        mullvad.autoConnect = false;
        mullvad.killSwitch.enable = true;
        mullvad.killSwitch.allowLan = true;

        # Sonarr with VPN disabled (should get bypass marks)
        sonarr = {
          enable = true;
          vpn.enable = false;
          config = {
            apiKey = {
              _secret = pkgs.writeText "sonarr-apikey" "0123456789abcdef0123456789abcdef";
            };
            hostConfig = {
              instanceName = "Sonarr Test";
              username = "admin";
              password = {
                _secret = pkgs.writeText "sonarr-password" "testpassword";
              };
              authenticationMethod = "forms";
            };
          };
        };

        # Radarr with VPN enabled (should NOT get bypass marks)
        radarr = {
          enable = true;
          vpn.enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "radarr-apikey" "fedcba9876543210fedcba9876543210";
            };
            hostConfig = {
              instanceName = "Radarr Test";
              username = "admin";
              password = {
                _secret = pkgs.writeText "radarr-password" "testpassword";
              };
              authenticationMethod = "forms";
            };
          };
        };

        # Prowlarr with default VPN setting (false → bypass marks)
        prowlarr = {
          enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "prowlarr-apikey" "abcd1234abcd1234abcd1234abcd1234";
            };
            hostConfig = {
              instanceName = "Prowlarr Test";
              username = "admin";
              password = {
                _secret = pkgs.writeText "prowlarr-password" "testpassword";
              };
              authenticationMethod = "forms";
            };
          };
        };
      };
    };

  testScript = ''
    start_all()

    # Create required directories
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{sonarr,radarr,prowlarr}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for Mullvad daemon (even though we won't connect)
    host.wait_for_unit("mullvad-daemon.service", timeout=120)

    # Wait for microVMs
    print("Waiting for microVMs to start...")
    for service in ["sonarr", "radarr", "prowlarr"]:
        host.wait_for_unit(f"microvm@{service}.service", timeout=120)

    print("\n=== Testing NAT Configuration ===")

    # Verify the nixflix-microvm-nat nftables table exists with masquerade
    print("\nVerifying nixflix-microvm-nat table...")
    host.succeed("nft list table ip nixflix-microvm-nat")
    print("  ✓ nixflix-microvm-nat table exists")

    host.succeed("nft list table ip nixflix-microvm-nat | grep masquerade")
    print("  ✓ masquerade rule configured for microVM subnet")

    print("\n=== Testing VPN Bypass nftables Configuration ===")

    # Verify the nixflix-microvm-vpn table exists (bypass services present)
    print("\nVerifying nixflix-microvm-vpn table...")
    host.succeed("nft list table inet nixflix-microvm-vpn")
    print("  ✓ nixflix-microvm-vpn table exists")

    table_contents = host.succeed("nft list table inet nixflix-microvm-vpn")
    print("  Table contents:")
    for line in table_contents.split('\n'):
        if line.strip():
            print(f"    {line}")

    # Verify bypass marks are set for sonarr (vpn.enable = false)
    sonarr_ip = "10.100.0.10"
    assert sonarr_ip in table_contents, \
        f"Expected Sonarr bypass mark rule for {sonarr_ip}, not found in nftables"
    assert "0x00000f41" in table_contents, \
        "Expected Mullvad ct bypass mark 0x00000f41 in nftables table"
    assert "0x6d6f6c65" in table_contents, \
        "Expected Mullvad meta bypass mark 0x6d6f6c65 in nftables table"
    print(f"  ✓ Sonarr bypass mark rules present (IP {sonarr_ip})")

    # Verify bypass marks are set for prowlarr (vpn.enable defaults to false)
    prowlarr_ip = "10.100.0.14"
    assert prowlarr_ip in table_contents, \
        f"Expected Prowlarr bypass mark rule for {prowlarr_ip}, not found in nftables"
    print(f"  ✓ Prowlarr bypass mark rules present (IP {prowlarr_ip})")

    # Verify radarr (vpn.enable = true) does NOT have bypass marks
    radarr_ip = "10.100.0.12"
    assert radarr_ip not in table_contents, \
        f"Radarr (vpn.enable=true) should NOT have bypass mark rules, but found {radarr_ip} in table"
    print(f"  ✓ Radarr correctly excluded from bypass (IP {radarr_ip} not marked)")

    print("\n=== Testing Service Accessibility ===")

    # Verify all services are accessible (VPN setting only affects routing, not reachability)
    service_ports = {
        "sonarr":   ("10.100.0.10", 8989),
        "radarr":   ("10.100.0.12", 7878),
        "prowlarr": ("10.100.0.14", 9696),
    }

    for service, (ip, port) in service_ports.items():
        host.wait_for_open_port(port, ip, timeout=120)
        print(f"  ✓ {service} is accessible at {ip}:{port}")

    print("\n✅ VPN routing configuration test passed!")
    print("   - nixflix-microvm-nat: masquerade configured for microVM subnet")
    print("   - nixflix-microvm-vpn: Mullvad bypass marks (0x00000f41 / 0x6d6f6c65) set for bypass services")
    print("   - Sonarr and Prowlarr correctly marked for VPN bypass")
    print("   - Radarr correctly excluded from bypass (routes through VPN)")
    print("   - All services accessible regardless of VPN routing setting")
  '';
}
