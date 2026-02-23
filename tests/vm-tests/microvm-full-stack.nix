# Full-stack microVM test - All services in microVMs with inter-service communication
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
  name = "microvm-full-stack";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      environment.systemPackages = [ pkgs.jq ];

      virtualisation = {
        cores = 8;
        memorySize = 12288;
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

        prowlarr = {
          enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "prowlarr-apikey" "0123456789abcdef0123456789abcdef";
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

        sonarr = {
          enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "sonarr-apikey" "abcdef0123456789abcdef0123456789";
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

        lidarr = {
          enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "lidarr-apikey" "1111111111111111111111111111111";
            };
            hostConfig = {
              instanceName = "Lidarr Test";
              username = "admin";
              password = {
                _secret = pkgs.writeText "lidarr-password" "testpassword";
              };
              authenticationMethod = "forms";
            };
          };
        };

        sabnzbd = {
          enable = true;
          settings.misc = {
            host = "0.0.0.0";
            port = 8080;
            api_key = {
              _secret = pkgs.writeText "sabnzbd-apikey" "2222222222222222222222222222222";
            };
            nzb_key = {
              _secret = pkgs.writeText "sabnzbd-nzbkey" "testnzbkey";
            };
            url_base = "/sabnzbd";
          };
        };

        jellyfin = {
          enable = true;
          users.admin = {
            password = {
              _secret = pkgs.writeText "jellyfin-admin-password" "testpassword123";
            };
            policy.isAdministrator = true;
          };
          # Extra memory and CPUs for first-boot DB initialisation in nested virt.
          # Avoid exactly 2048 (QEMU hang quirk).
          microvm.memoryMB = 2047;
          microvm.vcpus = 4;
        };

        jellyseerr = {
          enable = true;
          apiKey = {
            _secret = pkgs.writeText "jellyseerr-apikey" "3333333333333333333333333333333";
          };
          microvm.memoryMB = 2047;
        };
      };
    };

  testScript = ''
    import json

    start_all()

    # Create required directories for microVMs
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{prowlarr,sonarr,radarr,lidarr,sabnzbd,jellyfin,jellyseerr,postgresql}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for all microVM services to start
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@postgres.service", timeout=120)
    services = ["prowlarr", "sonarr", "radarr", "lidarr", "sabnzbd", "jellyfin", "jellyseerr"]
    for service in services:
        print(f"  Waiting for microvm@{service}.service...")
        host.wait_for_unit(f"microvm@{service}.service", timeout=120)

    # Wait for each service to be reachable via TCP.
    # nginx.enable = true sets urlBase on arr services, so direct-IP API calls
    # would need the urlBase prefix — use TCP-only checks here and validate APIs
    # through nginx below.
    # 8 simultaneous VMs in nested virt; services typically start within 30s.
    print("\nWaiting for services to become reachable...")

    print("  Waiting for Prowlarr (10.100.0.14:9696)...")
    host.wait_for_open_port(9696, "10.100.0.14", timeout=300)
    print("  ✓ Prowlarr (TCP port open)")

    print("  Waiting for Sonarr (10.100.0.10:8989)...")
    host.wait_for_open_port(8989, "10.100.0.10", timeout=300)
    print("  ✓ Sonarr (TCP port open)")

    print("  Waiting for Radarr (10.100.0.12:7878)...")
    host.wait_for_open_port(7878, "10.100.0.12", timeout=300)
    print("  ✓ Radarr (TCP port open)")

    print("  Waiting for Lidarr (10.100.0.13:8686)...")
    host.wait_for_open_port(8686, "10.100.0.13", timeout=300)
    print("  ✓ Lidarr (TCP port open)")

    print("  Waiting for SABnzbd (10.100.0.20:8080)...")
    host.wait_for_open_port(8080, "10.100.0.20", timeout=300)
    print("  ✓ SABnzbd (TCP port open)")

    # Jellyfin and Jellyseerr checks are deferred to after other service checks —
    # first boot in triple-nested virt can take >5min for these to bind their ports.

    # Verify nginx reverse proxy and inter-VM PostgreSQL connectivity.
    # All arr services get urlBase = "/<service>" when nginx is enabled, so API
    # checks go through nginx. databaseType=postgreSQL proves inter-VM TCP routing
    # (each service connected to the postgres microVM before starting).
    print("\nVerifying nginx reverse proxy and PostgreSQL connectivity...")
    host.wait_for_unit("nginx.service", timeout=60)
    host.wait_for_open_port(80, timeout=60)
    print("  ✓ nginx listening on port 80")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://localhost/prowlarr/api/v1/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Prowlarr", f"Expected Prowlarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Prowlarr not using PostgreSQL: {status['databaseType']}"
    print("  ✓ nginx -> Prowlarr (PostgreSQL)")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: abcdef0123456789abcdef0123456789' "
        "http://localhost/sonarr/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Sonarr", f"Expected Sonarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Sonarr not using PostgreSQL: {status['databaseType']}"
    print("  ✓ nginx -> Sonarr (PostgreSQL)")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
        "http://localhost/radarr/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Radarr", f"Expected Radarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Radarr not using PostgreSQL: {status['databaseType']}"
    print("  ✓ nginx -> Radarr (PostgreSQL)")

    result = host.succeed(
        "curl -f -H 'X-Api-Key: 1111111111111111111111111111111' "
        "http://localhost/lidarr/api/v1/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Lidarr", f"Expected Lidarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Lidarr not using PostgreSQL: {status['databaseType']}"
    print("  ✓ nginx -> Lidarr (PostgreSQL)")

    result = host.succeed(
        "curl -f 'http://localhost/sabnzbd/api?mode=version&apikey=2222222222222222222222222222222'"
    )
    version_info = json.loads(result)
    assert "version" in version_info, f"SABnzbd via nginx missing version field: {result}"
    print(f"  ✓ nginx -> SABnzbd (version {version_info['version']})")

    # Verify API configuration services ran correctly inside the microVMs.
    # These are oneshot services that run after the main service starts, so we
    # poll until they complete rather than checking immediately.

    # Prowlarr applications: sonarr, radarr, lidarr should be auto-configured.
    # prowlarr-applications runs inside the Prowlarr VM after prowlarr-config finishes.
    print("\nWaiting for Prowlarr applications to be configured...")
    host.wait_until_succeeds(
        "test \"$(curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://localhost/prowlarr/api/v1/applications | jq length)\" -eq 3",
        timeout=300,
    )
    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://localhost/prowlarr/api/v1/applications"
    )
    apps = json.loads(result)
    assert len(apps) == 3, f"Expected 3 Prowlarr applications (Sonarr, Radarr, Lidarr), got {len(apps)}"
    print(f"  ✓ Prowlarr applications: {len(apps)} configured (Sonarr, Radarr, Lidarr)")

    # Sonarr download clients: SABnzbd should be auto-configured with the SABnzbd microVM IP.
    # sonarr-downloadclients runs inside the Sonarr VM after sonarr-config finishes.
    print("Waiting for Sonarr download clients to be configured...")
    host.wait_until_succeeds(
        "test \"$(curl -sf -H 'X-Api-Key: abcdef0123456789abcdef0123456789' "
        "http://localhost/sonarr/api/v3/downloadclient | jq length)\" -eq 1",
        timeout=300,
    )
    result = host.succeed(
        "curl -f -H 'X-Api-Key: abcdef0123456789abcdef0123456789' "
        "http://localhost/sonarr/api/v3/downloadclient"
    )
    clients = json.loads(result)
    assert len(clients) == 1, f"Expected 1 Sonarr download client (SABnzbd), got {len(clients)}"
    assert clients[0]["name"] == "SABnzbd", f"Expected SABnzbd, got {clients[0]['name']}"
    print(f"  ✓ Sonarr download clients: {clients[0]['name']} configured")

    # Jellyfin and Jellyseerr: check TCP port only (HTTP API too slow on first boot).
    # Checked here rather than at startup to give 5+ min for initial DB setup in
    # triple-nested virt. By this point the VMs have been running for several minutes.
    print("\nWaiting for Jellyfin and Jellyseerr TCP ports...")
    print("  Waiting for Jellyfin (10.100.0.30:8096)...")
    host.wait_for_open_port(8096, "10.100.0.30", timeout=600)
    print("  ✓ Jellyfin (TCP port open)")

    print("  Waiting for Jellyseerr (10.100.0.31:5055)...")
    host.wait_for_open_port(5055, "10.100.0.31", timeout=600)
    print("  ✓ Jellyseerr (TCP port open)")

    print("\n✅ Full-stack microVM test passed!")
    print("   - All 8 microVMs started (postgres + 7 services)")
    print("   - nginx reverse proxy routing working for all arr services + SABnzbd")
    print("   - All arr services using PostgreSQL (inter-VM TCP confirmed)")
    print("   - Prowlarr applications auto-configured (3: Sonarr, Radarr, Lidarr)")
    print("   - Sonarr download client auto-configured (SABnzbd)")
    print("   - Jellyfin and Jellyseerr TCP ports open")
  '';
}
