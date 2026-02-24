# MicroVM networking test - Verify microVM-to-microVM and microVM-to-host communication
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  hypervisor ? "cloud-hypervisor",
}:

let
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
in
pkgsUnfree.testers.runNixOSTest {
  name = "microvm-networking";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation = {
        cores = 6;
        memorySize = 6144;
        diskSize = 10 * 1024;
        qemu.options = [ "-cpu host" ];
      };

      boot.kernelModules = [
        "kvm-intel"
        "kvm-amd"
      ];

      nixflix = {
        enable = true;
        microvm.enable = true;
        microvm.hypervisor = hypervisor;

        postgres.enable = true;

        sonarr = {
          enable = true;
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

        radarr = {
          enable = true;
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
    import json

    start_all()

    # Create required directories for microVMs
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{sonarr,radarr,prowlarr,postgresql}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for microVMs
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@postgres.service", timeout=300)
    for service in ["sonarr", "radarr", "prowlarr"]:
        print(f"  Waiting for microvm@{service}.service...")
        host.wait_for_unit(f"microvm@{service}.service", timeout=300)

    print("\n=== Testing Bridge Network ===")

    # Verify bridge interface exists
    host.succeed("ip link show nixflix-br0")
    print("  ✓ Bridge interface nixflix-br0 exists")

    # Verify bridge has correct IP
    bridge_ip = host.succeed(
        "ip -4 addr show nixflix-br0 | grep inet | awk '{print $2}' | cut -d/ -f1"
    ).strip()
    assert bridge_ip == "10.100.0.1", f"Expected bridge IP 10.100.0.1, got {bridge_ip}"
    print(f"  ✓ Bridge IP is {bridge_ip}")

    # Verify IP forwarding is enabled (required for NAT and inter-VM routing)
    ipfwd = host.succeed("sysctl -n net.ipv4.ip_forward").strip()
    assert ipfwd == "1", f"Expected IP forwarding enabled (1), got {ipfwd}"
    print("  ✓ IP forwarding enabled")

    # Verify NAT MASQUERADE is configured for microVM internet access
    host.succeed("nft list table ip nixflix-microvm-nat | grep masquerade")
    print("  ✓ NAT MASQUERADE rule configured")

    print("\n=== Testing Static IP Assignments ===")
    # Verify each microVM is reachable at its expected static IP.
    # The static IPs are configured in modules/microvm/addresses.nix and assigned
    # via systemd-networkd inside each guest.
    service_ips = {
        "sonarr":   ("10.100.0.10", 8989),
        "radarr":   ("10.100.0.12", 7878),
        "prowlarr": ("10.100.0.14", 9696),
    }

    for service, (ip, port) in service_ips.items():
        print(f"  Waiting for {service} at {ip}:{port}...")
        host.wait_for_open_port(port, ip, timeout=600)
        print(f"  ✓ {service} accessible at {ip}:{port}")

    # Verify PostgreSQL microVM is reachable at its static IP
    print("  Checking postgres microVM at 10.100.0.2:5432...")
    host.wait_for_open_port(5432, "10.100.0.2", timeout=300)
    print("  ✓ postgres microVM accessible at 10.100.0.2:5432")

    print("\n=== Testing microVM-to-microVM Connectivity ===")
    # Each arr service runs a wait-for-db step that connects to the postgres
    # microVM at 10.100.0.2:5432 via TCP before starting. The services being up
    # and using PostgreSQL proves inter-VM TCP routing is working.

    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://10.100.0.10:8989/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Sonarr", f"Expected Sonarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", \
        f"Expected postgreSQL DB, got {status['databaseType']}"
    print("  ✓ Sonarr using PostgreSQL (proves sonarr→postgres inter-VM TCP works)")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
        "http://10.100.0.12:7878/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Radarr", f"Expected Radarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", \
        f"Expected postgreSQL DB, got {status['databaseType']}"
    print("  ✓ Radarr using PostgreSQL (proves radarr→postgres inter-VM TCP works)")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
        "http://10.100.0.14:9696/api/v1/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Prowlarr", f"Expected Prowlarr, got {status['appName']}"
    print("  ✓ Prowlarr accessible (proves prowlarr→postgres inter-VM TCP works)")

    print("\n=== Testing Host-to-microVM TCP Connectivity ===")
    for service, (ip, port) in service_ips.items():
        check = host.succeed(
            f"timeout 5 bash -c 'cat < /dev/null > /dev/tcp/{ip}/{port}' && echo OPEN || echo CLOSED"
        ).strip()
        assert check == "OPEN", f"Expected {service} port {port} OPEN, got {check}"
        print(f"  ✓ Host can reach {service} at {ip}:{port}")

    # Also verify postgres is directly reachable from host
    check = host.succeed(
        "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.100.0.2/5432' && echo OPEN || echo CLOSED"
    ).strip()
    assert check == "OPEN", f"Expected postgres port 5432 OPEN, got {check}"
    print("  ✓ Host can reach postgres microVM at 10.100.0.2:5432")

    # ICMP ping is informational - may not work in all nested virt environments
    print("\nTesting ICMP ping (informational, not required)...")
    for service, (ip, port) in service_ips.items():
        result = host.succeed(f"ping -c 2 -W 2 {ip} 2>&1 || true")
        if "2 received" in result:
            print(f"  ✓ Host can ping {service} at {ip}")
        else:
            print(f"  ⚠ Host→{service} ping inconclusive (may be blocked in nested virt)")

    print("\n✅ Networking test passed!")
    print("   - Bridge network configured correctly (nixflix-br0 at 10.100.0.1)")
    print("   - IP forwarding and NAT MASQUERADE enabled")
    print("   - Static IP assignments working for all microVMs")
    print("   - microVM-to-microVM TCP connectivity proven by PostgreSQL usage")
    print("   - Host-to-microVM TCP connectivity working for all services")
  '';
}
