# Guest NixOS configuration for the Radarr microVM.
# apiKey, hostConfig, postgres TCP settings, rootFolders, and delayProfiles
# are pushed from the host via extraModules in arr-common/microvm.nix.
{ config, ... }:
{
  nixflix.radarr.enable = true;

  nixflix.radarr.settings.server.bindaddress = "*";

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/radarr";
      mountPoint = "${config.nixflix.stateDir}/radarr";
      tag = "nixflix-radarr-state";
      proto = "virtiofs";
    }
  ];
}
