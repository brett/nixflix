# Guest NixOS configuration for the qBittorrent microVM.
# Binds the WebUI on 0.0.0.0 so the host can reach it at the VM IP.
{ config, lib, ... }:
{
  nixflix.torrentClients.qbittorrent.enable = true;

  # Bind WebUI on all interfaces so the host bridge can reach it.
  nixflix.torrentClients.qbittorrent.serverConfig.Preferences.WebUI.Address = lib.mkForce "0.0.0.0";

  # Persist qBittorrent state on the host via virtiofs.
  # source: host path where VM data is stored (outside /var/lib to avoid
  #         conflicts with any locally-disabled qBittorrent instance).
  # mountPoint: services.qbittorrent.profileDir default (/var/lib/qBittorrent).
  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/qbittorrent";
      mountPoint = "/var/lib/qBittorrent";
      tag = "nixflix-qbittorrent-state";
      proto = "virtiofs";
    }
  ];
}
