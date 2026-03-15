# Bare-metal nixflix configuration for Hetzner.
#
# Enables a representative nixflix stack on top of the base Hetzner host config:
#   Prowlarr · Sonarr · Sonarr-Anime · Radarr · Lidarr
#   qBittorrent (routed behind Mullvad)
#   Mullvad VPN
#   nginx reverse proxy
#
# Secrets are managed by sops-nix.  The host decrypts them at boot using its
# SSH host key as an age identity (see deploy/secrets/README.md for setup).
#
# ZFS layout expected on the host (provisioned by disko):
#   rpool/nixos/nixflix  →  /var/lib/nixflix  (nixflix state)
#   rpool/data/media     →  /data/media
#   rpool/data/downloads →  /data/downloads
{
  config,
  domain ? "example.com",
  acmeEmail ? "admin@example.com",
  ...
}:
{
  imports = [
    ../hetzner/base.nix
  ];

  # ---------------------------------------------------------------------------
  # sops-nix — derive the age decryption key from the SSH host key at boot.
  # See: https://github.com/Mic92/sops-nix#using-age-for-secret-decryption
  # ---------------------------------------------------------------------------
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.secrets = {
    # Mullvad
    account_number = {
      sopsFile = ../secrets/mullvad.yaml;
    };
    # Arr API keys and shared admin password
    prowlarr_api_key = {
      sopsFile = ../secrets/arr.yaml;
    };
    sonarr_api_key = {
      sopsFile = ../secrets/arr.yaml;
    };
    sonarr_anime_api_key = {
      sopsFile = ../secrets/arr.yaml;
    };
    radarr_api_key = {
      sopsFile = ../secrets/arr.yaml;
    };
    lidarr_api_key = {
      sopsFile = ../secrets/arr.yaml;
    };
    arr_admin_password = {
      sopsFile = ../secrets/arr.yaml;
    };
    sabnzbd_api_key = {
      sopsFile = ../secrets/admin.yaml;
    };
  };

  # ---------------------------------------------------------------------------
  # nixflix stack
  # ---------------------------------------------------------------------------
  nixflix = {
    enable = true;

    # ZFS-specific state directory — should reside on its own ZFS dataset so
    # that service databases can be snapshotted and rolled back independently.
    stateDir = "/var/lib/nixflix";
    mediaDir = "/data/media";
    downloadsDir = "/data/downloads";

    # Wait for Mullvad to be connected before starting download clients.
    serviceDependencies = [ "mullvad-daemon.service" ];

    nginx = {
      enable = true;
      # Replace with the real domain before deploying to production.
      domain = domain;
      acme = {
        enable = true;
        email = acmeEmail;
      };
    };

    mullvad = {
      enable = true;
      accountNumber = {
        _secret = config.sops.secrets.account_number.path;
      };
      autoConnect = true;
      bypassPorts = [ 22 80 443 ];
    };

    prowlarr = {
      enable = true;
      config = {
        hostConfig.port = 9696;
        hostConfig.username = "admin";
        hostConfig.password = {
          _secret = config.sops.secrets.arr_admin_password.path;
        };
        apiKey = {
          _secret = config.sops.secrets.prowlarr_api_key.path;
        };
      };
    };

    sonarr = {
      enable = true;
      mediaDirs = [ "/data/media/tv" ];
      config = {
        hostConfig.port = 8989;
        hostConfig.username = "admin";
        hostConfig.password = {
          _secret = config.sops.secrets.arr_admin_password.path;
        };
        apiKey = {
          _secret = config.sops.secrets.sonarr_api_key.path;
        };
      };
    };

    sonarr-anime = {
      enable = true;
      mediaDirs = [ "/data/media/tv-anime" ];
      config = {
        hostConfig.port = 8990;
        hostConfig.username = "admin";
        hostConfig.password = {
          _secret = config.sops.secrets.arr_admin_password.path;
        };
        apiKey = {
          _secret = config.sops.secrets.sonarr_anime_api_key.path;
        };
      };
    };

    radarr = {
      enable = true;
      mediaDirs = [ "/data/media/movies" ];
      config = {
        hostConfig.port = 7878;
        hostConfig.username = "admin";
        hostConfig.password = {
          _secret = config.sops.secrets.arr_admin_password.path;
        };
        apiKey = {
          _secret = config.sops.secrets.radarr_api_key.path;
        };
      };
    };

    lidarr = {
      enable = true;
      mediaDirs = [ "/data/media/music" ];
      config = {
        hostConfig.port = 8686;
        hostConfig.username = "admin";
        hostConfig.password = {
          _secret = config.sops.secrets.arr_admin_password.path;
        };
        apiKey = {
          _secret = config.sops.secrets.lidarr_api_key.path;
        };
      };
    };

    torrentClients.qbittorrent = {
      enable = true;
      serverConfig.Preferences.WebUI.Username = "admin";
      # password: nullable — set nixflix.torrentClients.qbittorrent.password
      # via a sops secret (and add qbittorrent_password to deploy/secrets/admin.yaml)
      # before relying on the downloadarr integration.
    };

    usenetClients.sabnzbd = {
      enable = true;
      settings.misc.api_key = {
        _secret = config.sops.secrets.sabnzbd_api_key.path;
      };
    };

    recyclarr.enable = true;
  };
}
