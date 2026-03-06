# MicroVM interservice communication test: sonarr + postgres + sabnzbd in
# isolated microVMs. Verifies that:
#   - sonarr ran DB migrations on the postgres VM (tables exist over TCP)
#   - downloadarr wired the SABnzbd download client with the VM IP, not 127.0.0.1
#   - direct TCP from host to SABnzbd VM works
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-interservice-skip" { } ''
    echo "microvm-interservice: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-interservice-test";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 6;
        virtualisation.memorySize = 6144;

        # postgresql client on the host so we can run psql against the postgres VM.
        environment.systemPackages = [ pkgs.postgresql ];

        nixflix = {
          enable = true;

          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
          };

          postgres = {
            enable = true;
            microvm.enable = true;
          };

          sonarr = {
            enable = true;
            microvm.enable = true;
            mediaDirs = [ "/media/tv" ];
            config = {
              hostConfig = {
                port = 8989;
                password = {
                  _secret = pkgs.writeText "sonarr-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "sonarr-apikey" "0123456789abcdef0123456789abcdef";
              };
            };
          };

          usenetClients.sabnzbd = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@sonarr.service" ];
            };
            settings = {
              misc = {
                api_key = {
                  _secret = pkgs.writeText "sabnzbd-apikey" "sabnzbd555555555555555555555555555";
                };
                nzb_key = {
                  _secret = pkgs.writeText "sabnzbd-nzbkey" "sabnzbdnzb666666666666666666666";
                };
                port = 8080;
                host = "0.0.0.0";
                url_base = "/sabnzbd";
              };
            };
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed(
          "mkdir -p"
          " /data/.state/postgres /data/.state/sonarr /data/.state/sabnzbd"
          " /data/media /data/downloads /media/tv"
      )

      machine.wait_for_unit("microvm@postgres.service", timeout=600)
      machine.wait_for_unit("microvm@sonarr.service", timeout=600)
      machine.wait_for_unit("sabnzbd.service", timeout=600)

      # Config service inside the VM restarts sonarr after first startup; poll until stable.
      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
          "http://10.100.0.10:8989/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Sonarr"' in result, f"sonarr API: {result!r}"
      print("sonarr API verified")

      # microvm@sonarr.service being active means migrations ran against postgres.
      # The host bridge IP (10.100.0.1) is in the postgres trusted subnet; no password needed.
      table_list = machine.succeed(
          "psql -h 10.100.0.2 -U sonarr -d sonarr -c '\\dt' 2>&1"
      )
      assert "Did not find any relations" not in table_list, (
          "sonarr postgres database has no tables — migration did not run"
      )
      print("postgres migration verified: tables present in sonarr database")

      import json

      machine.wait_for_unit("sonarr-downloadclients.service", timeout=180)
      clients_raw = machine.succeed(
          "curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
          "http://10.100.0.10:8989/api/v3/downloadclient"
      )
      clients = json.loads(clients_raw)
      sabnzbd_client = next((c for c in clients if c["name"] == "SABnzbd"), None)
      assert sabnzbd_client is not None, f"SABnzbd download client not found in: {[c['name'] for c in clients]}"

      host_field = next(
          (f for f in sabnzbd_client["fields"] if f["name"] == "host"), None
      )
      assert host_field is not None, "SABnzbd download client has no 'host' field"
      assert host_field["value"] == "10.100.0.20", (
          f"SABnzbd host should be VM IP 10.100.0.20, got: {host_field['value']!r}"
      )
      print(f"SABnzbd download client host verified: {host_field['value']}")

      machine.succeed("bash -c 'echo >/dev/tcp/10.100.0.20/8080'")
      print("SABnzbd TCP from host verified")

      print(
          "microvm-interservice: postgres migration, download client VM IP, "
          "and cross-VM TCP all verified"
      )
    '';
  }
