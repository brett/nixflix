# Guest NixOS configuration for the PostgreSQL microVM.
# Listens on all interfaces; the pg_hba.conf subnet rule is pushed from the
# host via extraModules in postgres/microvm/default.nix so it matches the
# configured nixflix.microvm.network.subnet.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  nixflix.postgres.enable = true;

  # Listen on all interfaces (not just unix socket)
  services.postgresql.settings.listen_addresses = lib.mkForce "*";

  # Pre-create databases and users for all potential arr services.
  # The subnet trust rule is pushed via extraModules (uses configured subnet).
  services.postgresql.ensureDatabases = [
    "sonarr"
    "sonarr-logs"
    "sonarr-anime"
    "sonarr-anime-logs"
    "radarr"
    "radarr-logs"
    "lidarr"
    "lidarr-logs"
    "jellyseerr"
  ];

  # ensureDBOwnership = true grants the user ownership of their same-named
  # database AND (PostgreSQL 15+) GRANT ALL ON SCHEMA public — both are
  # required for the arr services to run schema migrations.
  services.postgresql.ensureUsers = [
    {
      name = "sonarr";
      ensureDBOwnership = true;
    }
    {
      name = "sonarr-anime";
      ensureDBOwnership = true;
    }
    {
      name = "radarr";
      ensureDBOwnership = true;
    }
    {
      name = "lidarr";
      ensureDBOwnership = true;
    }
    {
      name = "jellyseerr";
      ensureDBOwnership = true;
    }
  ];

  # Grant ownership of *-logs databases to the corresponding users.
  # ensureDBOwnership only covers the database named after the user;
  # logs databases have different names so need explicit ALTER DATABASE.
  systemd.services.postgresql-arr-logs-ownership = {
    description = "Grant arr service users ownership of their logs databases";
    wantedBy = [ "multi-user.target" ];
    after = [
      "postgresql.service"
      "postgresql-setup.service"
    ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      ExecStart = pkgs.writeShellScript "postgresql-arr-logs-ownership" ''
        set -eu
        psql() { ${config.services.postgresql.package}/bin/psql "$@"; }
        psql -c 'ALTER DATABASE "sonarr-logs" OWNER TO sonarr;'
        psql -c 'ALTER DATABASE "sonarr-anime-logs" OWNER TO "sonarr-anime";'
        psql -c 'ALTER DATABASE "radarr-logs" OWNER TO radarr;'
        psql -c 'ALTER DATABASE "lidarr-logs" OWNER TO lidarr;'
        # Also grant schema privileges on logs databases (PostgreSQL 15+)
        psql -d "sonarr-logs" -c 'GRANT ALL ON SCHEMA public TO sonarr;'
        psql -d "sonarr-anime-logs" -c 'GRANT ALL ON SCHEMA public TO "sonarr-anime";'
        psql -d "radarr-logs" -c 'GRANT ALL ON SCHEMA public TO radarr;'
        psql -d "lidarr-logs" -c 'GRANT ALL ON SCHEMA public TO lidarr;'
      '';
    };
  };

  microvm.shares = [
    {
      source = "${config.nixflix.stateDir}/postgres";
      mountPoint = "${config.nixflix.stateDir}/postgres";
      tag = "nixflix-postgres-state";
      proto = "virtiofs";
    }
  ];
}
