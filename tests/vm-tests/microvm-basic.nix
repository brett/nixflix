# Basic microVM test - Single service (Sonarr) in microVM
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules, # Passed by test infrastructure but not used (nixosModules already includes microvm)  # Passed by test infrastructure
  hypervisor ? "cloud-hypervisor",
}:

let
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
in
pkgsUnfree.testers.runNixOSTest {
  name = "microvm-basic";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        # Enable nested virtualization for microVMs
        qemu.options = [ "-cpu host" ];
      };

      # Enable KVM for microVMs
      boot.kernelModules = [
        "kvm-intel"
        "kvm-amd"
      ];

      nixflix = {
        enable = true;
        microvm.enable = true;
        microvm.hypervisor = hypervisor;

        # Run PostgreSQL in its own microVM
        postgres = {
          enable = true;
          microvm.enable = true;
        };

        sonarr = {
          enable = true;
          config = {
            apiKey = {
              _secret = pkgs.writeText "sonarr-apikey" "0123456789abcdef0123456789abcdef";
            };
            hostConfig = {
              instanceName = "Sonarr";
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
    host.succeed("mkdir -p /data/.state/sonarr /data/.state/postgresql /data/media /data/downloads")

    # Wait for host to be ready
    host.wait_for_unit("multi-user.target")

    # Wait for both microVMs to start
    host.wait_for_unit("microvm@postgres.service", timeout=300)
    host.wait_for_unit("microvm@sonarr.service", timeout=300)

    # Wait for Sonarr to become reachable. Once the port opens, Sonarr has:
    #   - Mounted its virtiofs state directory
    #   - Connected to the postgres microVM via TCP (wait-for-db succeeded)
    #   - Initialised its database tables
    print("Waiting for Sonarr (10.100.0.10:8989)...")
    host.wait_for_open_port(8989, "10.100.0.10", timeout=600)

    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://10.100.0.10:8989/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Sonarr", f"Expected Sonarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", \
        f"Sonarr not using PostgreSQL (inter-VM TCP failed?): {status['databaseType']}"
    print(f"  ✓ Sonarr API responding (databaseType={status['databaseType']})")

    print("\n✅ Basic microVM test passed!")
    print("   - Sonarr microVM started and reachable at 10.100.0.10:8989")
    print("   - Inter-VM TCP: Sonarr connected to postgres microVM (databaseType=postgreSQL)")
    print("   - virtiofs state dir mount working (service initialised successfully)")
  '';
}
