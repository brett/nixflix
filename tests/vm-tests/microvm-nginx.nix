# MicroVM + nginx test - Verify nginx reverse proxy correctly routes to microVM services
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
  name = "microvm-nginx";

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
        nginx.enable = true;

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

        sabnzbd = {
          enable = true;
          downloadsDir = "/data/downloads/usenet";
          settings = {
            misc = {
              api_key = {
                _secret = pkgs.writeText "sabnzbd-apikey" "2222222222222222222222222222222";
              };
              nzb_key = {
                _secret = pkgs.writeText "sabnzbd-nzbkey" "3333333333333333333333333333333";
              };
              port = 8080;
              # Note: host defaults to 127.0.0.1 but guest config overrides to 0.0.0.0
              url_base = "/sabnzbd";
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
    host.succeed("mkdir -p /data/.state/{sonarr,radarr,prowlarr,sabnzbd,postgresql}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for nginx to start
    host.wait_for_unit("nginx.service", timeout=60)
    host.wait_for_open_port(80, timeout=60)
    print("  ✓ nginx started and listening on port 80")

    # Wait for microVMs
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@postgres.service", timeout=300)
    for service in ["sonarr", "radarr", "prowlarr", "sabnzbd"]:
        print(f"  Waiting for microvm@{service}.service...")
        host.wait_for_unit(f"microvm@{service}.service", timeout=300)

    # Wait for services to be reachable directly (proves VMs have networking)
    print("\n=== Waiting for services to start in microVMs ===")
    service_ips = {
        "sonarr":   ("10.100.0.10", 8989),
        "radarr":   ("10.100.0.12", 7878),
        "prowlarr": ("10.100.0.14", 9696),
        "sabnzbd":  ("10.100.0.20", 8080),
    }
    for service, (ip, port) in service_ips.items():
        print(f"  Waiting for {service} at {ip}:{port}...")
        host.wait_for_open_port(port, ip, timeout=600)
        print(f"  ✓ {service} reachable directly at {ip}:{port}")

    print("\n=== Testing nginx proxyPass to microVM services ===")

    # Sonarr via nginx: nginx should proxy http://localhost/sonarr -> http://10.100.0.10:8989
    print("Testing Sonarr via nginx (localhost/sonarr -> 10.100.0.10:8989)...")
    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://localhost/sonarr/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Sonarr", f"Expected Sonarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Expected postgreSQL, got {status['databaseType']}"
    print(f"  ✓ Sonarr via nginx: appName={status['appName']}, db={status['databaseType']}")

    # Radarr via nginx: nginx should proxy http://localhost/radarr -> http://10.100.0.12:7878
    print("Testing Radarr via nginx (localhost/radarr -> 10.100.0.12:7878)...")
    result = host.succeed(
        "curl -f -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
        "http://localhost/radarr/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Radarr", f"Expected Radarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Expected postgreSQL, got {status['databaseType']}"
    print(f"  ✓ Radarr via nginx: appName={status['appName']}, db={status['databaseType']}")

    # Prowlarr via nginx: nginx should proxy http://localhost/prowlarr -> http://10.100.0.14:9696
    print("Testing Prowlarr via nginx (localhost/prowlarr -> 10.100.0.14:9696)...")
    result = host.succeed(
        "curl -f -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
        "http://localhost/prowlarr/api/v1/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Prowlarr", f"Expected Prowlarr, got {status['appName']}"
    print(f"  ✓ Prowlarr via nginx: appName={status['appName']}")

    # SABnzbd via nginx: nginx should proxy http://localhost/sabnzbd -> http://10.100.0.20:8080
    # SABnzbd guest config overrides misc.host to 0.0.0.0 so it listens on all interfaces
    print("Testing SABnzbd via nginx (localhost/sabnzbd -> 10.100.0.20:8080)...")
    result = host.succeed(
        "curl -f 'http://localhost/sabnzbd/api?mode=version&apikey=2222222222222222222222222222222'"
    )
    assert result.strip(), "Expected non-empty response from SABnzbd"
    print(f"  ✓ SABnzbd via nginx: response={result.strip()}")

    print("\n✅ microvm-nginx test passed!")
    print("   - nginx configured with microVM addresses (not 127.0.0.1)")
    print("   - All services proxied correctly through nginx to their microVM IPs")
    print("   - SABnzbd bind address override (0.0.0.0) working in guest")
    print("   - Inter-VM TCP proven by PostgreSQL database type in arr service APIs")
  '';
}
