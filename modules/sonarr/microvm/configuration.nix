# Guest NixOS configuration for the Sonarr microVM.
# Sonarr runs isolated here; postgres is in the postgres VM.
# apiKey, hostConfig, postgres TCP settings, rootFolders, and delayProfiles
# are pushed from the host via extraModules in arr-common/microvm.nix.
{ config, ... }:
{
  nixflix.sonarr.enable = true;

  # Bind on all interfaces so the host and bridge peers can reach the API
  nixflix.sonarr.settings.server.bindaddress = "*";

  # Persist sonarr state across VM reboots via virtiofs
  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/sonarr";
      mountPoint = "${config.nixflix.stateDir}/sonarr";
      tag = "nixflix-sonarr-state";
      proto = "virtiofs";
    }
  ];
}
