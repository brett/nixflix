# Guest NixOS configuration for the Seerr microVM.
# Connection hostnames (Jellyfin, Radarr, Sonarr VM addresses) are pushed
# from the host via extraModules in seerr/microvm/default.nix.
{ config, ... }:
{
  nixflix.seerr.enable = true;

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/seerr";
      mountPoint = "${config.nixflix.stateDir}/seerr";
      tag = "nixflix-seerr-state";
      proto = "virtiofs";
    }
  ];
}
