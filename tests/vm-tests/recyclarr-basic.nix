{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
}:
let
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
in
pkgsUnfree.testers.runNixOSTest {
  name = "recyclarr-basic-test";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      networking.useDHCP = true;
      virtualisation.cores = 4;

      nixflix = {
        enable = true;
        postgres.enable = true;

        radarr = {
          enable = true;
          user = "radarr";
          mediaDirs = [ "/media/movies" ];
          config = {
            hostConfig = {
              port = 7878;
              username = "admin";
              password = {
                _secret = pkgs.writeText "radarr-password" "testpassword123";
              };
            };
            apiKey = {
              _secret = pkgs.writeText "radarr-apikey" "abcd1234abcd1234abcd1234abcd1234";
            };
          };
        };

        sonarr = {
          enable = true;
          user = "sonarr";
          mediaDirs = [ "/media/tv" ];
          config = {
            hostConfig = {
              port = 8989;
              username = "admin";
              password = {
                _secret = pkgs.writeText "sonarr-password" "testpassword456";
              };
            };
            apiKey = {
              _secret = pkgs.writeText "sonarr-apikey" "efgh5678efgh5678efgh5678efgh5678";
            };
          };
        };

        sonarr-anime = {
          enable = true;
          user = "sonarr-anime";
          mediaDirs = [ "/media/anime" ];
          config = {
            hostConfig = {
              port = 8990;
              username = "admin";
              password = {
                _secret = pkgs.writeText "sonarr-anime-password" "testpassword789";
              };
            };
            apiKey = {
              _secret = pkgs.writeText "sonarr-anime-apikey" "ijkl9012ijkl9012ijkl9012ijkl9012";
            };
          };
        };

        recyclarr = {
          enable = true;
          radarr.enable = true;
          sonarr.enable = true;
          sonarr-anime.enable = true;
          cleanupUnmanagedProfiles = true;
        };
      };
    };

  testScript = ''
    start_all()

    # Wait for PostgreSQL
    machine.wait_for_unit("postgresql.service", timeout=120)
    machine.wait_for_unit("postgresql-ready.target", timeout=180)

    # Wait for all services to start
    machine.wait_for_unit("radarr.service", timeout=180)
    machine.wait_for_unit("sonarr.service", timeout=180)
    machine.wait_for_unit("sonarr-anime.service", timeout=180)
    machine.wait_for_open_port(7878, timeout=180)
    machine.wait_for_open_port(8989, timeout=180)
    machine.wait_for_open_port(8990, timeout=180)

    # Wait for config services to complete
    machine.wait_for_unit("radarr-config.service", timeout=180)
    machine.wait_for_unit("sonarr-config.service", timeout=180)
    machine.wait_for_unit("sonarr-anime-config.service", timeout=180)

    # Wait for services to come back up after config restarts
    machine.wait_for_unit("radarr.service", timeout=60)
    machine.wait_for_unit("sonarr.service", timeout=60)
    machine.wait_for_unit("sonarr-anime.service", timeout=60)
    machine.wait_for_open_port(7878, timeout=60)
    machine.wait_for_open_port(8989, timeout=60)
    machine.wait_for_open_port(8990, timeout=60)

    # Test API connectivity for all services
    machine.succeed(
        "curl -f -H 'X-Api-Key: abcd1234abcd1234abcd1234abcd1234' "
        "http://127.0.0.1:7878/api/v3/system/status"
    )
    machine.succeed(
        "curl -f -H 'X-Api-Key: efgh5678efgh5678efgh5678efgh5678' "
        "http://127.0.0.1:8989/api/v3/system/status"
    )
    machine.succeed(
        "curl -f -H 'X-Api-Key: ijkl9012ijkl9012ijkl9012ijkl9012' "
        "http://127.0.0.1:8990/api/v3/system/status"
    )

    # Verify recyclarr systemd service is defined
    machine.succeed("systemctl cat recyclarr.service")
    machine.succeed("systemctl cat recyclarr-cleanup-profiles.service")

    # Note: recyclarr.service will fail in isolated test VMs (no internet for trash guides)
    # and may restart in a loop. We skip waiting for it directly.

    # Run cleanup-profiles explicitly and verify it exits successfully.
    # systemctl start on a oneshot blocks until completion and returns the service exit code.
    # This is more reliable than polling systemctl show (which has timing issues with
    # recyclarr's restart loop) or journalctl (which doesn't capture unit messages reliably).
    machine.succeed("systemctl start recyclarr-cleanup-profiles.service")

    # Verify API keys are not visible in process arguments
    result = machine.succeed("ps aux")
    assert "abcd1234abcd1234abcd1234abcd1234" not in result, \
        "Radarr API key found in process list! Security vulnerability!"
    assert "efgh5678efgh5678efgh5678efgh5678" not in result, \
        "Sonarr API key found in process list! Security vulnerability!"
    assert "ijkl9012ijkl9012ijkl9012ijkl9012" not in result, \
        "Sonarr-Anime API key found in process list! Security vulnerability!"

    # Check that no API keys are visible in /proc/*/cmdline
    for api_key in ["abcd1234abcd1234abcd1234abcd1234",
                    "efgh5678efgh5678efgh5678efgh5678",
                    "ijkl9012ijkl9012ijkl9012ijkl9012"]:
        cmdline_check = machine.succeed(
            f"find /proc -name cmdline -type f 2>/dev/null | "
            f"xargs cat 2>/dev/null | "
            f"grep -q {api_key} && echo 'FOUND' || echo 'NOT_FOUND'"
        )
        assert "NOT_FOUND" in cmdline_check, \
            f"API key {api_key} found in /proc/*/cmdline! Security vulnerability!"
  '';
}
