# MicroVM support module entry point.
# Accepts the microvm flake input and returns a NixOS module.
#
# Usage in user's NixOS configuration:
#   imports = [
#     nixflix.nixosModules.default   # standard nixflix (unchanged)
#     nixflix.nixosModules.microvm   # opt-in microvm support
#   ];
{ microvm }:
{ ... }:
{
  imports = [
    # Infrastructure (service-agnostic)
    ./options.nix
    ./addresses.nix
    (import ./host.nix { inherit microvm; })
    ./network.nix
    ./vpn-routing.nix
    ./recyclarr.nix

    # Service microvm registrations
    ../downloadarr/microvm
    ../jellyfin/microvm
    ../seerr/microvm
    ../lidarr/microvm
    ../postgres/microvm
    ../prowlarr/microvm
    ../radarr/microvm
    ../sonarr/microvm
    ../sonarr-anime/microvm
    ../usenetClients/sabnzbd/microvm
    ../torrentClients/qbittorrent/microvm
  ];
}
