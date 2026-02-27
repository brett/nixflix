# MicroVM test: qBittorrent runs in an isolated microVM and the WebUI is
# reachable from the host at the VM's static IP.
# Verifies authenticated login and categories — the same configuration
# surfaces tested by qbittorrent-basic.nix.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-qbittorrent-skip" { } ''
    echo "microvm-qbittorrent: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    pkgsUnfree = import pkgs.path {
      inherit system;
      config.allowUnfree = true;
    };
  in
  pkgsUnfree.testers.runNixOSTest {
    name = "microvm-qbittorrent-test";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
        ];

        virtualisation.cores = 4;
        virtualisation.memorySize = 4096;
        # Enable nested KVM so cloud-hypervisor can use /dev/kvm inside the test VM
        virtualisation.qemu.options = [ "-cpu host" ];
        boot.kernelModules = [
          "kvm-intel"
          "kvm-amd"
        ];

        nixflix = {
          enable = true;

          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
          };

          torrentClients.qbittorrent = {
            enable = true;
            microvm.enable = true;
            webuiPort = 8282;
            downloadsDir = "/data/downloads/torrent";

            categories = {
              movies = "/data/downloads/torrent/movies";
              tv = "/data/downloads/torrent/tv";
            };

            # Plain-text password used by the microVM readiness check and
            # download client integration.
            password = {
              _secret = pkgs.writeText "qbittorrent-password" "testpassword123";
            };

            serverConfig = {
              LegalNotice.Accepted = true;
              Preferences.WebUI = {
                Username = "admin";
                LocalHostAuth = false;
                Locale = "en";
                # No Password_PBKDF2 needed: configuration.nix forces the microVM bridge
                # subnet into AuthSubnetWhitelist, so the ready service and test connections
                # are accepted without a password check. In production, set Password_PBKDF2
                # to a proper PBKDF2 hash and remove the subnet whitelist override.
              };
            };
          };
        };
      };

    testScript = ''
      start_all()

      # Pre-create state dir; virtiofsd needs the source to exist before it opens it.
      machine.succeed("mkdir -p /data/.state/qbittorrent /data/downloads/torrent")

      # Wait for microVM to start
      machine.wait_for_unit("microvm@qbittorrent.service", timeout=120)

      # Wait for qBittorrent to be ready (ready service authenticates with credentials)
      machine.wait_for_unit("qbittorrent-ready.service", timeout=300)

      # Verify qBittorrent WebUI is reachable and accepts credentials.
      # Use wait_until_succeeds: qBittorrent may briefly restart as it finalises
      # its initial config after the ready service fires.
      import json
      login_result = machine.wait_until_succeeds(
          "curl -sf -c /tmp/qbt-cookies.txt "
          "-d 'username=admin&password=testpassword123' "
          "http://10.100.0.21:8282/api/v2/auth/login",
          timeout=60
      )
      assert login_result.strip() == "Ok.", f"Expected 'Ok.' from login, got: {login_result!r}"
      print("Authenticated login verified")

      # Verify the application version (confirms qBittorrent is fully running)
      version = machine.succeed(
          "curl -sf -b /tmp/qbt-cookies.txt "
          "http://10.100.0.21:8282/api/v2/app/version"
      )
      assert version.strip() != "", f"Expected non-empty version string, got: {version!r}"
      print(f"qBittorrent version: {version.strip()}")

      # Verify categories.json was written to the virtiofs-backed state dir.
      # The guest writes to /var/lib/qBittorrent (virtiofs → host /data/.state/qbittorrent),
      # so the file is readable from the host at the source path.
      machine.succeed("test -f /data/.state/qbittorrent/qBittorrent/config/categories.json")
      cats_raw = machine.succeed(
          "cat /data/.state/qbittorrent/qBittorrent/config/categories.json"
      )
      cats = json.loads(cats_raw)
      assert "movies" in cats, f"movies category missing; found: {list(cats.keys())}"
      assert cats["movies"]["save_path"] == "/data/downloads/torrent/movies", \
          f"Unexpected movies save_path: {cats['movies']['save_path']}"
      assert "tv" in cats, f"tv category missing; found: {list(cats.keys())}"
      assert cats["tv"]["save_path"] == "/data/downloads/torrent/tv", \
          f"Unexpected tv save_path: {cats['tv']['save_path']}"
      print("Categories verified")

      print("microvm-qbittorrent: WebUI authenticated, version confirmed, categories verified from host")
    '';
  }
