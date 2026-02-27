{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.prowlarr;
  microvmCfg = cfg.microvm;

  isEnabled = cfg.enable && microvmCfg.enable;

  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";

  arrServiceNames = [
    "sonarr"
    "sonarr-anime"
    "radarr"
    "lidarr"
  ];

  mkVmApplication =
    serviceName:
    let
      svcCfg = config.nixflix.${serviceName};
      svcMicrovmCfg = svcCfg.microvm;
      displayName = concatMapStringsSep " " (
        word: toUpper (builtins.substring 0 1 word) + builtins.substring 1 (-1) word
      ) (splitString "-" serviceName);
      serviceBase = builtins.elemAt (splitString "-" serviceName) 0;
      implementationName = toUpper (substring 0 1 serviceBase) + substring 1 (-1) serviceBase;
    in
    optional (svcCfg.enable && svcMicrovmCfg.enable) {
      name = displayName;
      inherit implementationName;
      apiKey = mkDefault svcCfg.config.apiKey;
      baseUrl = mkDefault "http://${svcMicrovmCfg.address}:${toString svcCfg.config.hostConfig.port}";
      # prowlarrUrl must reach prowlarr from the arr VM — prowlarr is at its own VM IP
      prowlarrUrl = mkDefault "http://${microvmCfg.address}:${toString cfg.config.hostConfig.port}";
    };

  vmApplications = concatMap mkVmApplication arrServiceNames;
in
{
  options.nixflix.prowlarr.microvm = {
    enable = mkEnableOption "Prowlarr microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.prowlarr;
      description = "Static IP address for the Prowlarr microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the Prowlarr microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.memoryMB;
      description = "Memory in MB for the Prowlarr microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Systemd units added to After= and Wants= on the host-side
        microvm@prowlarr.service drop-in. Controls when Prowlarr's microVM
        starts relative to others. Defaults to empty (starts immediately);
        set to ["microvm@sonarr-anime.service"] etc. to stagger startup.
      '';
    };
  };

  config = mkIf isEnabled {
    nixflix.globals.microVMHostConfigurations.prowlarr = {
      module = ./configuration.nix;
      inherit (microvmCfg) address;
      inherit (microvmCfg) vcpus;
      inherit (microvmCfg) memoryMB;
      # VPN would break access to public indexers.
      vpnBypass = true;
      needsMedia = false;
      needsDownloads = false;
      extraModules = [
        {
          nixflix.prowlarr.config = {
            inherit (cfg.config) apiKey;
            inherit (cfg.config) hostConfig;
            applications = mkForce vmApplications;
            inherit (cfg.config) indexers;
          };
        }
        {
          networking.firewall.extraInputRules =
            let
              port = toString cfg.config.hostConfig.port;
              hostAddr = config.nixflix.microvm.network.hostAddress;
              arrSuffixes = concatMapStrings
                (svc:
                  optionalString
                    (config.nixflix.${svc}.enable && config.nixflix.${svc}.microvm.enable)
                    ", ${config.nixflix.${svc}.microvm.address}"
                )
                [ "sonarr" "sonarr-anime" "radarr" "lidarr" ];
            in
            ''
              ip saddr { ${hostAddr}${arrSuffixes} } tcp dport ${port} accept
            '';
        }
        # Clear ExecStartPost: on a loaded system, Prowlarr can exceed the 90-second poll
        # window, triggering Restart=on-failure. Matches arr-common/microvm.nix for other arr services.
        (_: {
          systemd.services.prowlarr.serviceConfig.ExecStartPost = mkForce [ ];
        })
        # Guest-side readiness gate: blocks multi-user.target until Prowlarr HTTP API is ready.
        (
          let
            inherit (cfg.config.hostConfig) port;
          in
          { pkgs, ... }:
          {
            systemd.services.prowlarr-guest-ready = {
              description = "Wait for Prowlarr HTTP API to be ready (guest-side readiness gate)";
              wantedBy = [ "multi-user.target" ];
              before = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                # 15min matches the host-side TimeoutStartSec=900 for the full-stack test.
                TimeoutStartSec = "15min";
                ExecStart = pkgs.writeShellScript "prowlarr-guest-ready" ''
                  set -eu
                  echo "Waiting for Prowlarr HTTP API..."
                  for i in $(seq 1 840); do
                    HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                      --connect-timeout 1 --max-time 3 \
                      "http://127.0.0.1:${toString port}/api/v1/system/status" \
                      2>/dev/null || echo "000")
                    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
                      echo "Prowlarr API ready (HTTP $HTTP_CODE)"
                      exit 0
                    fi
                    echo "Attempt $i/840 (HTTP $HTTP_CODE)"
                    sleep 1
                  done
                  echo "Timeout waiting for Prowlarr API" >&2
                  exit 1
                '';
              };
            };
          }
        )
      ];
    };

    nixflix.globals.serviceAddresses.prowlarr = microvmCfg.address;

    systemd.services."microvm@prowlarr" = mkMerge [
      {
        # Prowlarr starts last in the sequential arr chain; give extra time beyond the 600s default.
        serviceConfig.TimeoutStartSec = mkForce "900";
      }
      (mkIf (microvmCfg.startAfter != [ ]) {
        after = microvmCfg.startAfter;
        wants = microvmCfg.startAfter;
      })
    ];

    systemd.services = {
      prowlarr = mkForce {
        description = "Prowlarr (running in microVM at ${microvmCfg.address})";
        after = [ "microvm@prowlarr.service" ];
        requires = [ "microvm@prowlarr.service" ];
        wantedBy = [ ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      prowlarr-env = mkForce {
        description = "Prowlarr env (disabled in microVM mode)";
        wantedBy = [ ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      prowlarr-config = mkForce {
        description = "Prowlarr config (delegating to microVM)";
        after = [ "microvm@prowlarr.service" ];
        requires = [ "microvm@prowlarr.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      prowlarr-indexers = mkForce {
        description = "Prowlarr indexers (delegating to microVM)";
        after = [ "microvm@prowlarr.service" ];
        requires = [ "microvm@prowlarr.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      prowlarr-applications = mkForce {
        description = "Prowlarr applications (delegating to microVM)";
        after = [ "microvm@prowlarr.service" ];
        requires = [ "microvm@prowlarr.service" ];
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
  };
}
