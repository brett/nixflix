# Guest NixOS configuration for the Sonarr-Anime microVM.
# apiKey, hostConfig, postgres TCP settings, rootFolders, and delayProfiles
# are pushed from the host via extraModules in arr-common/microvm.nix.
{ config, ... }:
{
  nixflix.sonarr-anime.enable = true;

  nixflix.sonarr-anime.settings.server.bindaddress = "*";

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/sonarr-anime";
      mountPoint = "${config.nixflix.stateDir}/sonarr-anime";
      tag = "nixflix-sonarranime-state";
      proto = "virtiofs";
    }
  ];
}
