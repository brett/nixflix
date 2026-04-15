# MicroVM test: SABnzbd runs in an isolated microVM and the API is reachable
# from the host at the VM's static IP. SABnzbd does not use postgres.
# Verifies categories are configured via API — the main configuration surface
# testable from the host (filesystem checks require guest access).
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-sabnzbd-skip" { } ''
    echo "microvm-sabnzbd: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-sabnzbd-test";

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

          usenetClients.sabnzbd = {
            enable = true;
            microvm.enable = true;
            settings = {
              misc = {
                api_key = {
                  _secret = pkgs.writeText "sabnzbd-apikey" "testapikey123456789abcdef";
                };
                nzb_key = {
                  _secret = pkgs.writeText "sabnzbd-nzbkey" "testnzbkey123456789abcdef";
                };
                port = 8080;
                host = "0.0.0.0";
                url_base = "/sabnzbd";
              };
              categories = [
                {
                  name = "tv";
                  dir = "tv";
                  priority = 0;
                  pp = 3;
                  script = "None";
                }
                {
                  name = "movies";
                  dir = "movies";
                  priority = 1;
                  pp = 2;
                  script = "None";
                }
              ];
            };
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed("mkdir -p /data/.state/sabnzbd /data/downloads")

      machine.wait_for_unit("sabnzbd.service", timeout=600)

      result = machine.succeed(
          "curl -sf 'http://10.100.0.20:8080/sabnzbd/api?mode=version&apikey=testapikey123456789abcdef'"
      )
      assert '"version"' in result, f"Expected version field in SABnzbd API response, got: {result}"

      machine.wait_for_unit("sabnzbd-categories.service", timeout=60)

      import json
      cfg_raw = machine.succeed(
          "curl -sf 'http://10.100.0.20:8080/sabnzbd/api?mode=get_config&apikey=testapikey123456789abcdef'"
      )
      categories = json.loads(cfg_raw)['config']['categories']
      tv = next((c for c in categories if c['name'] == 'tv'), None)
      assert tv is not None, f"tv category missing; found: {[c['name'] for c in categories]}"
      print(f"TV category: {tv}")
      movies = next((c for c in categories if c['name'] == 'movies'), None)
      assert movies is not None, f"movies category missing; found: {[c['name'] for c in categories]}"
      print(f"Movies category: {movies}")

      print("microvm-sabnzbd: SABnzbd API and categories verified from host")
    '';
  }
