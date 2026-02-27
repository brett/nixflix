# Guest NixOS configuration for the Jellyfin microVM.
# users/system/network/branding/encoding/libraries are injected via host extraModules.
{ config, lib, ... }:
{
  nixflix.jellyfin.enable = true;

  # Transcode segments are temporary but land in cacheDir (virtiofs-backed).
  # Enable segment deletion so finished segments don't accumulate on the host.
  nixflix.jellyfin.encoding.enableSegmentDeletion = true;

  # Jellyfin 10.11.6+ requires ≥2 GiB free on both data AND cache dirs.
  # Redirect cache to virtiofs-backed path so statfs() reports host disk space
  # instead of the guest tmpfs (which is bounded by VM RAM).
  nixflix.jellyfin.cacheDir = "${config.nixflix.stateDir}/jellyfin/cache";

  # The inherited cachePath points to the host's /var/cache/jellyfin, which doesn't exist
  # in the guest. Jellyfin rejects POST /System/Configuration if CachePath is missing.
  nixflix.jellyfin.system.cachePath = lib.mkForce "${config.nixflix.stateDir}/jellyfin/cache";

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/jellyfin";
      mountPoint = "${config.nixflix.stateDir}/jellyfin";
      tag = "nixflix-jellyfin-state";
      proto = "virtiofs";
    }
  ];
}
