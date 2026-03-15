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
  hasPassword = cfg.password != null;
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
      default = 1024;
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
      # virtiofsd shares this directory into the VM as /var/lib/qBittorrent.
      # Must exist on the host before the VM starts.
      systemd.tmpfiles.settings."10-nixflix-qbittorrent" = {
        "${config.nixflix.stateDir}/qbittorrent".d = {
          user = "qbittorrent";
          group = "media";
          mode = "0755";
        };
      };

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
                  [ "sonarr" "sonarr-anime" "radarr" "lidarr" "prowlarr" ];
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
              # LocalhostAuth=false lets the guest-side setup service call the API to
              # apply the WebUI password without needing to authenticate first.
              serverConfig = lib.recursiveUpdate cfg.serverConfig {
                Preferences.WebUI.AuthSubnetWhitelistEnabled = true;
                Preferences.WebUI.AuthSubnetWhitelist = lib.concatStringsSep ","
                  (lib.filter (s: s != "") (map (svc:
                    if (config.nixflix.${svc}.enable or false) && (config.nixflix.${svc}.microvm.enable or false)
                    then config.nixflix.${svc}.microvm.address
                    else ""
                  ) [ "sonarr" "sonarr-anime" "radarr" "lidarr" "prowlarr" ]));
                Preferences.WebUI.LocalhostAuth = false;
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
                    echo "Waiting for qBittorrent WebUI..."
                    for i in $(seq 1 300); do
                      # LocalhostAuth=false means 127.0.0.1 bypasses auth; root returns 200.
                      # || echo "000": curl exits non-zero when refused; set -eu would kill the loop.
                      HTTP_CODE=$(${pkgs.curl}/bin/curl -s -o /dev/null -w "%{http_code}" \
                        --connect-timeout 1 --max-time 3 \
                        "http://127.0.0.1:${toString port}/" 2>/dev/null || echo "000")
                      if [ "$HTTP_CODE" = "200" ]; then
                        echo "qBittorrent WebUI ready"
                        exit 0
                      fi
                      echo "Attempt $i/300 (HTTP $HTTP_CODE)"
                      sleep 1
                    done
                    echo "Timeout waiting for qBittorrent WebUI" >&2
                    exit 1
                  '';
                };
              };
            }
          )
          # Guest-side password setup: compute PBKDF2 hash and write to config before qBittorrent starts.
          # nixpkgs writes the config via tmpfiles L+ (symlink to nix store, read-only) each boot.
          # qbittorrent-password-init runs as root after tmpfiles, replaces the symlink with a writable
          # file containing the PBKDF2 hash derived from the sops secret in /run/secrets.
          # /run/secrets is shared from the host into every guest via common-guest.nix.
          (
            { pkgs, lib, ... }:
            let
              secretPath = toString cfg.password._secret;
              needsRunSecrets = lib.hasPrefix "/run/secrets" secretPath;
              setPasswordScript = pkgs.writeText "qbt-set-password.py" ''
                import os, hashlib, base64, re

                config_file = '/var/lib/qBittorrent/qBittorrent/config/qBittorrent.conf'

                with open('${secretPath}', 'rb') as f:
                    password = f.read().rstrip(b'\n\r')

                # PBKDF2 params from qBittorrent source (password.cpp):
                # hashIterations=100000, hashMethod=EVP_sha512(), salt=16 bytes, key=64 bytes
                salt = os.urandom(16)
                key = hashlib.pbkdf2_hmac('sha512', password, salt, 100000, 64)
                pbkdf2_value = '@ByteArray(' + base64.b64encode(salt).decode() + ':' + base64.b64encode(key).decode() + ')'

                try:
                    with open(config_file, 'r') as f:
                        content = f.read()
                except FileNotFoundError:
                    content = ""

                content = re.sub(r'WebUI\\Password_PBKDF2=[^\n]*\n?', "", content)

                pbkdf2_line = 'WebUI\\Password_PBKDF2=' + pbkdf2_value + '\n'
                if '[Preferences]' in content:
                    # Use a lambda so the replacement is not scanned for backreferences.
                    # re.sub treats '\P' in a plain string as an invalid escape in Python 3.12+.
                    insert = '[Preferences]\n' + pbkdf2_line
                    content = re.sub(r'\[Preferences\]\n', lambda m: insert, content, count=1)
                else:
                    content += '\n[Preferences]\n' + pbkdf2_line

                # config_file may be a symlink to the read-only nix store (written by
                # systemd-tmpfiles C+ on each boot). Unlink it so we can write a regular file.
                if os.path.islink(config_file):
                    os.unlink(config_file)

                with open(config_file, 'w') as f:
                    f.write(content)

                print('qBittorrent password hash written to config')
              '';
            in
            lib.mkIf hasPassword {
              # Run as root (no User= set) so we can read the secret and
              # unlink the nixpkgs-created symlink to the read-only nix store.
              # Must run after:
              #   - systemd-tmpfiles-setup: creates the L+ symlink we need to replace
              #   - run-secrets.mount (only when secret is under /run/secrets):
              #     virtiofs share providing the secret file
              systemd.services.qbittorrent-password-init = {
                description = "Initialize qBittorrent WebUI password (PBKDF2 hash)";
                wantedBy = [ "multi-user.target" ];
                before = [ "qbittorrent.service" ];
                after = [ "systemd-tmpfiles-setup.service" ]
                  ++ lib.optional needsRunSecrets "run-secrets.mount";
                requires = lib.optional needsRunSecrets "run-secrets.mount";
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = pkgs.writeShellScript "qbt-password-init" ''
                    set -eu
                    ${pkgs.python3}/bin/python3 ${setPasswordScript}
                  '';
                };
              };
              systemd.services.qbittorrent = {
                after = [ "qbittorrent-password-init.service" ];
                requires = [ "qbittorrent-password-init.service" ];
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
