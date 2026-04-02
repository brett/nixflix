# Bare-metal nixflix configuration with microVM isolation.
#
# Extends hetzner-bare: each service runs in its own microVM instead of
# directly on the host. Arr services bypass Mullvad; qBittorrent routes
# through it.
#
# Targets Hetzner dedicated servers (legacy BIOS boot, SATA disk).
# Uses disko.nix (BIOS layout with EF02 partition) in flake.nix.
{ config, ... }:
{
  imports = [ ./hetzner-bare.nix ];

  nixpkgs.config.allowUnfree = true;

  sops.secrets = {
    qbittorrent_password = {
      sopsFile = ../secrets/admin.yaml;
    };
  };

  nixflix.microvm.enable = true;

  nixflix.postgres.enable = true;
  nixflix.postgres.microvm.enable = true;
  nixflix.postgres.microvm.memoryMB = 2048;

  nixflix.prowlarr.microvm.enable = true;
  nixflix.prowlarr.microvm.memoryMB = 2048;
  nixflix.sonarr.microvm.enable = true;
  nixflix.sonarr.microvm.memoryMB = 2048;
  nixflix.sonarr-anime.microvm.enable = true;
  nixflix.sonarr-anime.microvm.memoryMB = 2048;
  nixflix.radarr.microvm.enable = true;
  nixflix.radarr.microvm.memoryMB = 2048;
  nixflix.lidarr.microvm.enable = true;
  nixflix.lidarr.microvm.memoryMB = 2048;

  nixflix.torrentClients.qbittorrent.microvm.enable = true;
  nixflix.torrentClients.qbittorrent.microvm.memoryMB = 1024;
  # qbittorrent routes through Mullvad — don't start until VPN is connected.
  nixflix.torrentClients.qbittorrent.microvm.startAfter = [ "mullvad-config.service" ];
  nixflix.torrentClients.qbittorrent.password = {
    _secret = config.sops.secrets.qbittorrent_password.path;
  };

  nixflix.usenetClients.sabnzbd.microvm.enable = true;
  nixflix.usenetClients.sabnzbd.microvm.memoryMB = 1024;
  # sabnzbd routes through Mullvad — don't start until VPN is connected.
  nixflix.usenetClients.sabnzbd.microvm.startAfter = [ "mullvad-config.service" ];

  nixflix.jellyfin.enable = true;
  nixflix.jellyfin.microvm.enable = true;
  nixflix.jellyfin.microvm.memoryMB = 4096;
  nixflix.jellyfin.users.admin = {
    password = {
      _secret = config.sops.secrets.arr_admin_password.path;
    };
    policy.isAdministrator = true;
  };

  nixflix.seerr.enable = true;
  nixflix.seerr.microvm.enable = true;
  nixflix.seerr.microvm.memoryMB = 1536;
  nixflix.seerr.jellyfin.adminUsername = "admin";
  nixflix.seerr.jellyfin.adminPassword._secret = config.sops.secrets.arr_admin_password.path;
}
