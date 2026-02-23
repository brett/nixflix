{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  inherit (config) nixflix;
  indexers = import ./indexers.nix {
    inherit lib pkgs;
  };
  applications = import ./applications.nix {
    inherit lib pkgs config;
  };

  arrServices =
    optional nixflix.lidarr.enable "lidarr"
    ++ optional nixflix.radarr.enable "radarr"
    ++ optional nixflix.sonarr.enable "sonarr"
    ++ optional nixflix.sonarr-anime.enable "sonarr-anime";

  mkDefaultApplication =
    serviceName:
    let
      serviceConfig = nixflix.${serviceName}.config;
      # Convert service-name to "Service Name" format (e.g., "sonarr-anime" -> "Sonarr Anime")
      displayName = concatMapStringsSep " " (
        word: toUpper (builtins.substring 0 1 word) + builtins.substring 1 (-1) word
      ) (splitString "-" serviceName);

      # Map service names to their implementation names (for services with variants like sonarr-anime)
      serviceBase = builtins.elemAt (splitString "-" serviceName) 0;
      implementationName = toUpper (substring 0 1 serviceBase) + substring 1 (-1) serviceBase;

      useNginx = nixflix.nginx.enable or false;

      # Determine service address - use microVM IP if applicable, otherwise localhost
      serviceMicrovm =
        (nixflix.microvm.enable or false) && (nixflix.${serviceName}.microvm.enable or false);
      serviceAddress = if serviceMicrovm then nixflix.${serviceName}.microvm.address else "127.0.0.1";

      prowlarrMicrovm = (nixflix.microvm.enable or false) && (nixflix.prowlarr.microvm.enable or false);
      prowlarrAddress = if prowlarrMicrovm then nixflix.prowlarr.microvm.address else "127.0.0.1";

      # For inter-service URLs (Prowlarr→Sonarr sync), always use direct IP:port when
      # services are in microVMs. nginx runs on the host, not inside each service VM, so
      # the nginx-style URL (port 80, no explicit port) would hit the wrong machine.
      # nginx-style URLs are correct only when both nginx and the service share a host.
      baseUrl =
        if useNginx && !serviceMicrovm then
          "http://${serviceAddress}${serviceConfig.hostConfig.urlBase}"
        else
          "http://${serviceAddress}:${toString serviceConfig.hostConfig.port}${serviceConfig.hostConfig.urlBase}";
      prowlarrUrl =
        if useNginx && !prowlarrMicrovm then
          "http://${prowlarrAddress}${nixflix.prowlarr.config.hostConfig.urlBase}"
        else
          "http://${prowlarrAddress}:${toString nixflix.prowlarr.config.hostConfig.port}${nixflix.prowlarr.config.hostConfig.urlBase}";
    in
    mkIf (nixflix.${serviceName}.enable or false) {
      name = displayName;
      inherit implementationName;
      apiKey = mkDefault serviceConfig.apiKey;
      baseUrl = mkDefault baseUrl;
      prowlarrUrl = mkDefault prowlarrUrl;
    };

  defaultApplications = filter (app: app != { }) (map mkDefaultApplication arrServices);

  extraConfigOptions = {
    indexers = indexers.type;
    applications = applications.type;
  };
in
{
  imports = [
    (import ../arr-common/mkArrServiceModule.nix {
      inherit config lib pkgs;
    } "prowlarr" extraConfigOptions)
  ];

  config = {
    nixflix.prowlarr = {
      config = {
        apiVersion = lib.mkDefault "v1";
        hostConfig = {
          port = lib.mkDefault 9696;
          branch = lib.mkDefault "master";
        };
        applications = lib.mkDefault defaultApplications;
      };
    };

    # Run indexers/applications on the HOST (not inside guest VMs).
    # In microVM mode, the host reaches prowlarr via the bridge network.
    # prowlarr-config (also host-side) sets apiHost = VM IP when microvm.enable = true.
    systemd.services."prowlarr-indexers" = mkIf (
      nixflix.enable
      && nixflix.prowlarr.enable
      && nixflix.prowlarr.config.apiKey != null
      && !(config.nixflix.isGuest or false)
    ) (indexers.mkService nixflix.prowlarr.config);

    systemd.services."prowlarr-applications" = mkIf (
      nixflix.enable
      && nixflix.prowlarr.enable
      && nixflix.prowlarr.config.apiKey != null
      && !(config.nixflix.isGuest or false)
    ) (applications.mkService nixflix.prowlarr.config);
  };
}
