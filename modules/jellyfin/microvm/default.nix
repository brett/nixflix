{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.jellyfin;
  microvmCfg = cfg.microvm;
  isEnabled = cfg.enable && microvmCfg.enable;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";
in
{
  options.nixflix.jellyfin.microvm = {
    enable = mkEnableOption "Jellyfin microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.jellyfin;
      description = "Static IP address for the Jellyfin microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = 2;
      description = "Number of vCPUs for the Jellyfin microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = 1024;
      description = "Memory in MB for the Jellyfin microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Systemd units added to After= and Wants= on the host-side
        microvm@jellyfin.service drop-in. Defaults to empty (starts immediately)
        since Jellyfin has no dependency on PostgreSQL or other microVMs.
      '';
    };

  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.jellyfin.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      nixflix.globals.microVMHostConfigurations.jellyfin = {
        module = ./configuration.nix;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        # Jellyfin serves media and fetches metadata; VPN would block image providers.
        vpnBypass = true;
        # Jellyfin streams media but never writes to the media directory
        # (metadata and thumbnails go to its own state dir). Mount read-only
        # so a compromised Jellyfin process can't modify the media library.
        readOnlyMedia = true;
        needsDownloads = false;
        extraModules = [
          {
            networking.firewall.extraInputRules =
              let
                port = toString cfg.network.internalHttpPort;
                hostAddr = config.nixflix.microvm.network.hostAddress;
                jellyseerrSuffix = optionalString
                  (config.nixflix.jellyseerr.enable && config.nixflix.jellyseerr.microvm.enable)
                  ", ${config.nixflix.jellyseerr.microvm.address}";
              in
              ''
                ip saddr { ${hostAddr}${jellyseerrSuffix} } tcp dport ${port} accept
              '';
          }
          {
            nixflix.jellyfin = {
              inherit (cfg)
                users
                system
                branding
                encoding
                libraries
                ;
              # localNetworkAddresses defaults to ["127.0.0.1"] in nginx-proxy mode, which
              # restricts Kestrel to loopback. Add the bridge IP for host access, keep
              # 127.0.0.1 for in-guest services, and disable virtual-interface filtering.
              network = cfg.network // {
                localNetworkAddresses = [
                  microvmCfg.address
                  "127.0.0.1"
                ];
                ignoreVirtualInterfaces = false;
              };
            };

            # Forward to console so Jellyfin startup messages appear in the test log.
            systemd.services.jellyfin.serviceConfig.StandardOutput = lib.mkForce "journal+console";
            systemd.services.jellyfin.serviceConfig.StandardError = lib.mkForce "journal+console";
          }
        ];
      };

      nixflix.globals.serviceAddresses.jellyfin = microvmCfg.address;

      # Jellyfin first-boot (DB init, plugin discovery) can take many minutes in nested KVM.
      # Bump the notify timeout so the VM isn't killed before multi-user.target fires.
      systemd.services."microvm@jellyfin" = mkMerge [
        (mkIf (microvmCfg.startAfter != [ ]) {
          after = microvmCfg.startAfter;
          wants = microvmCfg.startAfter;
        })
        { serviceConfig.TimeoutStartSec = mkForce "1800"; }
      ];

      systemd.services = {
        jellyfin = mkForce {
          description = "Wait for Jellyfin HTTP API to be ready (host-side poll)";
          after = [ "microvm@jellyfin.service" ];
          requires = [ "microvm@jellyfin.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "900";
            ExecStart = pkgs.writeShellScript "jellyfin-host-ready" ''
              set -eu
              echo "Waiting for Jellyfin HTTP API at ${microvmCfg.address}..."
              for i in $(seq 1 180); do
                if ${pkgs.curl}/bin/curl -sf --connect-timeout 2 --max-time 5 \
                  "http://${microvmCfg.address}:${toString cfg.network.internalHttpPort}/System/Info/Public" \
                  >/dev/null 2>&1; then
                  echo "Jellyfin API ready"
                  exit 0
                fi
                echo "Attempt $i/180"
                sleep 5
              done
              echo "Timeout waiting for Jellyfin API" >&2
              exit 1
            '';
          };
        };

        jellyfin-setup-wizard = mkForce {
          description = "Jellyfin setup wizard (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyfin-branding-config = mkForce {
          description = "Jellyfin branding config (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyfin-system-config = mkForce {
          description = "Jellyfin system config (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyfin-users-config = mkForce {
          description = "Jellyfin users config (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyfin-libraries = mkForce {
          description = "Jellyfin libraries (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };
        jellyfin-encoding-config = mkForce {
          description = "Jellyfin encoding config (delegating to microVM)";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

      };

      services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
        locations."/".proxyPass =
          mkForce "http://${microvmCfg.address}:${toString cfg.network.internalHttpPort}";
        locations."/socket".proxyPass =
          mkForce "http://${microvmCfg.address}:${toString cfg.network.internalHttpPort}";
      };

      nixflix.jellyseerr.jellyfin.hostname = mkIf config.nixflix.jellyseerr.enable microvmCfg.address;
    })
  ];
}
