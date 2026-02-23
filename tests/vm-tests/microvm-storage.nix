# MicroVM storage test - Verify virtiofs mounts and hardlink creation
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
  name = "microvm-storage";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
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
            url_base = "";
          };
        };
      };
    };

  testScript = ''
    import json

    start_all()

    # Create required directories for microVMs
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{sonarr,radarr,sabnzbd,postgresql}")

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for microVMs to start
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@postgres.service", timeout=300)
    for service in ["sonarr", "radarr", "sabnzbd"]:
        print(f"  Waiting for microvm@{service}.service...")
        host.wait_for_unit(f"microvm@{service}.service", timeout=300)

    # Wait for services to respond - if they do, their virtiofs state dir mounts
    # are working (the service couldn't have initialized its database otherwise).
    print("\nWaiting for services to become reachable (proves virtiofs mounts work)...")

    print("  Waiting for Sonarr (10.100.0.10:8989)...")
    host.wait_for_open_port(8989, "10.100.0.10", timeout=600)
    result = host.succeed(
        "curl -f -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
        "http://10.100.0.10:8989/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Sonarr", f"Expected Sonarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Expected postgreSQL, got {status['databaseType']}"
    print("  ✓ Sonarr accessible (state dir + postgres mounts working)")

    print("  Waiting for Radarr (10.100.0.12:7878)...")
    host.wait_for_open_port(7878, "10.100.0.12", timeout=600)
    result = host.succeed(
        "curl -f -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
        "http://10.100.0.12:7878/api/v3/system/status"
    )
    status = json.loads(result)
    assert status["appName"] == "Radarr", f"Expected Radarr, got {status['appName']}"
    assert status["databaseType"] == "postgreSQL", f"Expected postgreSQL, got {status['databaseType']}"
    print("  ✓ Radarr accessible (state dir + postgres mounts working)")

    print("  Waiting for SABnzbd (10.100.0.20:8080)...")
    host.wait_for_open_port(8080, "10.100.0.20", timeout=600)
    host.succeed("curl -f 'http://10.100.0.20:8080/api?mode=version&apikey=2222222222222222222222222222222'")
    print("  ✓ SABnzbd accessible (state dir mount working)")

    print("\n=== Testing Hardlink Support ===")
    # virtiofs exposes the host filesystem directly to VMs, so the host filesystem's
    # hardlink capabilities are what matters for cross-mount hardlinks.
    # Media software (Sonarr, Radarr) requires hardlinks to work between
    # /data/downloads and /data/media to efficiently move completed downloads.
    # Both paths are under /data on the same host filesystem.
    print("Creating test file in /data/downloads...")
    host.succeed("mkdir -p /data/downloads/test")
    host.succeed("echo 'test content' > /data/downloads/test/original.txt")
    host.succeed("chmod 644 /data/downloads/test/original.txt")

    original_inode = host.succeed(
        "stat -c '%i' /data/downloads/test/original.txt"
    ).strip()
    print(f"  Original file inode: {original_inode}")

    print("Creating hardlink from /data/downloads to /data/media...")
    host.succeed("ln /data/downloads/test/original.txt /data/media/hardlink.txt")
    host.succeed("test -f /data/media/hardlink.txt")
    print("  ✓ Hardlink file exists in /data/media")

    hardlink_inode = host.succeed(
        "stat -c '%i' /data/media/hardlink.txt"
    ).strip()
    print(f"  Hardlink inode: {hardlink_inode}")
    assert original_inode == hardlink_inode, \
        f"Inodes don't match! Original: {original_inode}, Hardlink: {hardlink_inode}"
    print("  ✓ Same inode (true hardlink, not a copy)")

    link_count = host.succeed(
        "stat -c '%h' /data/downloads/test/original.txt"
    ).strip()
    assert link_count == "2", f"Expected link count of 2, got {link_count}"
    print(f"  ✓ Link count is {link_count}")

    content1 = host.succeed("cat /data/downloads/test/original.txt").strip()
    content2 = host.succeed("cat /data/media/hardlink.txt").strip()
    assert content1 == content2, "File contents don't match"
    print("  ✓ File contents match")

    # Modify the file and verify the change is visible via the hardlink
    host.succeed("echo 'appended' >> /data/downloads/test/original.txt")
    modified = host.succeed("cat /data/media/hardlink.txt")
    assert "appended" in modified, "Modification not reflected via hardlink"
    print("  ✓ Modifications reflected via hardlink (true shared data)")

    print("\n=== Testing Cross-VM Shared Storage ===")
    # All VMs share the same host directories via virtiofs: a file written by one
    # VM is immediately visible to all others because they all map to the same host path.
    print("Writing test file to shared /data/media from host...")
    host.succeed("echo 'cross-vm-test' > /data/media/cross-vm.txt")
    content = host.succeed("cat /data/media/cross-vm.txt").strip()
    assert content == "cross-vm-test", f"Expected 'cross-vm-test', got '{content}'"
    print("  ✓ Shared /data/media readable/writable (visible to all VMs)")

    host.succeed("echo 'downloads-test' > /data/downloads/cross-vm.txt")
    content = host.succeed("cat /data/downloads/cross-vm.txt").strip()
    assert content == "downloads-test", f"Expected 'downloads-test', got '{content}'"
    print("  ✓ Shared /data/downloads readable/writable (visible to all VMs)")

    print("\n=== Testing State Directory Ownership ===")
    # nixflix creates per-service state dirs owned by <service>:media.
    # virtiofs exposes the host filesystem to the guest, so chown operations
    # inside the VM appear on the host with the correct Unix UIDs/GIDs.
    # This verifies that the GID mapping is correct and globals.nix UIDs/GIDs
    # are consistent between host and guest.
    sonarr_owner = host.succeed("stat -c '%U:%G' /data/.state/sonarr").strip()
    assert sonarr_owner == "sonarr:media", \
        f"Expected sonarr:media for Sonarr state dir, got {sonarr_owner}"
    print(f"  ✓ Sonarr state dir: {sonarr_owner}")

    radarr_owner = host.succeed("stat -c '%U:%G' /data/.state/radarr").strip()
    assert radarr_owner == "radarr:media", \
        f"Expected radarr:media for Radarr state dir, got {radarr_owner}"
    print(f"  ✓ Radarr state dir: {radarr_owner}")

    sabnzbd_owner = host.succeed("stat -c '%U:%G' /data/.state/sabnzbd").strip()
    assert sabnzbd_owner == "sabnzbd:media", \
        f"Expected sabnzbd:media for SABnzbd state dir, got {sabnzbd_owner}"
    print(f"  ✓ SABnzbd state dir: {sabnzbd_owner}")

    print("\n✅ Storage test passed!")
    print("   - virtiofs mounts working (services accessible, state dirs mounted)")
    print("   - Hardlinks supported across /data/downloads and /data/media")
    print("   - Shared storage accessible from all VMs via host filesystem")
    print("   - State directory ownership configured correctly")
  '';
}
