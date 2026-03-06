# MicroVM test: qBittorrent runs in an isolated microVM and the WebUI is
# reachable from the host at the VM's static IP.
# Verifies WebUI reachability and categories — the host bridge IP is
# intentionally excluded from AuthSubnetWhitelist (nginx-proxied user
# sessions must still require login). Authenticated API access from arr
# service VMs is tested in the arr microVM tests.
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
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-qbittorrent-test";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 4;
        virtualisation.memorySize = 4096;

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
              };
            };
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed("mkdir -p /data/.state/qbittorrent /data/downloads/torrent")

      machine.wait_for_unit("qbittorrent.service", timeout=300)

      import json
      # Verify the WebUI is reachable from the host bridge. GET / returns the login
      # page (HTTP 200) without authentication — the host bridge IP is intentionally
      # excluded from AuthSubnetWhitelist so that nginx-proxied user sessions still
      # require login. Authenticated API access is tested in the arr VM tests via
      # service VMs that are in the whitelist.
      http_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "http://10.100.0.21:8282/"
      )
      assert http_code.strip() == "200", f"Expected HTTP 200 from WebUI, got: {http_code!r}"
      print("WebUI reachable from host (HTTP 200)")

      # categories.json is written inside the guest at /var/lib/qBittorrent (virtiofs),
      # readable from the host at the virtiofs source path.
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

      print("microvm-qbittorrent: WebUI reachable from host, categories verified")
    '';
  }
