{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  inherit (config.nixflix) globals;
  cfg = config.nixflix;
in
{
  imports = [
    ./downloadarr
    ./globals.nix
    ./jellyfin
    ./jellyseerr
    ./lidarr.nix
    ./mullvad.nix
    ./postgres.nix
    ./prowlarr
    ./radarr.nix
    ./recyclarr
    ./sonarr-anime.nix
    ./sonarr.nix
    ./torrentClients
    ./usenetClients
  ];

  options.nixflix = {
    enable = mkEnableOption "Nixflix";

    serviceDependencies = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "unlock-raid.service"
        "tailscale.service"
      ];
      description = ''
        List of systemd services that nixflix services should wait for before starting.
        Useful for mounting encrypted drives, starting VPNs, or other prerequisites.
      '';
    };

    theme = {
      enable = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = ''
          Enables themeing via [theme.park](https://docs.theme-park.dev/).
          Requires `nixflix.nginx.enable = true;` for all services except Jellyfin.
        '';
      };
      name = mkOption {
        type = types.str;
        default = "overseerr";
        description = ''
          The name of any official theme or community theme supported by theme.park.

          - [Official Themes](https://docs.theme-park.dev/theme-options/)
          - [Community Themes](https://docs.theme-park.dev/community-themes/)
        '';
      };
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable nginx reverse proxy for all services";
      };

      domain = mkOption {
        type = types.str;
        default = "nixflix";
        example = "internal";
        description = "Base domain for subdomain-based reverse proxy routing. Each service is accessible at `<subdomain>.<domain>`.";
      };

      addHostsEntries = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to add `networking.hosts` entries mapping service subdomains to `127.0.0.1`.

          Enable if you don't have a separate DNS setup.
        '';
      };

      acme = {
        enable = mkEnableOption "ACME/Let's Encrypt TLS certificates for all nixflix nginx virtual hosts";

        email = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "admin@example.com";
          description = ''
            Email address for Let's Encrypt certificate registration and renewal
            notifications. Required when `nixflix.nginx.acme.enable` is true.
          '';
        };
      };
    };

    mediaUsers = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "user" ];
      description = ''
        Extra users to add to the media group.
      '';
    };

    mediaDir = mkOption {
      type = types.path;
      default = "/data/media";
      example = "/data/media";
      description = ''
        The location of the media directory for the services.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        > mediaDir = /home/user/data
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };

    downloadsDir = mkOption {
      type = types.path;
      default = "/data/downloads";
      example = "/data/downloads";
      description = ''
        The location of the downloads directory for download clients.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        > downloadsDir = /home/user/downloads
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };

    stateDir = mkOption {
      type = types.path;
      default = "/data/.state";
      example = "/data/.state";
      description = ''
        The location of the state directory for the services.

        > **Warning:** Setting this to any path, where the subpath is not
        > owned by root, will fail! For example:
        >
        > ```nix
        > stateDir = /home/user/data/.state
        > ```
        >
        > Is not supported, because `/home/user` is owned by `user`.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.nginx.acme.enable || cfg.nginx.acme.email != null;
        message = "nixflix.nginx.acme.email must be set when nixflix.nginx.acme.enable is true";
      }
    ];

    users.groups.media.members = cfg.mediaUsers;

    systemd.tmpfiles.settings."10-nixflix" = {
      "${cfg.stateDir}".d = {
        mode = "0755";
        user = "root";
        group = "root";
      };
      "${cfg.mediaDir}".d = {
        mode = "0774";
        inherit (globals.libraryOwner) user;
        inherit (globals.libraryOwner) group;
      };
      "${cfg.downloadsDir}".d = {
        mode = "0774";
        inherit (globals.libraryOwner) user;
        inherit (globals.libraryOwner) group;
      };
    };

    systemd.services.nixflix-setup-dirs = {
      description = "Create tmp files";
      after = [ "systemd-tmpfiles-setup.service" ];
      requires = [ "systemd-tmpfiles-setup.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        ${pkgs.systemd}/bin/systemd-tmpfiles --create
      '';
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.nginx.enable [ 80 443 ];

    security.acme = mkIf (cfg.nginx.enable && cfg.nginx.acme.enable) {
      acceptTerms = true;
      defaults.email = cfg.nginx.acme.email;
    };

    services.nginx = mkIf cfg.nginx.enable {
      enable = true;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;

      virtualHosts."_" = {
        default = true;
        extraConfig = ''
          return 444;
        '';
      };
    };
  };
}
