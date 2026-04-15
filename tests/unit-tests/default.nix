{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
let
  inherit (pkgs) lib;

  # Helper to evaluate a NixOS configuration without building
  evalConfig =
    modules:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        nixosModules
        {
          # Minimal NixOS config stubs needed for evaluation
          nixpkgs.hostPlatform = system;
        }
      ]
      ++ modules;
    };

  evalConfigMicrovm =
    modules:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        nixosModules
        microvmModules
        { nixpkgs.hostPlatform = system; }
      ]
      ++ modules;
    };

  # Test helper to assert conditions
  assertTest =
    name: cond:
    pkgs.runCommand "unit-test-${name}" { } ''
      ${lib.optionalString (!cond) "echo 'FAIL: ${name}' && exit 1"}
      echo 'PASS: ${name}' > $out
    '';

  check = name: cond: ''
    ${lib.optionalString (!cond) "echo 'FAIL: ${name}' && exit 1"}
    echo 'PASS: ${name}'
  '';
in
{
  # Test that nixflix.sonarr options generate correct systemd units
  sonarr-service-generation =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            sonarr = {
              enable = true;
              user = "testuser";
              config = {
                hostConfig = {
                  port = 8989;
                  username = "admin";
                  password._secret = "/run/secrets/sonarr-pass";
                };
                apiKey._secret = "/run/secrets/sonarr-api";
                rootFolders = [ { path = "/media/tv"; } ];
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
      hasAllServices =
        systemdUnits ? sonarr && systemdUnits ? sonarr-config && systemdUnits ? sonarr-rootfolders;
    in
    assertTest "sonarr-service-generation" hasAllServices;

  # Test that nixflix.sonarr-anime options generate correct systemd units
  sonarr-anime-service-generation =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            sonarr-anime = {
              enable = true;
              user = "testuser";
              config = {
                hostConfig = {
                  port = 8990;
                  username = "admin";
                  password._secret = "/run/secrets/sonarr-pass";
                };
                apiKey._secret = "/run/secrets/sonarr-api";
                rootFolders = [ { path = "/media/anime"; } ];
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
      hasAllServices =
        systemdUnits ? sonarr-anime
        && systemdUnits ? sonarr-anime-config
        && systemdUnits ? sonarr-anime-rootfolders;
    in
    assertTest "sonarr-anime-service-generation" hasAllServices;

  # Test that radarr options generate correct systemd units
  radarr-service-generation =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            radarr = {
              enable = true;
              user = "testuser";
              config = {
                hostConfig = {
                  port = 7878;
                  username = "admin";
                  password._secret = "/run/secrets/radarr-pass";
                };
                apiKey._secret = "/run/secrets/radarr-api";
                rootFolders = [ { path = "/media/movies"; } ];
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
      hasAllServices =
        systemdUnits ? radarr && systemdUnits ? radarr-config && systemdUnits ? radarr-rootfolders;
    in
    assertTest "radarr-service-generation" hasAllServices;

  # Test that prowlarr with indexers generates correct systemd units
  prowlarr-service-generation =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            prowlarr = {
              enable = true;
              config = {
                hostConfig = {
                  port = 9696;
                  username = "admin";
                  password._secret = "/run/secrets/prowlarr-pass";
                };
                apiKey._secret = "/run/secrets/prowlarr-api";
                indexers = [
                  {
                    name = "1337x";
                    apiKey._secret = "/run/secrets/1337x-api";
                  }
                ];
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
      hasAllServices =
        systemdUnits ? prowlarr && systemdUnits ? prowlarr-config && systemdUnits ? prowlarr-indexers;
    in
    assertTest "prowlarr-service-generation" hasAllServices;

  # Test that prowlarr with indexers generates correct systemd units
  sabnzbd-service-generation =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            usenetClients.sabnzbd = {
              enable = true;
              downloadsDir = "/downloads/usenet";
              settings = {
                misc = {
                  api_key._secret = pkgs.writeText "sabnzbd-apikey" "testapikey123456789abcdef";
                  nzb_key._secret = pkgs.writeText "sabnzbd-nzbkey" "testnzbkey123456789abcdef";
                  port = 8080;
                  host = "127.0.0.1";
                  url_base = "/sabnzbd";
                  ignore_samples = true;
                  direct_unpack = false;
                  article_tries = 5;
                };
                servers = [
                  {
                    name = "TestServer";
                    host = "news.example.com";
                    port = 563;
                    username._secret = pkgs.writeText "eweka-username" "testuser";
                    password._secret = pkgs.writeText "eweka-password" "testpass123";
                    connections = 10;
                    ssl = true;
                    priority = 0;
                  }
                ];
                categories = [
                  {
                    name = "tv";
                    dir = "tv";
                    priority = 0;
                    pp = 3;
                    script = "None";
                  }
                  {
                    name = "movies";
                    dir = "movies";
                    priority = 1;
                    pp = 2;
                    script = "None";
                  }
                ];
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
      hasAllServices = systemdUnits ? sabnzbd;
    in
    assertTest "sabnzbd-service-generation" hasAllServices;

  # Test that seerr generates services with a remote Jellyfin (no local jellyfin)
  seerr-remote-jellyfin =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;
            seerr = {
              enable = true;
              apiKey._secret = "/run/secrets/seerr-api";
              jellyfin = {
                adminUsername = "remoteadmin";
                adminPassword = "remotepassword";
              };
            };
          };
        }
      ];
      systemdUnits = config.config.systemd.services;
    in
    assertTest "seerr-remote-jellyfin" (
      systemdUnits ? seerr
      && systemdUnits ? seerr-setup
      && systemdUnits ? seerr-jellyfin
      && systemdUnits ? seerr-libraries
      && systemdUnits ? seerr-user-settings
    );

  jellyfin-integration =
    let
      config = evalConfig [
        {
          nixflix = {
            enable = true;

            jellyfin = {
              enable = true;
              users.admin = {
                password = "testpassword";
                policy.isAdministrator = true;
              };
            };

            radarr = {
              enable = true;
              mediaDirs = [ "/media/movies" ];
              config = {
                hostConfig = {
                  port = 7878;
                  username = "admin";
                  password._secret = "/run/secrets/radarr-pass";
                };
                apiKey._secret = "/run/secrets/radarr-api";
                rootFolders = [ { path = "/media/movies"; } ];
              };
            };

            sonarr = {
              enable = true;
              mediaDirs = [ "/media/shows" ];
              config = {
                hostConfig = {
                  port = 8989;
                  username = "admin";
                  password._secret = "/run/secrets/sonarr-pass";
                };
                apiKey._secret = "/run/secrets/sonarr-api";
                rootFolders = [ { path = "/media/shows"; } ];
              };
            };

            sonarr-anime = {
              enable = true;
              mediaDirs = [ "/media/anime" ];
              config = {
                hostConfig = {
                  port = 8990;
                  username = "admin";
                  password._secret = "/run/secrets/sonarr-anime-pass";
                };
                apiKey._secret = "/run/secrets/sonarr-anime-api";
                rootFolders = [ { path = "/media/anime"; } ];
              };
            };

            lidarr = {
              enable = true;
              mediaDirs = [ "/media/music" ];
              config = {
                hostConfig = {
                  port = 8686;
                  username = "admin";
                  password._secret = "/run/secrets/lidarr-pass";
                };
                apiKey._secret = "/run/secrets/lidarr-api";
                rootFolders = [ { path = "/media/music"; } ];
              };
            };
          };
        }
      ];

      inherit (config.config.nixflix.jellyfin) libraries;
    in
    pkgs.runCommand "unit-test-jellyfin-integration" { } ''
      ${check "Movies library exists" (libraries ? Movies)}
      ${check "Movies library has correct collectionType" (libraries.Movies.collectionType == "movies")}
      ${check "Movies library has correct path" (builtins.elem "/media/movies" libraries.Movies.paths)}

      ${check "Shows library exists" (libraries ? Shows)}
      ${check "Shows library has correct collectionType" (libraries.Shows.collectionType == "tvshows")}
      ${check "Shows library has correct path" (builtins.elem "/media/shows" libraries.Shows.paths)}

      ${check "Anime library exists" (libraries ? Anime)}
      ${check "Anime library has correct collectionType" (libraries.Anime.collectionType == "tvshows")}
      ${check "Anime library has correct path" (builtins.elem "/media/anime" libraries.Anime.paths)}

      ${check "Music library exists" (libraries ? Music)}
      ${check "Music library has correct collectionType" (libraries.Music.collectionType == "music")}
      ${check "Music library has correct path" (builtins.elem "/media/music" libraries.Music.paths)}

      echo 'PASS: jellyfin-integration' > $out
    '';
}
# Microvm-specific eval tests — only included when microvmModules is provided
// lib.optionalAttrs (microvmModules != null) {

  # Verify recyclarr base_url substitutes VM IPs when arr services run in microvms.
  recyclarr-microvm-urls =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = true;

            sonarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 8989;
                apiKey._secret = "/run/secrets/sonarr-api";
              };
            };

            radarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 7878;
                apiKey._secret = "/run/secrets/radarr-api";
              };
            };

            recyclarr.enable = true;
          };
        }
      ];
      rcfg = config.config.nixflix.recyclarr;
    in
    pkgs.runCommand "unit-test-recyclarr-microvm-urls" { } ''
      ${check "recyclarr.config is non-null" (rcfg.config != null)}
      ${check "sonarr base_url uses VM IP" (
        rcfg.config.sonarr.sonarr.base_url == "http://10.100.0.10:8989"
      )}
      ${check "radarr base_url uses VM IP" (
        rcfg.config.radarr.radarr.base_url == "http://10.100.0.12:7878"
      )}
      echo 'PASS: recyclarr-microvm-urls' > $out
    '';

  # Verify downloadarr sabnzbd.host is overridden to the SABnzbd VM address,
  # and that sabnzbd-categories is stubbed on the host with the right dependency.
  downloadarr-microvm-host =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = true;

            usenetClients.sabnzbd = {
              enable = true;
              microvm.enable = true;
              downloadsDir = "/downloads";
              settings = {
                misc = {
                  api_key._secret = "/run/secrets/sabnzbd-api";
                  nzb_key._secret = "/run/secrets/sabnzbd-nzb";
                  port = 8080;
                  host = "0.0.0.0";
                  url_base = "/sabnzbd";
                  ignore_samples = true;
                  direct_unpack = false;
                  article_tries = 5;
                };
                servers = [ ];
                categories = [ ];
              };
            };
          };
        }
      ];
      cfg = config.config;
    in
    pkgs.runCommand "unit-test-downloadarr-microvm-host" { } ''
      ${check "sabnzbd.host is VM address" (cfg.nixflix.downloadarr.sabnzbd.host == "10.100.0.20")}
      ${check "sabnzbd-categories.service waits on microvm@sabnzbd" (
        builtins.elem "microvm@sabnzbd.service" cfg.systemd.services.sabnzbd-categories.after
      )}
      echo 'PASS: downloadarr-microvm-host' > $out
    '';

  # Verify seerr microvm registers in microVMHostConfigurations and
  # pushes extraModules for radarr/sonarr hostname overrides.
  seerr-microvm-registration =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = true;

            seerr = {
              enable = true;
              microvm.enable = true;
            };

            radarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 7878;
                apiKey._secret = "/run/secrets/radarr-api";
              };
            };

            sonarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 8989;
                apiKey._secret = "/run/secrets/sonarr-api";
              };
            };
          };
        }
      ];
      inherit (config.config.nixflix) globals;
    in
    pkgs.runCommand "unit-test-seerr-microvm-registration" { } ''
      ${check "seerr registered in microVMHostConfigurations" (
        globals.microVMHostConfigurations ? seerr
      )}
      ${check "seerr extraModules is non-empty" (
        builtins.length globals.microVMHostConfigurations.seerr.extraModules > 0
      )}
      echo 'PASS: seerr-microvm-registration' > $out
    '';

  vpn-bypass-exclusion =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            mullvad = {
              enable = true;
              accountNumber = "0000000000000000";
            };
            microvm.enable = true;
            postgres = {
              enable = true;
              microvm.enable = true;
            };
            torrentClients.qbittorrent = {
              enable = true;
              microvm.enable = true;
              password._secret = "/run/secrets/qbit-pass";
            };
          };
        }
      ];
      inherit (config.config.nixflix) globals;
    in
    pkgs.runCommand "unit-test-vpn-bypass-exclusion" { } ''
      ${check "qbittorrent has vpnBypass = false (routes through VPN)" (
        !globals.microVMHostConfigurations.qbittorrent.vpnBypass
      )}
      ${check "postgres has explicit vpnBypass = true (bypasses VPN)" globals.microVMHostConfigurations.postgres.vpnBypass}
      echo 'PASS: vpn-bypass-exclusion' > $out
    '';

  # Verify globals.serviceAddresses.qbittorrent is set to the correct VM IP.
  qbittorrent-service-addresses =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = true;
            torrentClients.qbittorrent = {
              enable = true;
              microvm.enable = true;
              password._secret = "/run/secrets/qbit-pass";
            };
          };
        }
      ];
    in
    pkgs.runCommand "unit-test-qbittorrent-service-addresses" { } ''
      ${check "serviceAddresses.qbittorrent == 10.100.0.21" (
        config.config.nixflix.globals.serviceAddresses.qbittorrent == "10.100.0.21"
      )}
      echo 'PASS: qbittorrent-service-addresses' > $out
    '';

  # Verify microvm.defaults.vcpus / memoryMB propagate to per-service microvm options.
  microvm-defaults-wiring =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm = {
              enable = true;
              defaults = {
                vcpus = 4;
                memoryMB = 2048;
              };
            };
            sonarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 8989;
                apiKey._secret = "/run/secrets/sonarr-api";
              };
            };
            postgres = {
              enable = true;
              microvm.enable = true;
            };
          };
        }
      ];
      nix = config.config.nixflix;
    in
    pkgs.runCommand "unit-test-microvm-defaults-wiring" { } ''
      ${check "sonarr.microvm.vcpus == 4" (nix.sonarr.microvm.vcpus == 4)}
      ${check "sonarr.microvm.memoryMB == 2048" (nix.sonarr.microvm.memoryMB == 2048)}
      ${check "postgres.microvm.vcpus == 4" (nix.postgres.microvm.vcpus == 4)}
      ${check "postgres.microvm.memoryMB == 2048" (nix.postgres.microvm.memoryMB == 2048)}
      echo 'PASS: microvm-defaults-wiring' > $out
    '';

  # Verify the assertion fires when nixflix.microvm.enable = false but a service
  # has microvm.enable = true (the "forgot to enable the parent" mistake).
  microvm-enable-assertion =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = false; # top-level disabled
            sonarr = {
              enable = true;
              microvm.enable = true; # service-level enabled → should trigger assertion
              config = {
                hostConfig.port = 8989;
                apiKey._secret = "/run/secrets/sonarr-api";
              };
            };
          };
        }
      ];
      failingAssertions = builtins.filter (a: !a.assertion) config.config.assertions;
      # The assertion message is: "nixflix.sonarr.microvm.enable requires nixflix.microvm.enable = true"
      hasExpectedAssertion = builtins.any (
        a: builtins.match ".*nixflix\\.microvm\\.enable.*" a.message != null
      ) failingAssertions;
    in
    pkgs.runCommand "unit-test-microvm-enable-assertion" { } ''
      ${check "assertion for nixflix.microvm.enable is present" hasExpectedAssertion}
      echo 'PASS: microvm-enable-assertion' > $out
    '';

  microvm-media-scoping =
    let
      config = evalConfigMicrovm [
        {
          nixflix = {
            enable = true;
            microvm.enable = true;

            postgres = {
              enable = true;
              microvm.enable = true;
            };

            jellyfin = {
              enable = true;
              microvm.enable = true;
            };

            seerr = {
              enable = true;
              microvm.enable = true;
            };

            prowlarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 9696;
                apiKey._secret = "/run/secrets/prowlarr-api";
              };
            };

            torrentClients.qbittorrent = {
              enable = true;
              microvm.enable = true;
              password._secret = "/run/secrets/qbit-pass";
            };

            usenetClients.sabnzbd = {
              enable = true;
              microvm.enable = true;
              downloadsDir = "/downloads";
              settings = {
                misc = {
                  api_key._secret = "/run/secrets/sabnzbd-api";
                  nzb_key._secret = "/run/secrets/sabnzbd-nzb";
                  port = 8080;
                  host = "0.0.0.0";
                  url_base = "/sabnzbd";
                  ignore_samples = true;
                  direct_unpack = false;
                  article_tries = 5;
                };
                servers = [ ];
                categories = [ ];
              };
            };

            sonarr = {
              enable = true;
              microvm.enable = true;
              config = {
                hostConfig.port = 8989;
                apiKey._secret = "/run/secrets/sonarr-api";
              };
            };
          };
        }
      ];
      vms = config.config.nixflix.globals.microVMHostConfigurations;
    in
    pkgs.runCommand "unit-test-microvm-media-scoping" { } ''
      ${check "postgres: needsMedia = false" (!(vms.postgres.needsMedia or true))}
      ${check "postgres: needsDownloads = false" (!(vms.postgres.needsDownloads or true))}

      ${check "jellyfin: readOnlyMedia = true" (vms.jellyfin.readOnlyMedia or false)}
      ${check "jellyfin: needsDownloads = false" (!(vms.jellyfin.needsDownloads or true))}

      ${check "seerr: needsMedia = false" (!(vms.seerr.needsMedia or true))}
      ${check "seerr: needsDownloads = false" (!(vms.seerr.needsDownloads or true))}

      ${check "prowlarr: needsMedia = false" (!(vms.prowlarr.needsMedia or true))}
      ${check "prowlarr: needsDownloads = false" (!(vms.prowlarr.needsDownloads or true))}

      ${check "qbittorrent: needsMedia = false" (!(vms.qbittorrent.needsMedia or true))}

      ${check "sabnzbd: needsMedia = false" (!(vms.sabnzbd.needsMedia or true))}

      ${check "sonarr: needsMedia = true (default)" (vms.sonarr.needsMedia or true)}
      ${check "sonarr: needsDownloads = true (default)" (vms.sonarr.needsDownloads or true)}

      echo 'PASS: microvm-media-scoping' > $out
    '';

  # Verify prowlarr databases were removed from the postgres guest config.
  # The postgres configuration module sets a fixed ensureDatabases list;
  # prowlarr should NOT appear (it uses SQLite, not PostgreSQL).
  postgres-no-prowlarr =
    let
      # Evaluate the postgres guest configuration module directly,
      # stubbing microvm.shares (normally provided by microvm.nixosModules.microvm
      # in a real guest context).
      postgresGuestCfg = import "${pkgs.path}/nixos/lib/eval-config.nix" {
        inherit system;
        modules = [
          nixosModules
          { nixpkgs.hostPlatform = system; }
          {
            nixflix.enable = true;
            nixflix.postgres.enable = true;
          }
          ../../modules/postgres/microvm/configuration.nix
          # Stub microvm.shares option — the guest module (microvm.nixosModules.microvm)
          # is not imported here; this lets the postgres module set the option without error.
          {
            options.microvm.shares = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [ ];
            };
          }
        ];
      };
      databases = postgresGuestCfg.config.services.postgresql.ensureDatabases;
    in
    pkgs.runCommand "unit-test-postgres-no-prowlarr" { } ''
      ${check "prowlarr not in ensureDatabases" (!builtins.elem "prowlarr" databases)}
      ${check "prowlarr-logs not in ensureDatabases" (!builtins.elem "prowlarr-logs" databases)}
      echo 'PASS: postgres-no-prowlarr' > $out
    '';
}
