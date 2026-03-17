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
      default = 2048;
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
        # VPN would block image proxies and Cloudflare CDN used for metadata.
        vpnBypass = true;
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
          # Without this, the arr service races the virtiofs mount and can create
          # config.xml in the guest-local overlay before the host share is visible.
          ({ config, ... }: {
            systemd.services."${serviceName}".unitConfig.RequiresMountsFor =
              "${config.nixflix.stateDir}/${serviceName}";
          })
          # Clear ExecStartPost: remote postgres migrations can take many minutes,
          # triggering Restart=on-failure before the service is ready.
          (_: {
            systemd.services."${serviceName}".serviceConfig.ExecStartPost = mkForce [ ];
          })
          # Sonarr's PUT /api/.../config/host returns 4xx (schema mismatch), causing
          # `set -eu` + `curl -f` to exit before the restart.  sed on config.xml instead.
          (
            let
              inherit (cfg.config.hostConfig) port;
              inherit (cfg.config) apiVersion;
              apiKeySetup = optionalString (cfg.config.apiKey != null)
                "API_KEY=${secrets.toShellValue cfg.config.apiKey}";
              apiKeyArg = optionalString (cfg.config.apiKey != null)
                "-H \"X-Api-Key: $API_KEY\"";
              acceptCondition =
                if cfg.config.apiKey != null then
                  ''[ "$HTTP_CODE" = "200" ]''
                else
                  ''[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]'';
            in
            { config, pkgs, ... }:
            {
              systemd.services."${serviceName}-config" = mkForce {
                description = "Configure ${capitalizedName} bind address in microVM (pre-READY=1)";
                after = [ "${serviceName}.service" ];
                before = [ "${serviceName}-guest-ready.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "20min";
                };
                script = ''
                  set -eu
                  ${apiKeySetup}
                  CONF="${config.nixflix.stateDir}/${serviceName}/config.xml"
                  echo "Waiting for ${capitalizedName} API (up to 20min)..."
                  for i in $(seq 1 1200); do
                    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                      --connect-timeout 1 --max-time 3 \
                      ${apiKeyArg} \
                      "http://127.0.0.1:${toString port}/api/${apiVersion}/system/status" \
                      2>/dev/null || true)
                    if ${acceptCondition}; then
                      echo "${capitalizedName} API is ready"
                      break
                    fi
                    if [ "$i" = "1200" ]; then
                      echo "${capitalizedName} API not available after 20 minutes" >&2
                      exit 1
                    fi
                    sleep 1
                  done
                  echo "Writing BindAddress=* to $CONF..."
                  if [ -f "$CONF" ] && grep -q '<BindAddress>' "$CONF"; then
                    ${pkgs.gnused}/bin/sed -i \
                      's|<BindAddress>.*</BindAddress>|<BindAddress>*</BindAddress>|' \
                      "$CONF"
                  fi
                  echo "Restarting ${capitalizedName}..."
                  systemctl restart ${serviceName}.service
                  echo "${capitalizedName} restarted"
                '';
              };
            }
          )
          # After guest-ready (not just the service) — the API isn't stable until
          # sonarr-config has run the sed fix and restarted sonarr.
          (_: {
            systemd.services."${serviceName}-rootfolders".after =
              [ "${serviceName}-guest-ready.service" ];
            systemd.services."${serviceName}-delayprofiles".after =
              [ "${serviceName}-guest-ready.service" ];
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
          {
            networking.firewall.extraInputRules =
              let
                port = toString cfg.config.hostConfig.port;
                hostAddr = config.nixflix.microvm.network.hostAddress;
                prowlarrSuffix = optionalString
                  (config.nixflix.prowlarr.enable && config.nixflix.prowlarr.microvm.enable)
                  ", ${config.nixflix.prowlarr.microvm.address}";
                jellyseerrSuffix = optionalString
                  (serviceName != "lidarr" && config.nixflix.jellyseerr.enable && config.nixflix.jellyseerr.microvm.enable)
                  ", ${config.nixflix.jellyseerr.microvm.address}";
              in
              ''
                ip saddr { ${hostAddr}${prowlarrSuffix}${jellyseerrSuffix} } tcp dport ${port} accept
              '';
          }
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
                # After sonarr-config so READY=1 fires only after sed writes BindAddress=*
                # and sonarr restarts.  After= on a non-existent unit is ignored by systemd.
                after = [
                  "${serviceName}.service"
                  "${serviceName}-config.service"
                ];
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
                        2>/dev/null || true)
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

      # APPNAME__SERVER__BINDADDRESS is not reliably honoured on first boot;
      # seeding config.xml before the microVM starts is the only reliable approach.
      systemd.services."${serviceName}-init-config-xml" = {
        description = "Seed ${capitalizedName} config.xml with BindAddress=* (microVM first-boot)";
        before = [ "microvm@${serviceName}.service" ];
        wantedBy = [ "microvm@${serviceName}.service" ];
        unitConfig.ConditionPathExists = "!${config.nixflix.stateDir}/${serviceName}/config.xml";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = cfg.user;
          Group = cfg.group;
          UMask = "0077";
          ExecStart = pkgs.writeShellScript "${serviceName}-init-config-xml" ''
            set -eu
            printf '<?xml version="1.0" encoding="utf-8"?>\n<Config>\n  <BindAddress>*</BindAddress>\n</Config>\n' \
              > "${config.nixflix.stateDir}/${serviceName}/config.xml"
          '';
        };
      };

      systemd.services."microvm@${serviceName}" = mkMerge [
        (mkIf (microvmCfg.startAfter != [ ]) {
          after = microvmCfg.startAfter;
          wants = microvmCfg.startAfter;
        })
        # DB migrations under concurrent virtiofsd IO can exceed the systemd default.
        { serviceConfig.TimeoutStartSec = mkForce "900"; }
      ];

      # microvm@{name}.service is Type=notify; it becomes active only after the
      # guest's {service}-guest-ready completes and fires vsock READY=1.
      systemd.services = {
        # Without these stubs, both services try to connect to /run/postgresql
        # (no local socket in microVM mode) and block postgresql-ready.target.
        "${serviceName}-setup-logs-db" = mkForce {
          description = "${capitalizedName} setup-logs-db (disabled in microVM mode)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

        "${serviceName}-wait-for-db" = mkForce {
          description = "${capitalizedName} wait-for-db (disabled in microVM mode)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

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

        "${serviceName}-config" = mkForce (
          let
            port = toString cfg.config.hostConfig.port;
            apiVersion = cfg.config.apiVersion;
            addr = microvmCfg.address;
            apiKeySetup = optionalString (cfg.config.apiKey != null)
              "API_KEY=${secrets.toShellValue cfg.config.apiKey}";
            apiKeyArg = optionalString (cfg.config.apiKey != null)
              "-H \"X-Api-Key: $API_KEY\"";
            acceptCondition =
              if cfg.config.apiKey != null then
                ''[ "$HTTP_CODE" = "200" ]''
              else
                ''[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]'';
          in
          {
            description = "${capitalizedName} config (polling microVM API for stability)";
            # after= not requires= so a crash-before-READY=1 doesn't propagate
            # as failure here and cascade to sonarr-downloadclients.
            after = [ "microvm@${serviceName}.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              TimeoutStartSec = "660";
              ExecStart = pkgs.writeShellScript "${serviceName}-host-config-wait" ''
                set -eu
                ${apiKeySetup}
                echo "Waiting for ${capitalizedName} API to stabilize at ${addr}..."
                for i in $(seq 1 600); do
                  HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                    --connect-timeout 2 --max-time 5 \
                    ${apiKeyArg} \
                    "http://${addr}:${port}/api/${apiVersion}/system/status" \
                    2>/dev/null || true)
                  if ${acceptCondition}; then
                    echo "${capitalizedName} API stable at ${addr}"
                    exit 0
                  fi
                  echo "Attempt $i/600 (HTTP $HTTP_CODE)"
                  sleep 1
                done
                echo "Timeout waiting for ${capitalizedName} API" >&2
                exit 1
              '';
            };
          }
        );

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
