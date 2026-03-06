# Full-stack microVM test: ALL nixflix services run in isolated microVMs.
# Verifies: all VMs start, ready services complete, APIs are reachable from the
# host, download clients are configured (both SABnzbd and qBittorrent), and
# nginx proxies traffic to the correct VM IPs.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-full-stack-skip" { } ''
    echo "microvm-full-stack: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-full-stack-test";

    nodes.machine =
      { pkgs, lib, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 8;
        virtualisation.memorySize = 8192;
        # Jellyfin 10.11.6+ requires ≥2 GiB free on data and cache dirs; virtiofs
        # reports host disk space, so the test VM disk must be large enough.
        virtualisation.diskSize = 8192;

        # SLIRP networking requires DHCP for reliable DNS (recyclarr fetches TRaSH Guides).
        networking.useDHCP = true;

        environment.systemPackages = [ pkgs.postgresql ];

        nixflix = {
          enable = true;
          nginx.enable = true;
          nginx.domain = "nixflix.test";

          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
          };

          mullvad = {
            enable = true;
            accountNumber = "0000000000000000";
          };

          postgres = {
            enable = true;
            microvm.enable = true;
          };

          sonarr = {
            enable = true;
            microvm.enable = true;
            mediaDirs = [ "/media/tv" ];
            config = {
              hostConfig = {
                port = 8989;
                password = {
                  _secret = pkgs.writeText "sonarr-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "sonarr-apikey" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
              };
              delayProfiles = [
                {
                  enableUsenet = true;
                  enableTorrent = true;
                  preferredProtocol = "torrent";
                  usenetDelay = 0;
                  torrentDelay = 360;
                  bypassIfHighestQuality = true;
                  bypassIfAboveCustomFormatScore = false;
                  minimumCustomFormatScore = 0;
                  order = 2147483647;
                  tags = [ ];
                  id = 1;
                }
              ];
            };
          };

          sonarr-anime = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@lidarr.service" ];
            };
            mediaDirs = [ "/media/anime" ];
            config = {
              hostConfig = {
                port = 8990;
                password = {
                  _secret = pkgs.writeText "sonarr-anime-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "sonarr-anime-apikey" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
              };
              delayProfiles = [
                {
                  enableUsenet = true;
                  enableTorrent = true;
                  preferredProtocol = "torrent";
                  usenetDelay = 0;
                  torrentDelay = 360;
                  bypassIfHighestQuality = true;
                  bypassIfAboveCustomFormatScore = false;
                  minimumCustomFormatScore = 0;
                  order = 2147483647;
                  tags = [ ];
                  id = 1;
                }
              ];
            };
          };

          radarr = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@sonarr.service" ];
            };
            mediaDirs = [ "/media/movies" ];
            config = {
              hostConfig = {
                port = 7878;
                password = {
                  _secret = pkgs.writeText "radarr-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "radarr-apikey" "cccccccccccccccccccccccccccccccc";
              };
              delayProfiles = [
                {
                  enableUsenet = true;
                  enableTorrent = true;
                  preferredProtocol = "torrent";
                  usenetDelay = 0;
                  torrentDelay = 360;
                  bypassIfHighestQuality = true;
                  bypassIfAboveCustomFormatScore = false;
                  minimumCustomFormatScore = 0;
                  order = 2147483647;
                  tags = [ ];
                  id = 1;
                }
              ];
            };
          };

          lidarr = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@radarr.service" ];
            };
            mediaDirs = [ "/media/music" ];
            config = {
              hostConfig = {
                port = 8686;
                password = {
                  _secret = pkgs.writeText "lidarr-password" "testpassword123";
                };
              };
              apiKey = {
                _secret = pkgs.writeText "lidarr-apikey" "dddddddddddddddddddddddddddddddd";
              };
              delayProfiles = [
                {
                  enableUsenet = true;
                  enableTorrent = true;
                  preferredProtocol = "torrent";
                  usenetDelay = 0;
                  torrentDelay = 360;
                  bypassIfHighestQuality = true;
                  bypassIfAboveCustomFormatScore = false;
                  minimumCustomFormatScore = 0;
                  order = 2147483647;
                  tags = [ ];
                  id = 1;
                }
              ];
            };
          };

          prowlarr = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@sonarr-anime.service" ];
            };
            config = {
              hostConfig.port = 9696;
              apiKey = {
                _secret = pkgs.writeText "prowlarr-apikey" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
              };
            };
          };

          usenetClients.sabnzbd = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@prowlarr.service" ];
            };
            settings = {
              misc = {
                api_key = {
                  _secret = pkgs.writeText "sabnzbd-apikey" "sabnzbd555555555555555555555555555";
                };
                nzb_key = {
                  _secret = pkgs.writeText "sabnzbd-nzbkey" "sabnzbdnzb666666666666666666666";
                };
                port = 8080;
                host = "0.0.0.0";
                url_base = "/sabnzbd";
              };
            };
          };

          torrentClients.qbittorrent = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@sabnzbd.service" ];
            };
            webuiPort = 8282;
            downloadsDir = "/data/downloads/torrent";
            password = {
              _secret = pkgs.writeText "qbittorrent-password" "testpassword123";
            };
            serverConfig = {
              LegalNotice.Accepted = true;
              Preferences.WebUI = {
                Username = "admin";
                LocalHostAuth = false;
                Locale = "en";
              };
            };
          };

          jellyfin = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@qbittorrent.service" ];
            };
            users.admin = {
              password = {
                _secret = pkgs.writeText "jellyfin-admin-password" "testpassword";
              };
              policy.isAdministrator = true;
            };
          };

          jellyseerr = {
            enable = true;
            microvm = {
              enable = true;
              startAfter = [ "microvm@jellyfin.service" ];
            };
          };

          # recyclarr is disabled: it unconditionally clones TRaSH Guides from GitHub,
          # which fails in the nested microVM test environment (SLIRP DNS is unreliable
          # when TAP/bridge interfaces are present). Coverage lives in recyclarr-basic.nix.
          recyclarr.enable = false;
        };

        systemd.services.mullvad-daemon.enable = lib.mkForce false;
        systemd.services.mullvad-config.enable = lib.mkForce false;
        services.mullvad-vpn.enable = lib.mkForce false;

        # Retained for reference but never evaluated (recyclarr.enable = false above).
        services.recyclarr.configuration = lib.mkForce {
          sonarr = {
            sonarr_main = {
              base_url = "http://10.100.0.10:8989";
              api_key = {
                _secret = pkgs.writeText "sonarr-apikey" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
              };
              quality_profiles = [
                {
                  name = "WEB-1080p";
                  upgrade = {
                    allowed = true;
                    until_quality = "WEB 1080p";
                    until_score = 10000;
                  };
                  min_format_score = 0;
                  quality_sort = "top";
                  qualities = [
                    {
                      name = "WEB 1080p";
                      qualities = [
                        "WEBDL-1080p"
                        "WEBRip-1080p"
                      ];
                    }
                    { name = "Bluray-1080p"; }
                    { name = "HDTV-1080p"; }
                  ];
                }
              ];
            };
            sonarr_anime = {
              base_url = "http://10.100.0.11:8990";
              api_key = {
                _secret = pkgs.writeText "sonarr-anime-apikey" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
              };
              quality_profiles = [
                {
                  name = "Remux-1080p - Anime";
                  upgrade = {
                    allowed = true;
                    until_quality = "Bluray-1080p";
                    until_score = 10000;
                  };
                  min_format_score = 0;
                  quality_sort = "top";
                  qualities = [
                    {
                      name = "Bluray-1080p";
                      qualities = [
                        "Bluray-1080p Remux"
                        "Bluray-1080p"
                      ];
                    }
                    {
                      name = "WEB 1080p";
                      qualities = [
                        "WEBDL-1080p"
                        "WEBRip-1080p"
                        "HDTV-1080p"
                      ];
                    }
                  ];
                }
              ];
            };
          };
          radarr = {
            radarr_main = {
              base_url = "http://10.100.0.12:7878";
              api_key = {
                _secret = pkgs.writeText "radarr-apikey" "cccccccccccccccccccccccccccccccc";
              };
              quality_profiles = [
                {
                  name = "SQP-1 (1080p)";
                  upgrade = {
                    allowed = true;
                    until_quality = "Bluray-1080p";
                    until_score = 10000;
                  };
                  min_format_score = 0;
                  quality_sort = "top";
                  qualities = [
                    { name = "Bluray-1080p"; }
                    {
                      name = "WEB 1080p";
                      qualities = [
                        "WEBDL-1080p"
                        "WEBRip-1080p"
                      ];
                    }
                    { name = "HDTV-1080p"; }
                  ];
                }
              ];
            };
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed(
          "mkdir -p"
          " /data/.state/postgres /data/.state/sonarr /data/.state/sonarr-anime"
          " /data/.state/radarr /data/.state/lidarr /data/.state/prowlarr"
          " /data/.state/sabnzbd /data/.state/qbittorrent"
          " /data/.state/jellyfin /data/.state/jellyseerr"
          " /data/media /data/downloads /data/downloads/torrent"
          " /media/tv /media/anime /media/movies /media/music"
      )

      # ── Wait for all microVMs to be ready ────────────────────────────────────

      machine.wait_for_unit("microvm@postgres.service", timeout=600)
      for svc in ["sonarr", "radarr", "lidarr", "sonarr-anime"]:
          machine.wait_for_unit(f"microvm@{svc}.service", timeout=600)
      # Prowlarr starts last; system is under maximum load. 900s matches host-side TimeoutStartSec.
      machine.wait_for_unit("microvm@prowlarr.service", timeout=900)
      machine.wait_for_unit("sabnzbd.service", timeout=600)
      machine.wait_for_unit("qbittorrent.service", timeout=300)
      # jellyfin-guest-ready polls the HTTP API; can be slow on first boot.
      machine.wait_for_unit("microvm@jellyfin.service", timeout=720)
      # Host-side poll service, not microvm@jellyseerr: vsock READY fires before port 5055 binds.
      machine.wait_for_unit("jellyseerr.service", timeout=300)

      # ── Verify VPN bypass nftables rules ─────────────────────────────────────
      machine.wait_for_unit("nftables.service", timeout=30)
      bypass_rules = machine.succeed("nft list table ip nixflix-microvm-vpn-bypass")
      assert "10.100.0.2" in bypass_rules, "Postgres IP not in VPN bypass rules"
      assert "10.100.0.10" in bypass_rules, "Sonarr IP not in VPN bypass rules"
      # qBittorrent has vpnBypass = false; must not appear in bypass rules.
      assert "10.100.0.21" not in bypass_rules, (
          "qBittorrent IP 10.100.0.21 found in bypass rules — should be excluded"
      )
      print("VPN bypass nftables rules verified")

      # ── Verify postgres firewall blocks host ──────────────────────────────────
      # The postgres VM firewall allows port 5432 only from service VM IPs.
      # Service APIs being up already proves DB connectivity from the service VM side.
      machine.fail("bash -c 'echo >/dev/tcp/10.100.0.2/5432'")
      print("postgres firewall verified: host bridge IP correctly blocked")

      import json

      # ── Verify arr service APIs from host ─────────────────────────────────────
      # Config service inside each VM restarts the arr service after first startup; poll.

      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "
          "http://10.100.0.10:8989/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Sonarr"' in result, f"sonarr API: {result!r}"
      print("sonarr API verified")

      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "
          "http://10.100.0.11:8990/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Sonarr"' in result, f"sonarr-anime API: {result!r}"
      print("sonarr-anime API verified")

      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: cccccccccccccccccccccccccccccccc' "
          "http://10.100.0.12:7878/api/v3/system/status",
          timeout=120
      )
      assert '"appName": "Radarr"' in result, f"radarr API: {result!r}"
      print("radarr API verified")

      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: dddddddddddddddddddddddddddddddd' "
          "http://10.100.0.13:8686/api/v1/system/status",
          timeout=120
      )
      assert '"appName": "Lidarr"' in result, f"lidarr API: {result!r}"
      print("lidarr API verified")

      result = machine.wait_until_succeeds(
          "curl -sf -H 'X-Api-Key: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' "
          "http://10.100.0.14:9696/api/v1/system/status",
          timeout=120
      )
      assert '"appName": "Prowlarr"' in result, f"prowlarr API: {result!r}"
      print("prowlarr API verified")

      # ── Postgres interservice verification ────────────────────────────────────
      # microvm@sonarr.service active means migrations ran against the postgres VM.
      # Host bridge IP (10.100.0.1) is in the postgres trusted subnet; no password needed.
      table_list = machine.succeed(
          "psql -h 10.100.0.2 -U sonarr -d sonarr -c '\\dt' 2>&1"
      )
      assert "Did not find any relations" not in table_list, (
          "sonarr postgres database has no tables — inter-VM migration did not run"
      )
      print("postgres interservice migration verified: sonarr tables present")

      # ── Verify download client configuration ──────────────────────────────────
      machine.wait_for_unit("sonarr-downloadclients.service", timeout=180)
      clients_raw = machine.succeed(
          "curl -sf -H 'X-Api-Key: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "
          "http://10.100.0.10:8989/api/v3/downloadclient"
      )
      clients = json.loads(clients_raw)
      client_names = [c["name"] for c in clients]
      assert len(clients) == 2, (
          f"Expected 2 download clients (SABnzbd + qBittorrent), found: {client_names}"
      )
      assert any(c["name"] == "SABnzbd" for c in clients), (
          f"Expected SABnzbd in sonarr download clients: {client_names}"
      )
      assert any(c["name"] == "qBittorrent" for c in clients), (
          f"Expected qBittorrent in sonarr download clients: {client_names}"
      )
      print(f"sonarr download clients verified: {client_names}")

      # ── Verify download client host addresses use VM IPs ──────────────────────
      sabnzbd_client = next(c for c in clients if c["name"] == "SABnzbd")
      sabnzbd_host = next(
          (f["value"] for f in sabnzbd_client["fields"] if f["name"] == "host"), None
      )
      assert sabnzbd_host == "10.100.0.20", (
          f"SABnzbd download client host should be VM IP 10.100.0.20, got: {sabnzbd_host!r}"
      )
      print(f"SABnzbd download client host verified: {sabnzbd_host}")

      qbit_client = next(c for c in clients if c["name"] == "qBittorrent")
      qbit_host = next(
          (f["value"] for f in qbit_client["fields"] if f["name"] == "host"), None
      )
      assert qbit_host == "10.100.0.21", (
          f"qBittorrent download client host should be VM IP 10.100.0.21, got: {qbit_host!r}"
      )
      print(f"qBittorrent download client host verified: {qbit_host}")

      # Spot-check radarr download clients too
      machine.wait_for_unit("radarr-downloadclients.service", timeout=180)
      clients_raw = machine.succeed(
          "curl -sf -H 'X-Api-Key: cccccccccccccccccccccccccccccccc' "
          "http://10.100.0.12:7878/api/v3/downloadclient"
      )
      clients = json.loads(clients_raw)
      client_names = [c["name"] for c in clients]
      assert len(clients) == 2, (
          f"Expected 2 download clients for radarr (SABnzbd + qBittorrent), found: {client_names}"
      )
      print(f"radarr download clients verified: {client_names}")

      # ── Verify nginx proxies to correct VM IPs ────────────────────────────────
      machine.wait_for_unit("nginx.service", timeout=30)
      machine.succeed(
          "curl -f --resolve sonarr.nixflix.test:80:127.0.0.1 "
          "-H 'X-Api-Key: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "
          "http://sonarr.nixflix.test/api/v3/system/status"
      )
      machine.succeed(
          "curl -f --resolve radarr.nixflix.test:80:127.0.0.1 "
          "-H 'X-Api-Key: cccccccccccccccccccccccccccccccc' "
          "http://radarr.nixflix.test/api/v3/system/status"
      )
      machine.succeed(
          "curl -f --resolve prowlarr.nixflix.test:80:127.0.0.1 "
          "-H 'X-Api-Key: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' "
          "http://prowlarr.nixflix.test/api/v1/system/status"
      )
      machine.succeed(
          "curl -f --resolve lidarr.nixflix.test:80:127.0.0.1 "
          "-H 'X-Api-Key: dddddddddddddddddddddddddddddddd' "
          "http://lidarr.nixflix.test/api/v1/system/status"
      )
      # SABnzbd: verify nginx route is alive (returns any HTTP response, not 502)
      sabnzbd_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "--resolve sabnzbd.nixflix.test:80:127.0.0.1 "
          "http://sabnzbd.nixflix.test/sabnzbd/api?mode=version"
      ).strip()
      assert sabnzbd_code == "200", f"Expected 200 from sabnzbd nginx, got: {sabnzbd_code}"
      print("nginx proxy verified for sonarr, radarr, prowlarr, lidarr, sabnzbd")

      # ── Verify Jellyseerr API from host ───────────────────────────────────────
      machine.succeed("bash -c 'echo >/dev/tcp/10.100.0.31/5055'")
      http_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "http://10.100.0.31:5055/api/v1/status"
      ).strip()
      assert http_code in ("200", "401"), (
          f"Expected 200 or 401 from Jellyseerr /api/v1/status, got: {http_code}"
      )
      public = json.loads(machine.succeed(
          "curl -sf http://10.100.0.31:5055/api/v1/settings/public"
      ))
      assert public.get("initialized") == True, (
          f"Jellyseerr setup service should have initialized Jellyseerr, got: {public}"
      )
      print("Jellyseerr initialization verified (cross-VM auth to Jellyfin succeeded)")
      # Also verify jellyseerr nginx route
      jellyseerr_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "--resolve jellyseerr.nixflix.test:80:127.0.0.1 "
          "http://jellyseerr.nixflix.test/api/v1/status"
      ).strip()
      assert jellyseerr_code in ("200", "401"), (
          f"Expected 200/401 from jellyseerr nginx, got: {jellyseerr_code}"
      )
      print("Jellyseerr API and nginx verified")

      print(
          "microvm-full-stack: all 10 VMs started, all APIs reachable, "
          "VPN bypass rules correct, postgres interservice migration verified, "
          "download client VM IPs verified, Jellyseerr→Jellyfin auth verified, "
          "nginx routes verified"
      )
    '';
  }
