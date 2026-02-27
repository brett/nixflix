# Guest NixOS configuration for the Prowlarr microVM.
# Since arr services aren't enabled here, defaultApplications = [].
# VM-addressed application registrations are pushed from the host via extraModules
# in prowlarr/microvm/default.nix. prowlarr-config and prowlarr-applications
# run inside this VM once apiKey and applications are available.
{ config, ... }:
{
  nixflix.prowlarr.enable = true;

  # Bind on all interfaces so host can reach the API
  nixflix.prowlarr.settings.server.bindaddress = "*";

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/prowlarr";
      mountPoint = "${config.nixflix.stateDir}/prowlarr";
      tag = "nixflix-prowlarr-state";
      proto = "virtiofs";
    }
  ];
}
