{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.postgres;
  microvmCfg = cfg.microvm;
  isEnabled = cfg.enable && microvmCfg.enable;

  # Services that get a postgres TCP account in this deployment.
  # Used to build pg_hba rules and the guest firewall allowlist.
  enabledDbServices =
    lib.filter
      (svc: (config.nixflix.${svc}.enable or false) && (config.nixflix.${svc}.microvm.enable or false))
      [
        "sonarr"
        "sonarr-anime"
        "radarr"
        "lidarr"
      ]
    ++ lib.optional
      (config.nixflix.jellyseerr.enable && config.nixflix.jellyseerr.microvm.enable)
      "jellyseerr";
in
{
  options.nixflix.postgres.microvm = {
    enable = mkEnableOption "PostgreSQL microVM isolation";

    address = mkOption {
      type = types.str;
      default = config.nixflix.microvm.addresses.postgres;
      description = "Static IP address for the PostgreSQL microVM";
    };

    vcpus = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.vcpus;
      description = "Number of vCPUs for the PostgreSQL microVM";
    };

    memoryMB = mkOption {
      type = types.int;
      default = config.nixflix.microvm.defaults.memoryMB;
      description = "Memory in MB for the PostgreSQL microVM";
    };
  };

  config = mkMerge [
    {
      assertions = [
        {
          assertion = !microvmCfg.enable || config.nixflix.microvm.enable;
          message = "nixflix.postgres.microvm.enable requires nixflix.microvm.enable = true";
        }
      ];
    }
    (mkIf isEnabled {
      nixflix.globals.microVMHostConfigurations.postgres = {
        module = ./configuration.nix;
        inherit (microvmCfg) address;
        inherit (microvmCfg) vcpus;
        inherit (microvmCfg) memoryMB;
        vpnBypass = true;
        needsMedia = false;
        needsDownloads = false;
        extraModules = [
          # Blocks multi-user.target until PostgreSQL is fully set up.
          # postgresql.service sends READY=1 when TCP is ready, but before postgresql-setup
          # creates arr databases. The gate must also wait for setup so arr VMs don't
          # start before their databases exist.
          {
            systemd.services.postgresql-guest-ready = {
              description = "Gate multi-user.target on PostgreSQL readiness (guest-side)";
              wantedBy = [ "multi-user.target" ];
              before = [ "multi-user.target" ];
              requires = [
                "postgresql.service"
                "postgresql-setup.service"
                "postgresql-arr-logs-ownership.service"
              ];
              after = [
                "postgresql.service"
                "postgresql-setup.service"
                "postgresql-arr-logs-ownership.service"
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "/run/current-system/sw/bin/true";
              };
            };
          }
          {
            # Scope each service to its own databases with trust auth.
            # Access is enforced at the network level by the guest firewall below —
            # only the listed VM IPs can reach port 5432, mirroring the Unix socket
            # model used in the non-microVM setup (OS enforces who can connect).
            services.postgresql.authentication = lib.mkAfter (
              lib.concatStrings (
                map
                  (
                    svc:
                    let
                      addr = config.nixflix.${svc}.microvm.address;
                    in
                    ''
                      host ${svc} ${svc} ${addr}/32 trust
                      host ${svc}-logs ${svc} ${addr}/32 trust
                    ''
                  )
                  (
                    lib.filter
                      (svc: (config.nixflix.${svc}.enable or false) && (config.nixflix.${svc}.microvm.enable or false))
                      [
                        "sonarr"
                        "sonarr-anime"
                        "radarr"
                        "lidarr"
                      ]
                  )
              )
              + lib.optionalString (config.nixflix.jellyseerr.enable && config.nixflix.jellyseerr.microvm.enable)
                ''
                  host jellyseerr jellyseerr ${config.nixflix.jellyseerr.microvm.address}/32 trust
                ''
            );
          }
          {
            # nftables required for extraInputRules support.
            networking.nftables.enable = true;
            networking.firewall.enable = true;
            networking.firewall.extraInputRules = lib.optionalString (enabledDbServices != [ ]) (
              let
                allowedIPs = lib.concatStringsSep ", " (
                  map (svc: config.nixflix.${svc}.microvm.address) enabledDbServices
                );
              in
              ''
                ip saddr { ${allowedIPs} } tcp dport 5432 accept
              ''
            );
          }
        ];
      };

      nixflix.globals.serviceAddresses.postgres = microvmCfg.address;

      # services.postgresql.enable = false suppresses user creation, but tmpfiles in postgres.nix needs it.
      services.postgresql.enable = mkForce false;
      users.users.postgres = {
        isSystemUser = true;
        group = "postgres";
      };
      users.groups.postgres = { };

      systemd.services = {
        postgresql = mkForce {
          description = "PostgreSQL (running in microVM at ${microvmCfg.address})";
          wantedBy = [ ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.coreutils}/bin/true";
          };
        };

      };

      # microvm@postgres.service is Type=notify; it becomes active only after
      # postgresql-guest-ready.service (and thus full DB setup) completes.
      systemd.targets.postgresql-ready = mkForce {
        description = "PostgreSQL ready (delegating to microVM)";
        after = [ "microvm@postgres.service" ];
        requires = [ "microvm@postgres.service" ];
        wantedBy = [ "multi-user.target" ];
      };
    })
  ];
}
