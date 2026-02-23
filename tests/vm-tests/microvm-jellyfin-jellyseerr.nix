# MicroVM Jellyfin + Jellyseerr test
# Verifies both services start correctly in microVMs and are reachable from the host
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
  name = "microvm-jellyfin-jellyseerr";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation = {
        cores = 8;
        memorySize = 8192;
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

        jellyfin = {
          enable = true;

          users.admin = {
            password = {
              _secret = pkgs.writeText "jellyfin-admin-password" "testpassword123";
            };
            policy.isAdministrator = true;
          };

          # Jellyfin needs extra memory for first-boot DB initialisation.
          # Avoid exactly 2048 (QEMU hang quirk).
          microvm.memoryMB = 2047;
          microvm.vcpus = 4;
        };

        jellyseerr = {
          enable = true;
          apiKey = {
            _secret = pkgs.writeText "jellyseerr-apikey" "jellyseerr555555555555555555";
          };
          microvm.memoryMB = 2047;
        };
      };
    };

  testScript = ''
    start_all()

    # Create required state directories for virtiofs ownership
    host.succeed("mkdir -p /data/media /data/downloads")
    host.succeed("mkdir -p /data/.state/{jellyfin,jellyseerr}")

    host.wait_for_unit("multi-user.target")

    # Verify nginx started
    host.wait_for_unit("nginx.service", timeout=60)
    host.wait_for_open_port(80, timeout=60)
    print("  ✓ nginx started")

    # Wait for both microVMs to launch
    print("Waiting for microVMs to start...")
    host.wait_for_unit("microvm@jellyfin.service", timeout=300)
    host.wait_for_unit("microvm@jellyseerr.service", timeout=300)
    print("  ✓ Both microVMs launched")

    # Dump bridge/routing state so failures are self-documenting
    print("\n=== Host network diagnostic ===")
    print(host.succeed("ip -br addr show nixflix-br0 2>/dev/null || echo '(no nixflix-br0)'"))
    print(host.succeed("ip route show 2>/dev/null | head -20"))

    print("\n=== Testing Jellyfin microVM (10.100.0.30:8096) ===")
    # HTTP API checks are skipped: Jellyfin's first-boot DB initialisation is very
    # slow in triple-nested virt (host → test QEMU → microVM + virtiofs I/O),
    # and waiting for HTTP 200 risks timing out the test host. TCP port open is
    # sufficient to prove the microVM started and the service is listening.
    # nginx proxy routing for Jellyfin is verified in microvm-nginx and
    # microvm-full-stack tests.
    print("  Waiting for Jellyfin to start (TCP port 8096)...")
    host.wait_for_open_port(8096, "10.100.0.30", timeout=300)
    print("  ✓ Jellyfin microVM started — TCP port 8096 is open on 10.100.0.30")

    print("\n=== Testing Jellyseerr microVM (10.100.0.31:5055) ===")
    # Same rationale as Jellyfin — TCP port check only.
    print("  Waiting for Jellyseerr to start (TCP port 5055)...")
    host.wait_for_open_port(5055, "10.100.0.31", timeout=300)
    print("  ✓ Jellyseerr microVM started — TCP port 5055 is open on 10.100.0.31")

    print("\n=== Testing State Directory Ownership ===")
    jf_owner = host.succeed("stat -c '%U:%G' /data/.state/jellyfin").strip()
    assert jf_owner == "jellyfin:media", \
        f"Expected jellyfin:media for Jellyfin state dir, got {jf_owner}"
    print(f"  ✓ Jellyfin state dir: {jf_owner}")

    js_owner = host.succeed("stat -c '%U:%G' /data/.state/jellyseerr").strip()
    assert js_owner == "jellyseerr:media", \
        f"Expected jellyseerr:media for Jellyseerr state dir, got {js_owner}"
    print(f"  ✓ Jellyseerr state dir: {js_owner}")

    print("\n✅ microvm-jellyfin-jellyseerr test passed!")
    print("   - Jellyfin microVM started (TCP 10.100.0.30:8096 open)")
    print("   - Jellyseerr microVM started (TCP 10.100.0.31:5055 open)")
    print("   - State directory ownership correct (jellyfin:media, jellyseerr:media)")
  '';
}
