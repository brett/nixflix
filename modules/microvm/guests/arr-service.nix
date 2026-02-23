# MicroVM guest configuration for *arr services
# Supports: sonarr, sonarr-anime, radarr, lidarr, prowlarr

{
  config,
  lib,
  pkgs,
  serviceName,
  microvm,
  ...
}:

with lib;

let
  # Host config (accessed from the host's nixflix config)
  hostConfig = config;
  microvmCfg = hostConfig.nixflix.microvm;
  svcCfg = hostConfig.nixflix.${serviceName};
  stateDir = "${hostConfig.nixflix.stateDir}/${serviceName}";

  # Generate MAC address deterministically from service name
  # This ensures the same service always gets the same MAC
  generateMac =
    name:
    let
      hash = builtins.hashString "sha256" name;
      # Take first 10 hex chars and format as MAC
      macSuffix = substring 0 10 hash;
    in
    "02:00:00:${substring 0 2 macSuffix}:${substring 2 2 macSuffix}:${substring 4 2 macSuffix}";
in
{
  # MicroVM configuration
  autostart = true;
  restartIfChanged = true;

  config = {
    imports = [
      # Import microvm module for guest VM support
      microvm.nixosModules.microvm

      # Import the main nixflix module to get the service
      (import ../../default.nix { microvm = null; })

      # Import common guest configuration
      # Call the function with custom args to get a NixOS module
      (import ../common-guest.nix {
        inherit hostConfig serviceName;
      })
    ];

    # Add PostgreSQL client tools for database connectivity checks
    environment.systemPackages = mkIf hostConfig.services.postgresql.enable [
      pkgs.postgresql
    ];

    # Enable only this specific service in the guest
    nixflix = mkMerge [
      {
        # Mark as a guest VM — suppresses host-only services (e.g. prowlarr-config)
        # that must run on the host where they can reach VM IPs via the bridge.
        isGuest = true;

        enable = true;
        ${serviceName} = {
          enable = true;

          # Run as the service-specific user (for correct UID) but shared media group
          # so all services can share files in the media and downloads directories.
          inherit (svcCfg) user;
          group = "media";

          # Inherit service configuration from host (apiKey, hostConfig, etc.)
          inherit (svcCfg) config;

          # Override settings for microVM guest environment
          settings = {
            # Bind to all interfaces so the host and other microVMs can reach this service
            server.bindaddress = "*";
          }
          // optionalAttrs hostConfig.nixflix.postgres.enable {
            # Connect to PostgreSQL microVM via TCP (not local socket)
            log.dbEnabled = true;
            postgres = {
              inherit (svcCfg) user;
              host = microvmCfg.addresses.postgres; # Connect to PostgreSQL microVM
              port = 5432;
              mainDb = svcCfg.user;
              logDb = "${svcCfg.user}-logs";
            };
          };
        };

        # Use the same directories as the host
        inherit (hostConfig.nixflix) mediaDir downloadsDir stateDir;

        # Copy relevant host configuration
        inherit (hostConfig.nixflix) serviceDependencies;

        # Note: microVM options don't exist in guest since we import nixflix with microvm = null
      }

      # Set apiHost to the VM's own static IP so that wait-for-api scripts and
      # config scripts connect to the service via its network address rather than
      # 127.0.0.1. Kestrel with bindAddress=* does not reliably serve on the
      # loopback interface inside a microVM, so we use the actual VM IP instead.
      {
        ${serviceName}.config.hostConfig.apiHost = mkForce microvmCfg.addresses.${serviceName};
      }

      # When running as the Prowlarr guest VM, force the applications list to
      # the host's pre-computed value. prowlarr/default.nix re-evaluates
      # mkDefaultApplication in the guest context where sonarr/radarr/lidarr
      # are not enabled (arrServices = []), producing an empty list. Using
      # mkForce ensures the host's correctly-computed list (with direct
      # microVM IP:port addresses) is used instead.
      (mkIf (serviceName == "prowlarr") {
        prowlarr.config.applications = mkForce hostConfig.nixflix.prowlarr.config.applications;
      })
    ];

    # Override PostgreSQL connection for TCP when host has PostgreSQL
    # Don't run PostgreSQL in guest
    services.postgresql.enable = mkForce false;

    # Create database wait service for PostgreSQL microVM
    # This service waits for the PostgreSQL microVM to be ready via TCP
    systemd.services = mkIf hostConfig.nixflix.postgres.enable {
      "${serviceName}-wait-for-db" = {
        description = "Wait for ${serviceName} PostgreSQL databases on postgres microVM";
        after = [ "network.target" ];
        before = [ "${serviceName}.service" ];
        requiredBy = [ "${serviceName}.service" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "5min";
          User = svcCfg.user;
          Group = "media";
        };

        script = ''
          echo "Starting database connection check to ${microvmCfg.addresses.postgres}:5432"
          echo "Testing with user: ${svcCfg.user}, database: ${svcCfg.user}"

          # Wait for network to be fully up
          sleep 5

          while true; do
            echo "Attempting connection to main database..."
            if ${pkgs.postgresql}/bin/psql \
               -h ${microvmCfg.addresses.postgres} \
               -p 5432 \
               -U ${svcCfg.user} \
               -d ${svcCfg.user} \
               -c "SELECT 1" > /dev/null 2>&1; then
              echo "Main database connection successful!"

              echo "Attempting connection to logs database..."
              if ${pkgs.postgresql}/bin/psql \
                 -h ${microvmCfg.addresses.postgres} \
                 -p 5432 \
                 -U ${svcCfg.user} \
                 -d ${svcCfg.user}-logs \
                 -c "SELECT 1" > /dev/null 2>&1; then
                echo "Logs database connection successful!"
                echo "${serviceName} PostgreSQL databases are ready on postgres microVM"
                exit 0
              else
                echo "Logs database connection failed, retrying..."
              fi
            else
              echo "Main database connection failed, retrying..."
            fi

            echo "Waiting for ${serviceName} PostgreSQL databases on postgres microVM..."
            sleep 2
          done
        '';
      };
    };

    # Hypervisor selection
    microvm.hypervisor = microvmCfg.hypervisor;

    # vCPUs and memory
    microvm.vcpu = svcCfg.microvm.vcpus or microvmCfg.defaults.vcpus;
    microvm.mem = svcCfg.microvm.memoryMB or microvmCfg.defaults.memoryMB;

    # Network interfaces
    # Use "tap" type for virtio-mmio (compatible with microvm machine type)
    # The TAP interface will be automatically attached to the bridge by systemd-networkd on the host
    microvm.interfaces = [
      {
        type = "tap";
        id = "vm-${serviceName}";
        mac = generateMac serviceName;
      }
    ];

    # Storage shares are configured in common-guest.nix via microvm.shares
  };
}
