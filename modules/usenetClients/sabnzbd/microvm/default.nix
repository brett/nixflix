{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  secrets = import ../../../../lib/secrets { inherit lib; };
  cfg = config.nixflix.usenetClients.sabnzbd;
  microvmCfg = cfg.microvm;
  isEnabled = cfg.enable && microvmCfg.enable;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";
in
{
  options.nixflix.usenetClients.sabnzbd.microvm = {
    enable = mkEnableOption "SABnzbd microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.sabnzbd;
      description = "Static IP address for the SABnzbd microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the SABnzbd microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = 1024;
      description = "Memory in MB for the SABnzbd microVM";
    };

    startAfter = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Systemd units added to After= and Wants= on the host-side microvm@sabnzbd.service drop-in. Defaults to empty (starts immediately).";
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.usenetClients.sabnzbd.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      # virtiofsd shares this directory into the VM as /var/lib/sabnzbd.
      # Must exist on the host before the VM starts.
      systemd.tmpfiles.settings."10-nixflix-sabnzbd" = {
        "${config.nixflix.stateDir}/sabnzbd".d = {
          user = "sabnzbd";
          group = "media";
          mode = "0755";
        };
      };

      nixflix.globals.microVMHostConfigurations.sabnzbd = {
        module = ./configuration.nix;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        # Usenet traffic must route through the VPN.
        vpnBypass = false;
        # Downloads land in downloadsDir; arr services move files to mediaDir.
        needsMedia = false;
        extraModules = [
          {
            networking.firewall.extraInputRules =
              let
                port = toString cfg.settings.misc.port;
                hostAddr = config.nixflix.microvm.network.hostAddress;
                arrSuffixes =
                  concatMapStrings
                    (
                      svc:
                      optionalString (config.nixflix.${svc}.enable && config.nixflix.${svc}.microvm.enable)
                        ", ${config.nixflix.${svc}.microvm.address}"
                    )
                    [
                      "sonarr"
                      "sonarr-anime"
                      "radarr"
                      "lidarr"
                      "prowlarr"
                    ];
              in
              ''
                ip saddr { ${hostAddr}${arrSuffixes} } tcp dport ${port} accept
              '';
          }
          {
            nixflix.usenetClients.sabnzbd = {
              inherit (cfg) settings;
              inherit (cfg) downloadsDir;
            };

            # sabnzbd-categories.service has wantedBy=multi-user.target, which gates vsock
            # READY=1 on API polling (30 x 15s = up to 450s of guest time). Strip wantedBy
            # so multi-user.target is not blocked; pull the job via sabnzbd.service instead.
            systemd.services.sabnzbd-categories.wantedBy = lib.mkForce [ ];
            systemd.services.sabnzbd.wants = [ "sabnzbd-categories.service" ];
          }
        ];
      };

      nixflix.globals.serviceAddresses.sabnzbd = microvmCfg.address;

      systemd.services."microvm@sabnzbd" = {
        after = mkIf (microvmCfg.startAfter != [ ]) microvmCfg.startAfter;
        wants = mkIf (microvmCfg.startAfter != [ ]) microvmCfg.startAfter;
      };

      systemd.services = {
        sabnzbd = mkForce {
          description = "SABnzbd (running in microVM at ${microvmCfg.address})";
          after = [ "microvm@sabnzbd.service" ];
          requires = [ "microvm@sabnzbd.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig =
            let
              inherit (cfg.settings.misc) port;
              urlBase = cfg.settings.misc.url_base;
              apiKey = cfg.settings.misc.api_key;
            in
            {
              Type = "oneshot";
              RemainAfterExit = true;
              # Single attempt per start; systemd retries at RestartSec=3s (up to StartLimitBurst=20 times).
              ExecStart = pkgs.writeShellScript "sabnzbd-host-ready" ''
                set -eu
                API_KEY=${secrets.toShellValue apiKey}
                ${pkgs.curl}/bin/curl -sf --connect-timeout 3 --max-time 10 \
                  "http://${microvmCfg.address}:${toString port}${urlBase}/api?mode=version&apikey=$API_KEY" \
                  -o /dev/null
              '';
              Restart = "on-failure";
              RestartSec = "3s";
              StartLimitBurst = 20;
              StartLimitIntervalSec = "120";
            };
        };

      };

      systemd.services."sonarr-downloadclients" = mkIf config.nixflix.sonarr.enable {
        after = [ "sabnzbd.service" ];
      };
      systemd.services."radarr-downloadclients" = mkIf config.nixflix.radarr.enable {
        after = [ "sabnzbd.service" ];
      };
      systemd.services."lidarr-downloadclients" = mkIf config.nixflix.lidarr.enable {
        after = [ "sabnzbd.service" ];
      };
      systemd.services."sonarr-anime-downloadclients" = mkIf config.nixflix.sonarr-anime.enable {
        after = [ "sabnzbd.service" ];
      };

      services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
        locations."/".proxyPass = mkForce "http://${microvmCfg.address}:${toString cfg.settings.misc.port}";
      };
    })
  ];
}
