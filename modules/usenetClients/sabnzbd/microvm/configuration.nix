# Guest NixOS configuration for the SABnzbd microVM.
# Binds on 0.0.0.0 so the host can reach it at the VM IP.
{ config, lib, ... }:
{
  nixflix.usenetClients.sabnzbd.enable = true;

  # Bind on all interfaces so the host bridge can reach the API
  nixflix.usenetClients.sabnzbd.settings.misc.host = lib.mkForce "0.0.0.0";

  # Persist SABnzbd state on the host via virtiofs.
  # source: host path where VM data is stored (outside /var/lib to avoid
  #         conflicts with any locally-disabled sabnzbd instance).
  # mountPoint: where sabnzbd expects its state inside the guest.
  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/sabnzbd";
      mountPoint = "/var/lib/sabnzbd";
      tag = "nixflix-sabnzbd-state";
      proto = "virtiofs";
    }
  ];
}
