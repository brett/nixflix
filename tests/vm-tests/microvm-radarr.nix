# MicroVM test: radarr runs in an isolated microVM and the API is reachable
# from the host at the VM's static IP.
# Verifies root folder, delay profile, and SABnzbd download client — the
# same configuration surfaces tested by radarr-basic.nix.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-radarr-skip" { } ''
    echo "microvm-radarr: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-radarr-test";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 6;
        virtualisation.memorySize = 4096;

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

          radarr = {
            enable = true;
            microvm.enable = true;
            mediaDirs = [ "/media/movies" ];
            config = {
              hostConfig = {
                port = 7878;
                # password triggers creation of radarr-config.service inside the guest.
                password = {
                  _secret = pkgs.writeText "radarr-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "radarr-apikey" "abcd1234abcd1234abcd1234abcd1234";
              };
              delayProfiles = [
                {
                  enableUsenet = true;
                  enableTorrent = true;
                  preferredProtocol = "torrent";
                  usenetDelay = 0;
                  torrentDelay = 360;
                  bypassIfHighestQuality = true;
                  bypassIfAboveCustomFormatScore = false;
                  minimumCustomFormatScore = 0;
                  order = 2147483647;
                  tags = [ ];
                  id = 1;
                }
              ];
            };
          };

          usenetClients.sabnzbd = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@radarr.service" ];
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
      machine.succeed("mkdir -p /data/.state/postgres /data/.state/radarr /data/.state/sabnzbd /data/media /data/downloads /media/movies")

      machine.wait_for_unit("microvm@postgres.service", timeout=600)
      machine.wait_for_unit("microvm@radarr.service", timeout=600)
      machine.wait_for_unit("sabnzbd.service", timeout=600)

      # Config service inside the VM restarts radarr after first startup; poll until stable.
      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Radarr"' in result, f"Expected Radarr appName in API response, got: {result}"
      assert '"version"' in result, f"Expected version field in API response, got: {result}"

      # Guest-side rootfolders/delayprofiles services run asynchronously after the API
      # is up; poll until they complete.
      machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/rootfolder | grep -q '/media/movies'",
          timeout=120
      )
      print("Root folder /media/movies verified")

      import json
      machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/delayprofile | grep -q 'torrent'",
          timeout=120
      )
      profiles_list = json.loads(machine.succeed(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/delayprofile"
      ))
      assert len(profiles_list) == 1, f"Expected 1 delay profile, found {len(profiles_list)}"
      assert profiles_list[0]['preferredProtocol'] == 'torrent', "Expected preferredProtocol=torrent"
      assert profiles_list[0]['torrentDelay'] == 360, "Expected torrentDelay=360"
      print("Delay profile verified")

      machine.wait_for_unit("radarr-downloadclients.service", timeout=180)
      clients_list = json.loads(machine.succeed(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/downloadclient"
      ))
      assert len(clients_list) == 1, f"Expected 1 download client, found {len(clients_list)}"
      sabnzbd = next((c for c in clients_list if c["name"] == "SABnzbd"), None)
      assert sabnzbd is not None, f"Expected SABnzbd download client, found {clients_list}"
      assert sabnzbd['implementationName'] == 'SABnzbd', "Expected SABnzbd implementation"
      category_field = next((f for f in sabnzbd['fields'] if f['name'] == 'movieCategory'), None)
      assert category_field is not None, "Expected movieCategory field in SABnzbd download client"
      assert category_field['value'] == 'radarr', f"Expected movieCategory 'radarr', got: {category_field['value']}"
      print("SABnzbd download client with movieCategory='radarr' verified")

      import base64
      client_b64 = base64.b64encode(json.dumps(sabnzbd).encode()).decode()
      machine.succeed(f"echo {client_b64} | base64 -d > /tmp/client-test.json")
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/json' "
          "-H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "-d @/tmp/client-test.json "
          "http://10.100.0.12:7878/api/v3/downloadclient/test"
      )
      print("Radarr → SABnzbd cross-VM connectivity verified")

      # Quality profiles are seeded from postgres during migrations — only present if the VM can reach the DB.
      profiles = json.loads(machine.succeed(
          "curl -sf -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
          "http://10.100.0.12:7878/api/v3/qualityprofile"
      ))
      assert len(profiles) > 0, f"Expected quality profiles from postgres DB, got: {profiles}"
      print(f"postgres DB connectivity verified from radarr VM: {len(profiles)} quality profile(s) present")

      # The postgres VM firewall allows the host bridge IP on port 5432.
      machine.succeed("bash -c 'echo >/dev/tcp/10.100.0.2/5432'")

      print("microvm-radarr: API, root folder, delay profile, download client, cross-VM connectivity, and postgres all verified")
    '';
  }
