# Prowlarr microVM test - Prowlarr in a microVM, applications auto-configured from Sonarr
#
# Tests the prowlarr-applications service running inside the Prowlarr guest VM.
# With only Sonarr also enabled, exactly 1 application (Sonarr) should be
# auto-configured in Prowlarr via the API.
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
  name = "microvm-prowlarr";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      environment.systemPackages = [ pkgs.jq ];

      virtualisation = {
        cores = 4;
        memorySize = 6144;
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
      };
    };

  testScript = ''
    import json

    start_all()

    # Create required directories for microVMs
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{prowlarr,sonarr,postgresql}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for all microVM services to start
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@postgres.service", timeout=120)
    host.wait_for_unit("microvm@prowlarr.service", timeout=120)
    host.wait_for_unit("microvm@sonarr.service", timeout=120)

    # Wait for services to become reachable via TCP
    print("Waiting for Prowlarr (10.100.0.14:9696)...")
    host.wait_for_open_port(9696, "10.100.0.14", timeout=120)
    print("  ✓ Prowlarr (TCP port open)")

    print("Waiting for Sonarr (10.100.0.10:8989)...")
    host.wait_for_open_port(8989, "10.100.0.10", timeout=120)
    print("  ✓ Sonarr (TCP port open)")

    # Verify nginx is running
    host.wait_for_unit("nginx.service", timeout=60)
    host.wait_for_open_port(80, timeout=60)
    print("  ✓ nginx listening on port 80")

    # Verify Prowlarr is reachable via nginx and using PostgreSQL
    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://localhost/prowlarr/api/v1/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Prowlarr", f"Expected Prowlarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Prowlarr not using PostgreSQL: {status['databaseType']}"
    print("  ✓ nginx -> Prowlarr (PostgreSQL)")

    # Diagnostic: check if prowlarr-config has run yet by checking instanceName.
    # prowlarr-config sets instanceName to "Prowlarr Test" via PUT /config/host.
    # If still "Prowlarr" (default), prowlarr-config hasn't run or failed.
    def check_prowlarr_config():
        try:
            r = host.succeed(
                "curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
                "http://localhost/prowlarr/api/v1/config/host"
            )
            cfg = json.loads(r)
            print(f"  Prowlarr instanceName={cfg.get('instanceName')} authMethod={cfg.get('authenticationMethod')}")
        except Exception as e:
            print(f"  (config/host check failed: {e})")

    check_prowlarr_config()

    # Dump the prowlarr microVM journal (host's view of VM console output).
    # This shows systemd service messages and script stdout from inside the VM.
    def dump_prowlarr_vm_journal(lines=100):
        rc, out = host.execute(
            f"journalctl -u microvm@prowlarr.service --no-pager 2>&1 | tail -{lines}"
        )
        print(f"=== microvm@prowlarr.service journal (last {lines} lines) ===\n{out}")

    # Wait for prowlarr-applications to configure Sonarr as an application.
    # prowlarr-applications runs inside the Prowlarr microVM after prowlarr-config
    # finishes (which restarts Prowlarr to apply host config). With only Sonarr
    # enabled on the host, exactly 1 application should be auto-configured.
    # Expected timing: prowlarr-config starts immediately after prowlarr.service,
    # waits ~20s for API, runs config + restart, then prowlarr-applications runs.
    # Total: ~60-80s from prowlarr start. 300s gives comfortable 4x buffer.
    print("\nWaiting for Prowlarr applications to be configured...")
    import time
    deadline = time.time() + 300
    last_count = -1
    last_journal_dump = time.time()
    success = False
    while time.time() < deadline:
        try:
            r = host.succeed(
                "curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
                "http://localhost/prowlarr/api/v1/applications"
            )
            apps = json.loads(r)
            count = len(apps)
            if count != last_count:
                print(f"  applications count: {count}")
                last_count = count
                check_prowlarr_config()
            if count == 1:
                success = True
                break
        except Exception:
            pass
        # Dump VM journal every 120s for diagnostics
        if time.time() - last_journal_dump >= 120:
            dump_prowlarr_vm_journal(80)
            last_journal_dump = time.time()
        time.sleep(5)
    if not success:
        check_prowlarr_config()
        dump_prowlarr_vm_journal(200)
        raise Exception(f"Timed out waiting for 1 Prowlarr application (last count: {last_count})")
    assert len(apps) == 1, f"Expected 1 Prowlarr application (Sonarr), got {len(apps)}"
    assert apps[0]["implementationName"] == "Sonarr", f"Expected Sonarr, got {apps[0]['implementationName']}"
    print("  ✓ Prowlarr applications: 1 configured (Sonarr)")

    print("\n✅ Prowlarr microVM test passed!")
    print("   - Prowlarr microVM started and reachable")
    print("   - Prowlarr using PostgreSQL (inter-VM TCP confirmed)")
    print("   - prowlarr-applications auto-configured 1 application (Sonarr)")
  '';
}
