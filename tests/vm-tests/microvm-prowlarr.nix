# MicroVM test: prowlarr runs in an isolated microVM and the API is reachable
# from the host at the VM's static IP. Prowlarr uses SQLite so no postgres VM
# is needed. Verifies the SABnzbd download client is configured — the same
# surface tested by prowlarr-basic.nix (qBittorrent not enabled in this test).
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-prowlarr-skip" { } ''
    echo "microvm-prowlarr: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-prowlarr-test";

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

          prowlarr = {
            enable = true;
            microvm.enable = true;
            config = {
              hostConfig.port = 9696;
              apiKey = {
                _secret = pkgs.writeText "prowlarr-apikey" "fedcba9876543210fedcba9876543210";
              };
            };
          };

          usenetClients.sabnzbd = {
            enable = true;
            microvm.enable = true;
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
      machine.succeed("mkdir -p /data/.state/prowlarr /data/.state/sabnzbd /data/downloads")

      machine.wait_for_unit("microvm@prowlarr.service", timeout=300)
      machine.wait_for_unit("sabnzbd.service", timeout=600)

      # Config service inside the VM restarts prowlarr after first startup; poll until stable.
      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
          "http://10.100.0.14:9696/api/v1/system/status",
          timeout=120
      )
      assert '"appName": "Prowlarr"' in result, f"Expected Prowlarr appName in API response, got: {result}"
      assert '"version"' in result, f"Expected version field in API response, got: {result}"

      machine.wait_for_unit("prowlarr-config.service", timeout=60)

      import json
      machine.wait_for_unit("prowlarr-downloadclients.service", timeout=180)
      clients = machine.succeed(
          "curl -sf -H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
          "http://10.100.0.14:9696/api/v1/downloadclient"
      )
      clients_list = json.loads(clients)
      assert len(clients_list) == 1, f"Expected 1 download client, found {len(clients_list)}"
      sabnzbd = next((c for c in clients_list if c["name"] == "SABnzbd"), None)
      assert sabnzbd is not None, f"Expected SABnzbd download client, found {clients_list}"
      assert sabnzbd['implementationName'] == 'SABnzbd', "Expected SABnzbd implementation"
      print("SABnzbd download client verified in Prowlarr")

      import base64
      client_b64 = base64.b64encode(json.dumps(sabnzbd).encode()).decode()
      machine.succeed(f"echo {client_b64} | base64 -d > /tmp/client-test.json")
      machine.succeed(
          "curl -sf -X POST -H 'Content-Type: application/json' "
          "-H 'X-Api-Key: fedcba9876543210fedcba9876543210' "
          "-d @/tmp/client-test.json "
          "http://10.100.0.14:9696/api/v1/downloadclient/test"
      )
      print("Prowlarr → SABnzbd cross-VM connectivity verified")

      print("microvm-prowlarr: Prowlarr API, SABnzbd download client, and cross-VM connectivity verified")
    '';
  }
