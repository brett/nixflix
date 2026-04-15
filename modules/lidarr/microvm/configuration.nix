# Guest NixOS configuration for the Lidarr microVM.
# apiKey, hostConfig, postgres TCP settings, rootFolders, and delayProfiles
# are pushed from the host via extraModules in arr-common/microvm.nix.
{ config, ... }:
{
  nixflix.lidarr.enable = true;

  nixflix.lidarr.settings.server.bindaddress = "*";

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/lidarr";
      mountPoint = "${config.nixflix.stateDir}/lidarr";
      tag = "nixflix-lidarr-state";
      proto = "virtiofs";
    }
  ];
}
