{ config, lib, ... }:
with lib;
let
  mkBase =
    svc: addr:
    let
      h = config.nixflix.${svc}.config.hostConfig;
    in
    "http://${addr}:${toString h.port}${toString h.urlBase}";

  sonarrInVm = config.nixflix.sonarr.enable && config.nixflix.sonarr.microvm.enable;
  sonarrAnimeInVm =
    (config.nixflix.sonarr-anime.enable or false)
    && (config.nixflix.sonarr-anime.microvm.enable or false);
  radarrInVm = config.nixflix.radarr.enable && config.nixflix.radarr.microvm.enable;
in
{
  config = {
    nixflix.recyclarr.config.sonarr.sonarr.base_url = mkIf sonarrInVm (
      mkBase "sonarr" config.nixflix.sonarr.microvm.address
    );

    nixflix.recyclarr.config.sonarr.sonarr_anime.base_url = mkIf sonarrAnimeInVm (
      mkBase "sonarr-anime" config.nixflix.sonarr-anime.microvm.address
    );

    nixflix.recyclarr.config.radarr.radarr.base_url = mkIf radarrInVm (
      mkBase "radarr" config.nixflix.radarr.microvm.address
    );
  };
}
