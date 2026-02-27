{ config, lib, ... }:
with lib;
let
  cfg = config.nixflix.microvm;
  # Parse "10.100.0.0/24" → base prefix "10.100.0"
  subnetBase = head (splitString "/" cfg.network.subnet);
  octets = splitString "." subnetBase;
  base = concatStringsSep "." (init octets);
  mkAddr = n: "${base}.${toString n}";
in
{
  options.nixflix.microvm.addresses = mkOption {
    type = types.attrsOf types.str;
    default = { };
    description = ''
      Static IP address table for nixflix microVM services.
      Defaults are derived from nixflix.microvm.network.subnet — changing
      the subnet prefix automatically updates all service addresses.
      Individual entries can be overridden if needed.
    '';
  };

  # Always available (not guarded by cfg.enable) so service options can reference them unconditionally.
  config.nixflix.microvm.addresses = {
    # Infrastructure
    postgres = mkDefault (mkAddr 2);
    # Arr services
    sonarr = mkDefault (mkAddr 10);
    sonarr-anime = mkDefault (mkAddr 11);
    radarr = mkDefault (mkAddr 12);
    lidarr = mkDefault (mkAddr 13);
    prowlarr = mkDefault (mkAddr 14);
    # Download clients
    sabnzbd = mkDefault (mkAddr 20);
    # Media
    jellyfin = mkDefault (mkAddr 30);
    jellyseerr = mkDefault (mkAddr 31);
  };
}
