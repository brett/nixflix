{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.jellyseerr;
  microvmCfg = cfg.microvm;
  isEnabled = cfg.enable && microvmCfg.enable;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";

  # Override hostname with the service's VM address; all other fields come from host config.
  guestRadarr = mapAttrs (
    _name: radarrCfg:
    radarrCfg
    // {
      hostname =
        if config.nixflix.radarr.enable && config.nixflix.radarr.microvm.enable then
          config.nixflix.radarr.microvm.address
        else
          radarrCfg.hostname;
    }
  ) cfg.radarr;

  guestSonarr = mapAttrs (
    name: sonarrCfg:
    sonarrCfg
    // {
      hostname =
        if name == "Sonarr" && config.nixflix.sonarr.enable && config.nixflix.sonarr.microvm.enable then
          config.nixflix.sonarr.microvm.address
        else if
          name == "Sonarr Anime"
          && (config.nixflix.sonarr-anime.enable or false)
          && config.nixflix.sonarr-anime.microvm.enable
        then
          config.nixflix.sonarr-anime.microvm.address
        else
          sonarrCfg.hostname;
    }
  ) cfg.sonarr;
in
{
  options.nixflix.jellyseerr.microvm = {
    enable = mkEnableOption "Jellyseerr microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.jellyseerr;
      description = "Static IP address for the Jellyseerr microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the Jellyseerr microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = 1536;
      description = "Memory in MB for the Jellyseerr microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ "postgresql-ready.target" ];
      description = ''
        Systemd units added to After= and Wants= on the host-side
        microvm@jellyseerr.service drop-in. Defaults to postgresql-ready.target
        because Jellyseerr stores its state in PostgreSQL.
      '';
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.jellyseerr.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      nixflix.globals.microVMHostConfigurations.jellyseerr = {
        module = ./configuration.nix;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        # VPN would block external metadata and poster APIs.
        vpnBypass = true;
        needsMedia = false;
        needsDownloads = false;
        extraModules = [
          # host-only: nginx is the sole consumer
          {
            networking.firewall.extraInputRules =
              let
                port = toString cfg.port;
                hostAddr = config.nixflix.microvm.network.hostAddress;
              in
              ''
                ip saddr { ${hostAddr} } tcp dport ${port} accept
              '';
          }
          {
            nixflix.jellyseerr.jellyfin = {
              hostname = mkIf config.nixflix.jellyfin.microvm.enable config.nixflix.jellyfin.microvm.address;
              # jellyfin.enable is false in the jellyseerr guest so these can't
              # be auto-derived; forward the host-resolved values directly.
              adminUsername = mkForce cfg.jellyfin.adminUsername;
              adminPassword = mkForce cfg.jellyfin.adminPassword;
            };
            nixflix.jellyseerr.apiKey = mkForce cfg.apiKey;
            nixflix.jellyseerr.radarr = mkForce guestRadarr;
            nixflix.jellyseerr.sonarr = mkForce guestSonarr;
          }
        ]
        ++ optionals config.nixflix.postgres.microvm.enable [
          (
            let
              postgresHost = config.nixflix.postgres.microvm.address;
            in
            { pkgs, ... }:
            {
              # Connect to postgres microVM via TCP instead of Unix socket.
              # services.postgresql.enable is false in the guest; inject env vars directly.
              systemd.services.jellyseerr.environment = {
                DB_TYPE = "postgres";
                DB_HOST = postgresHost;
                DB_PORT = "5432";
                DB_USER = "jellyseerr";
                DB_NAME = "jellyseerr";
                DB_LOG_QUERIES = "false";
              };
              systemd.services.jellyseerr-wait-for-db = {
                description = "Wait for PostgreSQL microVM at ${postgresHost}";
                wantedBy = [ "multi-user.target" ];
                before = [ "jellyseerr.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "5min";
                  ExecStart = pkgs.writeShellScript "jellyseerr-wait-for-db" ''
                    set -eu
                    echo "Waiting for PostgreSQL at ${postgresHost}:5432..."
                    for i in $(seq 1 150); do
                      if ${pkgs.postgresql}/bin/pg_isready \
                           -h ${postgresHost} -p 5432 -t 2 > /dev/null 2>&1; then
                        echo "PostgreSQL is ready"
                        exit 0
                      fi
                      echo "Waiting... attempt $i/150"
                      sleep 2
                    done
                    echo "Timeout waiting for PostgreSQL" >&2
                    exit 1
                  '';
                };
              };
              systemd.services.jellyseerr = {
                after = [ "jellyseerr-wait-for-db.service" ];
                requires = [ "jellyseerr-wait-for-db.service" ];
              };
            }
          )
        ];
      };

      nixflix.globals.serviceAddresses.jellyseerr = microvmCfg.address;

      systemd.services."microvm@jellyseerr" = mkIf (microvmCfg.startAfter != [ ]) {
        after = microvmCfg.startAfter;
        wants = microvmCfg.startAfter;
      };

      systemd.services = {
        jellyseerr = mkForce {
          description = "Wait for Jellyseerr HTTP API to be ready (host-side poll)";
          after = [ "microvm@jellyseerr.service" ];
          requires = [ "microvm@jellyseerr.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "600";
            ExecStart = pkgs.writeShellScript "jellyseerr-host-ready" ''
              set -eu
              echo "Waiting for Jellyseerr HTTP API at ${microvmCfg.address}..."
              for i in $(seq 1 120); do
                HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                  --connect-timeout 2 --max-time 5 \
                  "http://${microvmCfg.address}:${toString cfg.port}/api/v1/status" \
                  2>/dev/null || echo "000")
                if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
                  echo "Jellyseerr API ready (HTTP $HTTP_CODE)"
                  exit 0
                fi
                echo "Attempt $i/120 (HTTP $HTTP_CODE)"
                sleep 5
              done
              echo "Timeout waiting for Jellyseerr API" >&2
              exit 1
            '';
          };
        };

        jellyseerr-env = mkForce {
          description = "Jellyseerr env (disabled in microVM mode)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        jellyseerr-setup = mkForce {
          description = "Jellyseerr setup (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyseerr-libraries = mkForce {
          description = "Jellyseerr libraries (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyseerr-jellyfin = mkForce {
          description = "Jellyseerr jellyfin (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyseerr-user-settings = mkForce {
          description = "Jellyseerr user settings (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyseerr-radarr = mkForce {
          description = "Jellyseerr radarr (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyseerr-sonarr = mkForce {
          description = "Jellyseerr sonarr (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

      };

      services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
        enableACME = config.nixflix.nginx.acme.enable;
        forceSSL = config.nixflix.nginx.acme.enable;
        locations."/".proxyPass = mkForce "http://${microvmCfg.address}:${toString cfg.port}";
      };
    })
  ];
}
