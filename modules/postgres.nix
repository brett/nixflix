{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.postgres;
  stateDir = "${config.nixflix.stateDir}/postgres";
in
{
  options.nixflix.postgres = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = "Whether or not to enable postgresql for the entire stack";
    };

    microvm.enable = mkOption {
      type = types.bool;
      default = config.nixflix.microvm.enable or false;
      description = ''
        Run PostgreSQL in an isolated microVM.
        Inherits from nixflix.microvm.enable but can be overridden.
      '';
    };
  };

  config = mkIf (config.nixflix.enable && cfg.enable && !cfg.microvm.enable) {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      dataDir = stateDir;

      # When microVM is enabled, listen on the bridge interface
      # to allow microVMs to connect via TCP
      settings = mkIf (config.nixflix.microvm.enable or false) {
        listen_addresses = mkForce "${config.nixflix.microvm.network.hostAddress},127.0.0.1";
      };

      # Allow connections from microVM subnet
      # Use 'trust' authentication for the private microVM network since
      # it's only accessible from the host and simplifies database connections
      authentication = mkIf (config.nixflix.microvm.enable or false) (mkAfter ''
        # Allow microVM services to connect without password
        host all all ${config.nixflix.microvm.network.subnet} trust
      '');
    };

    systemd.services.postgresql = {
      after = [ "nixflix-setup-dirs.service" ];
      requires = [ "nixflix-setup-dirs.service" ];
    };

    systemd = {
      tmpfiles.settings."10-postgresql".${stateDir}.d = {
        user = "postgres";
        group = "postgres";
        mode = "0700";
      };

      targets.postgresql-ready = {
        after = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        requires = [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        wantedBy = [ "multi-user.target" ];
      };
    };
  };
}
