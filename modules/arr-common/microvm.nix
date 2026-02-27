serviceName:
{ guestConfigPath }:
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.${serviceName};
  microvmCfg = cfg.microvm;
  secrets = import ../../lib/secrets { inherit lib; };

  capitalizedName = toUpper (substring 0 1 serviceName) + substring 1 (-1) serviceName;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";

  isEnabled = cfg.enable && microvmCfg.enable;
in
{
  options.nixflix.${serviceName}.microvm = {
    enable = mkEnableOption "${capitalizedName} microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.${serviceName};
      description = "Static IP address for the ${capitalizedName} microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the ${capitalizedName} microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.memoryMB;
      description = "Memory in MB for the ${capitalizedName} microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ "postgresql-ready.target" ];
      description = ''
        Systemd units added to After= and Wants= on the host-side
        microvm@${serviceName}.service drop-in. Controls when this microVM
        starts relative to others. Defaults to postgresql-ready.target because
        ${capitalizedName} requires a PostgreSQL database.
      '';
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.${serviceName}.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      nixflix.globals.microVMHostConfigurations.${serviceName} = {
        module = guestConfigPath;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        extraModules = [
          {
            nixflix = {
              ${serviceName} = {
                config = {
                  inherit (cfg.config) apiKey;
                  # bind on all interfaces — "127.0.0.1" is unreachable from the host bridge
                  hostConfig = cfg.config.hostConfig // {
                    bindAddress = "*";
                  };
                  inherit (cfg.config) rootFolders;
                  inherit (cfg.config) delayProfiles;
                };
                # mkDefault so guest-specific overrides (bindaddress, postgres TCP) win.
                settings = mkDefault cfg.settings;
              };
            };
          }
          # Clear ExecStartPost: remote postgres migrations can take many minutes,
          # triggering Restart=on-failure before the service is ready.
          (_: {
            systemd.services."${serviceName}".serviceConfig.ExecStartPost = mkForce [ ];
          })
        ]
        ++ optionals (cfg ? mediaDirs && cfg.mediaDirs != [ ]) [
          {
            nixflix.${serviceName}.mediaDirs = cfg.mediaDirs;
            microvm.shares = imap0 (i: mediaDir: {
              source = mediaDir;
              mountPoint = mediaDir;
              # Tag must be ≤36 chars; strip hyphens to stay within limit.
              tag = "nf-${replaceStrings [ "-" ] [ "" ] serviceName}-m${toString i}";
              proto = "virtiofs";
            }) cfg.mediaDirs;
          }
        ]
        ++ optionals config.nixflix.postgres.microvm.enable [
          {
            nixflix.${serviceName}.settings = {
              log.dbEnabled = true;
              postgres = {
                user = serviceName;
                host = config.nixflix.postgres.microvm.address;
                port = 5432;
                mainDb = serviceName;
                logDb = "${serviceName}-logs";
              };
            };
          }
          (
            let
              postgresHost = config.nixflix.postgres.microvm.address;
            in
            {
              pkgs,
              ...
            }:
            {
              # services.postgresql.enable is always false inside the guest; this gate replaces it.
              systemd.services."${serviceName}-wait-for-db" = {
                description = "Wait for PostgreSQL microVM at ${postgresHost}";
                wantedBy = [ "multi-user.target" ];
                before = [ "${serviceName}.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "5min";
                  ExecStart = pkgs.writeShellScript "${serviceName}-wait-for-db" ''
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
              systemd.services."${serviceName}" = {
                after = [ "${serviceName}-wait-for-db.service" ];
                requires = [ "${serviceName}-wait-for-db.service" ];
              };
            }
          )
        ]
        ++ [
          # Guest-side readiness gate: blocks multi-user.target (and vsock READY=1)
          # until the arr HTTP API is confirmed responding.
          (
            let
              inherit (cfg.config.hostConfig) port;
              inherit (cfg.config) apiVersion;
              apiKeySetup = optionalString (
                cfg.config.apiKey != null
              ) "API_KEY=${secrets.toShellValue cfg.config.apiKey}";
              apiKeyArg = optionalString (cfg.config.apiKey != null) "-H \"X-Api-Key: $API_KEY\"";
              acceptCondition =
                if cfg.config.apiKey != null then
                  ''[ "$HTTP_CODE" = "200" ]''
                else
                  ''[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]'';
            in
            { pkgs, ... }:
            {
              systemd.services."${serviceName}-guest-ready" = {
                description = "Wait for ${capitalizedName} HTTP API to be ready (guest-side readiness gate)";
                wantedBy = [ "multi-user.target" ];
                before = [ "multi-user.target" ];
                # No After=: adding After=<service> risks letting multi-user.target
                # start before this gate if that service is slow to activate.
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "10min";
                  ExecStart = pkgs.writeShellScript "${serviceName}-guest-ready" ''
                    set -eu
                    ${apiKeySetup}
                    echo "Waiting for ${capitalizedName} HTTP API..."
                    for i in $(seq 1 600); do
                      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                        --connect-timeout 1 --max-time 3 \
                        ${apiKeyArg} \
                        "http://127.0.0.1:${toString port}/api/${apiVersion}/system/status" \
                        2>/dev/null || echo "000")
                      if ${acceptCondition}; then
                        echo "${capitalizedName} API ready"
                        exit 0
                      fi
                      echo "Attempt $i/600 (HTTP $HTTP_CODE)"
                      sleep 1
                    done
                    echo "Timeout waiting for ${capitalizedName} API" >&2
                    exit 1
                  '';
                };
              };
            }
          )
        ];
      };

      nixflix.globals.serviceAddresses.${serviceName} = microvmCfg.address;

      systemd.services."microvm@${serviceName}" = mkIf (microvmCfg.startAfter != [ ]) {
        after = microvmCfg.startAfter;
        wants = microvmCfg.startAfter;
      };

      # microvm@{name}.service is Type=notify; it becomes active only after the
      # guest's {service}-guest-ready completes and fires vsock READY=1.
      systemd.services = {
        "${serviceName}" = mkForce {
          description = "${capitalizedName} (running in microVM at ${microvmCfg.address})";
          after = [ "microvm@${serviceName}.service" ];
          requires = [ "microvm@${serviceName}.service" ];
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        "${serviceName}-env" = mkForce {
          description = "${capitalizedName} env (disabled in microVM mode)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        "${serviceName}-config" = mkForce {
          description = "${capitalizedName} config (delegating to microVM)";
          after = [ "microvm@${serviceName}.service" ];
          requires = [ "microvm@${serviceName}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        "${serviceName}-rootfolders" = mkForce {
          description = "${capitalizedName} rootfolders (delegating to microVM)";
          after = [ "microvm@${serviceName}.service" ];
          requires = [ "microvm@${serviceName}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        "${serviceName}-delayprofiles" = mkForce {
          description = "${capitalizedName} delayprofiles (delegating to microVM)";
          after = [ "microvm@${serviceName}.service" ];
          requires = [ "microvm@${serviceName}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
      };

      services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
        locations."/".proxyPass =
          mkForce "http://${microvmCfg.address}:${toString cfg.config.hostConfig.port}";
      };
    })
  ];
}
