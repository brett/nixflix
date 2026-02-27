{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  secrets = import ../../../../lib/secrets { inherit lib; };
  cfg = config.nixflix.torrentClients.qbittorrent;
  microvmCfg = cfg.microvm;
  isEnabled = cfg.enable && microvmCfg.enable;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";
in
{
  options.nixflix.torrentClients.qbittorrent.microvm = {
    enable = mkEnableOption "qBittorrent microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.qbittorrent;
      description = "Static IP address for the qBittorrent microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the qBittorrent microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.memoryMB;
      description = "Memory in MB for the qBittorrent microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Systemd units added to After= and Wants= on the host-side microvm@qbittorrent.service drop-in. Defaults to empty (starts immediately).";
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.torrentClients.qbittorrent.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      nixflix.globals.microVMHostConfigurations.qbittorrent = {
        module = ./configuration.nix;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        vpnBypass = false;
        # Downloads land in downloadsDir; arr services move files to mediaDir.
        needsMedia = false;
        extraModules = [
          {
            networking.firewall.extraInputRules =
              let
                port = toString cfg.webuiPort;
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
          {
            nixflix.torrentClients.qbittorrent = {
              # Whitelist only the specific arr service VM IPs that need API access.
              # The host bridge IP is intentionally excluded: nginx proxies user requests
              # from 10.100.0.1, and whitelisting it would bypass qBittorrent's WebUI auth
              # for all proxied browser sessions.
              serverConfig = lib.recursiveUpdate cfg.serverConfig {
                Preferences.WebUI.AuthSubnetWhitelistEnabled = true;
                Preferences.WebUI.AuthSubnetWhitelist = lib.concatStringsSep ","
                  (lib.filter (s: s != "") (map (svc:
                    if (config.nixflix.${svc}.enable or false) && (config.nixflix.${svc}.microvm.enable or false)
                    then config.nixflix.${svc}.microvm.address
                    else ""
                  ) [ "sonarr" "sonarr-anime" "radarr" "lidarr" ]));
              };
              inherit (cfg) password;
              inherit (cfg) webuiPort;
              inherit (cfg) downloadsDir;
              inherit (cfg) categories;
            };
          }
          # Guest-side readiness gate: blocks multi-user.target until qBittorrent WebUI is ready.
          (
            let
              port = cfg.webuiPort;
              hasPassword = cfg.password != null;
              passwordSetup = optionalString hasPassword "PASSWORD=${secrets.toShellValue cfg.password}";
              username = cfg.serverConfig.Preferences.WebUI.Username or "admin";
            in
            { pkgs, ... }:
            {
              systemd.services.qbittorrent-guest-ready = {
                description = "Wait for qBittorrent WebUI to be ready (guest-side readiness gate)";
                wantedBy = [ "multi-user.target" ];
                before = [ "multi-user.target" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  TimeoutStartSec = "5min";
                  ExecStart = pkgs.writeShellScript "qbittorrent-guest-ready" ''
                    set -eu
                    ${passwordSetup}
                    echo "Waiting for qBittorrent WebUI..."
                    for i in $(seq 1 300); do
                      ${
                        if hasPassword then
                          ''
                            RESPONSE=$(${pkgs.curl}/bin/curl -s --connect-timeout 1 --max-time 3 \
                              -d "username=${username}&password=$PASSWORD" \
                              "http://127.0.0.1:${toString port}/api/v2/auth/login" 2>/dev/null || echo "")
                            if [ "$RESPONSE" = "Ok." ]; then
                              echo "qBittorrent WebUI ready (authenticated)"
                              exit 0
                            fi
                            echo "Attempt $i/300 (response: $RESPONSE)"
                          ''
                        else
                          ''
                            HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                              --connect-timeout 1 --max-time 3 \
                              "http://127.0.0.1:${toString port}/" 2>/dev/null || echo "000")
                            if [ "$HTTP_CODE" = "200" ]; then
                              echo "qBittorrent WebUI ready"
                              exit 0
                            fi
                            echo "Attempt $i/300 (HTTP $HTTP_CODE)"
                          ''
                      }
                      sleep 1
                    done
                    echo "Timeout waiting for qBittorrent WebUI" >&2
                    exit 1
                  '';
                };
              };
            }
          )
        ];
      };

      nixflix.globals.serviceAddresses.qbittorrent = microvmCfg.address;

      systemd.services."microvm@qbittorrent" = mkIf (microvmCfg.startAfter != [ ]) {
        after = microvmCfg.startAfter;
        wants = microvmCfg.startAfter;
      };

      systemd.services = {
        qbittorrent = mkForce {
          description = "Wait for qBittorrent WebUI to be ready (host-side poll)";
          after = [ "microvm@qbittorrent.service" ];
          requires = [ "microvm@qbittorrent.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "600";
            ExecStart = pkgs.writeShellScript "qbittorrent-host-ready" ''
              set -eu
              echo "Waiting for qBittorrent WebUI at ${microvmCfg.address}..."
              for i in $(seq 1 120); do
                # GET / returns 200 (login page) without authentication, so the host
                # bridge IP does not need to be in the AuthSubnetWhitelist.
                HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                  --connect-timeout 2 --max-time 5 \
                  "http://${microvmCfg.address}:${toString cfg.webuiPort}/" \
                  2>/dev/null || echo "000")
                if [ "$HTTP_CODE" = "200" ]; then
                  echo "qBittorrent WebUI ready"
                  exit 0
                fi
                echo "Attempt $i/120 (HTTP $HTTP_CODE)"
                sleep 5
              done
              echo "Timeout waiting for qBittorrent WebUI" >&2
              exit 1
            '';
          };
        };

      };

      services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
        locations."/".proxyPass = mkForce "http://${microvmCfg.address}:${toString cfg.webuiPort}";
      };
    })
  ];
}
