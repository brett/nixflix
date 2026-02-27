# Guest NixOS configuration for the Jellyseerr microVM.
# Connection hostnames (Jellyfin, Radarr, Sonarr VM addresses) are pushed
# from the host via extraModules in jellyseerr/microvm/default.nix.
{ config, ... }:
{
  nixflix.jellyseerr.enable = true;

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/jellyseerr";
      mountPoint = "${config.nixflix.stateDir}/jellyseerr";
      tag = "nixflix-jellyseerr-state";
      proto = "virtiofs";
    }
  ];
}
