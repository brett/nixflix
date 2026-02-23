# MicroVM guest configuration for PostgreSQL
# Runs PostgreSQL in an isolated microVM for all *arr services to connect to

{
  config,
  lib,
  pkgs,
  microvm,
  ...
}:

with lib;

let
  # Host config
  hostConfig = config;
  microvmCfg = hostConfig.nixflix.microvm;

  # Generate MAC address deterministically
  generateMac =
    name:
    let
      hash = builtins.hashString "sha256" name;
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

      # Import the main nixflix module to get PostgreSQL
      (import ../../default.nix { microvm = null; })
    ];

    # Basic system configuration
    system.stateVersion = "24.11";
    networking.hostName = "postgres";

    # Minimal package set
    environment.systemPackages = with pkgs; [
      postgresql
      curl
    ];

    # Enable PostgreSQL in the guest
    nixflix = {
      enable = true;
      postgres.enable = true;

      # Use the same state directory structure
      inherit (hostConfig.nixflix) stateDir;
    };

    # PostgreSQL configuration for microVM mode
    services.postgresql = {
      enable = true;
      package = mkDefault pkgs.postgresql_16;

      # Listen on all interfaces (so other microVMs can connect)
      settings = {
        listen_addresses = mkForce "0.0.0.0";
        port = 5432;
      };

      # Enable TCP/IP connections
      enableTCPIP = true;

      # Trust authentication for microVM subnet
      authentication = mkAfter ''
        # Allow all microVMs to connect without password
        host all all ${microvmCfg.network.subnet} trust
      '';

      # Copy database creation from host config
      ensureDatabases =
        optionals (hostConfig.nixflix.sonarr.enable or false) [
          "sonarr"
          "sonarr-logs"
        ]
        ++ optionals (hostConfig.nixflix.radarr.enable or false) [
          "radarr"
          "radarr-logs"
        ]
        ++ optionals (hostConfig.nixflix.lidarr.enable or false) [
          "lidarr"
          "lidarr-logs"
        ]
        ++ optionals (hostConfig.nixflix.prowlarr.enable or false) [
          "prowlarr"
          "prowlarr-logs"
        ]
        ++ optionals (hostConfig.nixflix.sonarr-anime.enable or false) [
          "sonarr-anime"
          "sonarr-anime-logs"
        ];

      ensureUsers =
        optionals (hostConfig.nixflix.sonarr.enable or false) [ { name = "sonarr"; } ]
        ++ optionals (hostConfig.nixflix.radarr.enable or false) [ { name = "radarr"; } ]
        ++ optionals (hostConfig.nixflix.lidarr.enable or false) [ { name = "lidarr"; } ]
        ++ optionals (hostConfig.nixflix.prowlarr.enable or false) [ { name = "prowlarr"; } ]
        ++ optionals (hostConfig.nixflix.sonarr-anime.enable or false) [ { name = "sonarr-anime"; } ];
    };

    # Setup database ownership
    systemd.services =
      let
        mkDbSetup = svc: {
          "${svc}-setup-logs-db" = mkIf (hostConfig.nixflix.${svc}.enable or false) {
            description = "Grant ownership of ${svc} databases";
            # Must wait for postgresql-setup.service which runs ensureDatabases/ensureUsers
            # (not just postgresql.service which only starts the daemon)
            after = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            requires = [
              "postgresql.service"
              "postgresql-setup.service"
            ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              User = "postgres";
              Group = "postgres";
              Type = "oneshot";
              RemainAfterExit = true;
            };

            script = ''
              ${pkgs.postgresql}/bin/psql -tAc 'ALTER DATABASE "${svc}" OWNER TO "${svc}";'
              ${pkgs.postgresql}/bin/psql -tAc 'ALTER DATABASE "${svc}-logs" OWNER TO "${svc}";'
            '';
          };
        };
      in
      mkDbSetup "sonarr"
      // mkDbSetup "radarr"
      // mkDbSetup "lidarr"
      // mkDbSetup "prowlarr"
      // mkDbSetup "sonarr-anime";

    # Network configuration
    networking = {
      useDHCP = false;
      useNetworkd = true;
      firewall.enable = false; # Allow all connections from other microVMs
      # Disable predictable interface names so the interface is always eth0.
      # Required because virtiofs shares cause requirePci=true in microvm.nix.
      usePredictableInterfaceNames = false;
    };

    systemd.network = {
      enable = true;
      networks."10-eth0" = {
        matchConfig.Name = "eth0";
        address = [
          "${microvmCfg.addresses.postgres or "10.100.0.2"}/24"
        ];
        gateway = [ microvmCfg.network.hostAddress ];
        dns = [
          "1.1.1.1"
          "8.8.8.8"
        ];
        networkConfig = {
          IPv6AcceptRA = false;
          DHCP = "no";
        };
      };
    };

    # Hypervisor selection
    microvm.hypervisor = microvmCfg.hypervisor;

    # vCPUs and memory (PostgreSQL might need more resources)
    # Note: QEMU hangs with exactly 2048MB, use 2047 instead
    microvm.vcpu = 2;
    microvm.mem = 2047;

    # Network interface
    # Use "tap" type for virtio-mmio (compatible with microvm machine type)
    # The TAP interface will be automatically attached to the bridge by systemd-networkd on the host
    microvm.interfaces = [
      {
        type = "tap";
        id = "vm-postgres";
        mac = generateMac "postgres";
      }
    ];

    # PostgreSQL data directory via virtiofs
    microvm.shares = [
      {
        source = "${hostConfig.nixflix.stateDir}/postgresql";
        mountPoint = "/var/lib/postgresql";
        tag = "postgresql-data";
        proto = "virtiofs";
      }
    ];
  };
}
