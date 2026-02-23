# Static IP address mapping for microVM services
# Each service gets a predictable IP within the configured subnet

{ config, lib, ... }:

with lib;

let
  cfg = config.nixflix.microvm;

  # Parse the subnet to get the base network
  # Default: 10.100.0.0/24 -> 10.100.0
  subnetParts = splitString "/" cfg.network.subnet;
  networkPrefix = head subnetParts;
  baseOctets = init (splitString "." networkPrefix);
  baseNetwork = concatStringsSep "." baseOctets;

  # Helper to build IP address
  mkAddress = lastOctet: "${baseNetwork}.${toString lastOctet}";
in
{
  options.nixflix.microvm.addresses = mkOption {
    type = types.attrsOf types.str;
    readOnly = true;
    description = "Static IP address mapping for each microVM service";
  };

  config = mkIf cfg.enable {
    nixflix.microvm.addresses = {
      # *arr services
      sonarr = mkDefault (mkAddress 10);
      sonarr-anime = mkDefault (mkAddress 11);
      radarr = mkDefault (mkAddress 12);
      lidarr = mkDefault (mkAddress 13);
      prowlarr = mkDefault (mkAddress 14);

      # Download client
      sabnzbd = mkDefault (mkAddress 20);

      # Media services
      jellyfin = mkDefault (mkAddress 30);
      jellyseerr = mkDefault (mkAddress 31);

      # Database (if running in microVM)
      postgres = mkDefault (mkAddress 2);
    };
  };
}
