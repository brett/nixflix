{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  secrets = import ../../../lib/secrets { inherit lib; };
in
{
  imports = [
    ./jellyfin.nix
    ./radarr.nix
    ./sonarr.nix
    ./users.nix
  ];

  options.nixflix.jellyseerr = {
    enable = mkEnableOption "Jellyseerr media request manager";

    package = lib.mkOption {
      type = lib.types.package;
      # Jellyseerr 2.7.3 only sends X-Emby-Authorization, which Jellyfin 10.12+ ignores
      # (enableLegacyAuthorization defaults to false). Remove once nixpkgs ships Seerr v3.0.0 (#58).
      default = pkgs.jellyseerr.overrideAttrs (old: {
        postInstall =
          (old.postInstall or "")
          + ''
            substituteInPlace $out/share/dist/api/jellyfin.js \
              --replace-fail \
                "'X-Emby-Authorization': authHeaderVal," \
                "'X-Emby-Authorization': authHeaderVal, Authorization: authHeaderVal,"
          '';
      });
      defaultText = lib.literalExpression "pkgs.jellyseerr (patched for Jellyfin auth)";
      description = "Jellyseerr package to use.";
    };

    apiKey = secrets.mkSecretOption {
      nullable = true;
      default = null;
      description = "API key for Jellyseerr.";
    };

    externalUrlScheme = mkOption {
      type = types.str;
      default = "http";
      example = "https";
      description = ''
        Scheme to use for external linking to other services
        from within Jellyseerr.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "jellyseerr";
      description = "User under which the service runs";
    };

    group = mkOption {
      type = types.str;
      default = "jellyseerr";
      description = "Group under which the service runs";
    };

    dataDir = mkOption {
      type = types.path;
      default = "${config.nixflix.stateDir}/jellyseerr";
      defaultText = literalExpression ''"''${nixflix.stateDir}/jellyseerr"'';
      description = "Directory containing jellyseerr data and configuration";
    };

    port = mkOption {
      type = types.port;
      default = 5055;
      description = "Port on which jellyseerr listens";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open port in firewall for jellyseerr";
    };

    subdomain = mkOption {
      type = types.str;
      default = "jellyseerr";
      description = "Subdomain prefix for nginx reverse proxy.";
    };

    vpn = {
      enable = mkOption {
        type = types.bool;
        default = config.nixflix.mullvad.enable;
        defaultText = literalExpression "config.nixflix.mullvad.enable";
        description = ''
          Whether to route Jellyseerr traffic through the VPN.
          When true (default), Jellyseerr routes through the VPN (requires nixflix.mullvad.enable = true).
          When false, Jellyseerr bypasses the VPN.
        '';
      };
    };
  };
}
