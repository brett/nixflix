{ lib, ... }:
with lib;
{
  options.nixflix.globals = mkOption {
    description = "Global values to be used by nixflix services";
    default = { };
    # freeform submodule: microVMHostConfigurations/serviceAddresses get typed options
    # so multiple modules can each add entries without `//` clobbering prior contributions.
    type = types.submodule {
      freeformType = types.attrs;

      options.microVMHostConfigurations = mkOption {
        type = types.attrsOf types.anything;
        default = { };
        description = ''
          MicroVM support: services register here to opt into VM isolation.
          Each entry maps a service name to { module, address, vcpus, memoryMB }.
          Uses attrsOf so that multiple modules can each add their own entry
          without overwriting the others.
        '';
      };

      options.serviceAddresses = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          MicroVM support: services register their VM address here.
          Used by downloadarr and other integrations to reach VM-isolated services.
        '';
      };
    };
  };

  config.nixflix.globals = {
    libraryOwner.user = "root";
    libraryOwner.group = "media";

    uids = {
      jellyfin = 146;
      autobrr = 188;
      bazarr = 232;
      lidarr = 306;
      prowlarr = 293;
      seerr = 262;
      sonarr = 274;
      sonarr-anime = 273;
      radarr = 275;
      recyclarr = 269;
      sabnzbd = 38;
      qbittorrent = 70;
      cross-seed = 183;
    };
    gids = {
      autobrr = 188;
      cross-seed = 183;
      jellyfin = 146;
      seerr = 250;
      media = 169;
      prowlarr = 287;
      recyclarr = 269;
    };
  };
}
