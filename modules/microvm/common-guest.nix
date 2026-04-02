# Common guest configuration shared across all nixflix microVMs.
{
  vmAddress,
  macAddress,
  tapId,
  hostAddress,
  mediaDir,
  downloadsDir,
  hasSopsNix ? false,
  hasAgenix ? false,
  needsMedia ? true,
  needsDownloads ? true,
  # Jellyfin streams media but writes metadata only to its state dir —
  # mounting read-only prevents a compromised process from modifying the library.
  readOnlyMedia ? false,
}:
{ lib, ... }:
{
  networking.useNetworkd = true;
  systemd.network = {
    enable = true;
    networks."10-nixflix" = {
      matchConfig.MACAddress = macAddress;
      address = [ "${vmAddress}/24" ];
      routes = [ { Gateway = hostAddress; } ];
      networkConfig = {
        DNS = hostAddress;
        DHCP = "no";
      };
    };
  };

  microvm.interfaces = [
    {
      type = "tap";
      id = tapId;
      mac = macAddress;
    }
  ];

  # Share the host's Nix store read-only; overlay provides a writable layer
  # for store paths written during guest activation.
  microvm.writableStoreOverlay = "/nix/.rw-store";

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
      readOnly = true;
    }
  ]
  ++ lib.optional needsMedia {
    source = mediaDir;
    mountPoint = mediaDir;
    tag = "nixflix-media";
    proto = "virtiofs";
    readOnly = readOnlyMedia;
  }
  ++ lib.optional needsDownloads {
    source = downloadsDir;
    mountPoint = downloadsDir;
    tag = "nixflix-downloads";
    proto = "virtiofs";
  }
  # Mount the host's decrypted secrets into the guest at the same paths so
  # { _secret = "/run/secrets/foo"; } works identically in both modes.
  ++ lib.optional hasSopsNix {
    source = "/run/secrets";
    mountPoint = "/run/secrets";
    tag = "nixflix-secrets";
    proto = "virtiofs";
    readOnly = true;
  }
  ++ lib.optional hasAgenix {
    source = "/run/agenix";
    mountPoint = "/run/agenix";
    tag = "nixflix-agenix";
    proto = "virtiofs";
    readOnly = true;
  };

  # Give long-running services (Jellyfin first-boot, database migrations, …)
  # plenty of time to start before systemd declares a timeout.
  systemd.settings.Manager.DefaultTimeoutStartSec = "900s";

  nixflix =
    lib.genAttrs
      [
        "nginx"
        "mullvad"
        "postgres"
        "recyclarr"
        "downloadarr"
        "jellyfin"
        "seerr"
        "sonarr"
        "sonarr-anime"
        "radarr"
        "lidarr"
        "prowlarr"
      ]
      (_: {
        enable = lib.mkDefault false;
      })
    // {
      isGuest = true;
      usenetClients.sabnzbd.enable = lib.mkDefault false;
      torrentClients.qbittorrent.enable = lib.mkDefault false;
    };

  # Reduce closure size: strip documentation and default packages not needed in guests
  documentation.enable = false;
  environment.defaultPackages = lib.mkForce [ ];
  programs.command-not-found.enable = false;

  networking.firewall.enable = lib.mkDefault true;
  networking.nftables.enable = lib.mkDefault true;

  system.stateVersion = "24.11";
}
