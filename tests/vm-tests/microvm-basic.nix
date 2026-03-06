# Basic microVM test: sonarr + postgres VMs start and API is reachable.
# Requires microvmModules to be provided; trivially passes otherwise.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-basic-skip" { } ''
    echo "microvm-basic: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-basic-test";

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

          postgres = {
            enable = true;
            microvm.enable = true;
          };

          sonarr = {
            enable = true;
            microvm.enable = true;
            config = {
              hostConfig.port = 8989;
              apiKey = {
                _secret = pkgs.writeText "sonarr-apikey" "0123456789abcdef0123456789abcdef";
              };
            };
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed("mkdir -p /data/.state/postgres /data/.state/sonarr /data/media /data/downloads")

      # microvm@*.service is Type=notify, activated only after the guest readiness
      # gate completes. First boot in nested KVM can take ~10 min (DB init + migrations).
      machine.wait_for_unit("microvm@postgres.service", timeout=600)
      machine.wait_for_unit("microvm@sonarr.service", timeout=600)

      # The postgres VM firewall allows port 5432 only from service VM IPs.
      # The host bridge IP is not in the allowlist, so this must fail.
      machine.fail("bash -c 'echo >/dev/tcp/10.100.0.2/5432'")

      # Sonarr activating proves postgres is reachable from the service VM side —
      # sonarr won't reach its ready state unless it connected to postgres successfully.

      # Config service inside the VM restarts sonarr after first startup;
      # poll until the API is stable.
      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: 0123456789abcdef0123456789abcdef' "
          "http://10.100.0.10:8989/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Sonarr"' in result, f"Expected Sonarr appName in API response, got: {result}"
      assert '"version"' in result, f"Expected version field in API response, got: {result}"

      machine.wait_for_unit("sonarr-config.service", timeout=60)

      print("microvm-basic: postgres firewall blocks host, sonarr API verified from host")
    '';
  }
