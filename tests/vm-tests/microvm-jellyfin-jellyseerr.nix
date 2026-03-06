# MicroVM test: Jellyfin and Jellyseerr each run in isolated microVMs.
# Exercises the same configuration surface as jellyfin-basic.nix (users, system
# config, encoding, branding, libraries) plus Jellyseerr API reachability.
# Auth is obtained via the Jellyfin API rather than the on-host token file.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
  microvmModules ? null,
}:
if microvmModules == null then
  pkgs.runCommand "microvm-jellyfin-jellyseerr-skip" { } ''
    echo "microvm-jellyfin-jellyseerr: skipped (pass microvmModules to run)" > $out
  ''
else
  let
    base = import ../lib/microvm-test-base.nix { inherit system pkgs; };
    verifyJellyfin = import ../lib/jellyfin-verify.nix;
  in
  base.pkgsUnfree.testers.runNixOSTest {
    name = "microvm-jellyfin-jellyseerr-test";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          nixosModules
          microvmModules
          base.kvmModule
        ];

        virtualisation.cores = 6;
        virtualisation.memorySize = 6144;
        # Jellyfin 10.11.6+ requires ≥2 GiB free on data/cache dirs; virtiofs reports host
        # filesystem space, so the test VM disk must be large enough.
        virtualisation.diskSize = 8192;

        nixflix = {
          enable = true;

          microvm = {
            enable = true;
            hypervisor = "cloud-hypervisor";
          };

          jellyfin = {
            enable = true;
            microvm.enable = true;
            microvm.vcpus = 4;
            microvm.memoryMB = 2048;

            users = {
              admin = {
                password = {
                  _secret = pkgs.writeText "jellyfin-admin-password" "testpassword";
                };
                policy.isAdministrator = true;
              };

              kiri = {
                password = "password123";
                enableAutoLogin = false;
                mutable = false;

                configuration = {
                  audioLanguagePreference = "eng";
                  playDefaultAudioTrack = false;
                  subtitleLanguagePreference = "spa";
                  displayMissingEpisodes = true;
                  subtitleMode = "Always";
                  displayCollectionsView = true;
                  enableLocalPassword = true;
                  hidePlayedInLatest = false;
                  rememberAudioSelections = false;
                  rememberSubtitleSelections = false;
                  enableNextEpisodeAutoPlay = false;
                };

                policy = {
                  isAdministrator = false;
                  isHidden = false;
                  isDisabled = false;
                  enableAllChannels = false;
                  enableAllDevices = false;
                  enableAllFolders = false;
                  enableAudioPlaybackTranscoding = false;
                  enableCollectionManagement = true;
                  enableContentDeletion = true;
                  enableContentDownloading = false;
                  enableLiveTvAccess = false;
                  enableLiveTvManagement = false;
                  enableMediaConversion = false;
                  enableMediaPlayback = true;
                  enablePlaybackRemuxing = false;
                  enablePublicSharing = false;
                  enableRemoteAccess = true;
                  enableRemoteControlOfOtherUsers = true;
                  enableSharedDeviceControl = false;
                  enableSubtitleManagement = true;
                  enableSyncTranscoding = false;
                  enableVideoPlaybackTranscoding = false;
                  forceRemoteSourceTranscoding = true;
                  maxParentalRating = 18;
                  blockedTags = [
                    "violence"
                    "horror"
                  ];
                  allowedTags = [
                    "comedy"
                    "drama"
                  ];
                  blockUnratedItems = [
                    "Movie"
                    "Series"
                  ];
                  enableUserPreferenceAccess = false;
                  invalidLoginAttemptCount = 5;
                  loginAttemptsBeforeLockout = 5;
                  maxActiveSessions = 3;
                  remoteClientBitrateLimit = 8000000;
                  syncPlayAccess = "JoinGroups";
                  authenticationProviderId = "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider";
                  passwordResetProviderId = "Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider";
                  maxParentalSubRating = 10;
                };
              };
            };

            system = {
              serverName = "test-jellyfin-server";
              preferredMetadataLanguage = "de";
              metadataCountryCode = "DE";
              uiCulture = "de-DE";
              logFileRetentionDays = 7;
              activityLogRetentionDays = 60;
              enableMetrics = true;
              enableNormalizedItemByNameIds = false;
              isPortAuthorized = false;
              quickConnectAvailable = false;
              enableCaseSensitiveItemIds = false;
              disableLiveTvChannelUserDataName = false;
              sortReplaceCharacters = [
                "-"
                "_"
              ];
              sortRemoveCharacters = [
                "!"
                "?"
              ];
              sortRemoveWords = [
                "der"
                "die"
                "das"
              ];
              minResumePct = 10;
              maxResumePct = 85;
              minAudiobookResume = 2;
              maxAudiobookResume = 3;
              minResumeDurationSeconds = 120;
              inactiveSessionThreshold = 15;
              libraryMonitorDelay = 30;
              libraryUpdateDuration = 45;
              cacheSize = 500;
              imageSavingConvention = "Compatible";
              imageExtractionTimeoutMs = 5000;
              skipDeserializationForBasicTypes = false;
              saveMetadataHidden = true;
              enableFolderView = true;
              enableGroupingMoviesIntoCollections = true;
              enableGroupingShowsIntoCollections = true;
              displaySpecialsWithinSeasons = false;
              remoteClientBitrateLimit = 8000000;
              enableSlowResponseWarning = false;
              slowResponseThresholdMs = 1000;
              corsHosts = [
                "localhost"
                "test.example.com"
              ];
              libraryScanFanoutConcurrency = 2;
              libraryMetadataRefreshConcurrency = 4;
              allowClientLogUpload = false;
              enableExternalContentInSuggestions = false;
              dummyChapterDuration = 10;
              chapterImageResolution = "P720";
              parallelImageEncodingLimit = 3;
              castReceiverApplications = [
                {
                  id = "CUSTOM123";
                  name = "Test Receiver";
                }
              ];
              trickplayOptions = {
                enableHwAcceleration = true;
                enableHwEncoding = true;
                enableKeyFrameOnlyExtraction = true;
                scanBehavior = "Blocking";
                processPriority = "Normal";
                interval = 5000;
                widthResolutions = [
                  320
                  480
                  720
                ];
                tileWidth = 8;
                tileHeight = 8;
                qscale = 6;
                jpegQuality = 85;
                processThreads = 2;
              };
              metadataOptions = [
                {
                  itemType = "Movie";
                  disabledMetadataSavers = [ "Nfo" ];
                  disabledMetadataFetchers = [ "TheMovieDb" ];
                  localMetadataReaderOrder = [ "Nfo" ];
                  metadataFetcherOrder = [ "TheMovieDb" ];
                  disabledImageFetchers = [ "TheMovieDb" ];
                  imageFetcherOrder = [ "TheMovieDb" ];
                }
              ];
              contentTypes = [
                {
                  name = "test";
                  value = "application/test";
                }
              ];
              pathSubstitutions = [
                {
                  from = "/old/path";
                  to = "/new/path";
                }
              ];
              codecsUsed = [
                "h264"
                "hevc"
              ];
              pluginRepositories = [
                {
                  tag = "RepositoryInfo";
                  content = {
                    name = "Test Repo";
                    url = "https://test.example.com/manifest.json";
                    enabled = true;
                  };
                }
              ];
              enableLegacyAuthorization = false;
            };

            encoding = {
              enableHardwareEncoding = false;
              allowHevcEncoding = true;
              allowAv1Encoding = true;
              encodingThreadCount = 4;
              transcodingTempPath = "/custom/transcode/path";
              enableAudioVbr = true;
              downMixAudioBoost = 3;
              downMixStereoAlgorithm = "Rfc7845";
              maxMuxingQueueSize = 4096;
              enableThrottling = true;
              throttleDelaySeconds = 120;
              enableSegmentDeletion = true;
              segmentKeepSeconds = 600;
              hardwareAccelerationType = "vaapi";
              vaapiDevice = "/dev/dri/renderD129";
              enableTonemapping = true;
              tonemappingAlgorithm = "hable";
              tonemappingMode = "rgb";
              tonemappingRange = "pc";
              tonemappingDesat = 0.5;
              tonemappingPeak = 200;
              tonemappingParam = 1.5;
              h264Crf = 20;
              h265Crf = 25;
              encoderPreset = "placebo";
              deinterlaceDoubleRate = true;
              deinterlaceMethod = "bwdif";
              enableDecodingColorDepth10Hevc = false;
              enableDecodingColorDepth10Vp9 = false;
              hardwareDecodingCodecs = [
                "h264"
                "hevc"
                "vp9"
                "av1"
              ];
              enableSubtitleExtraction = false;
              allowOnDemandMetadataBasedKeyframeExtractionForExtensions = [
                "mkv"
                "mp4"
              ];
            };

            branding = {
              customCss = ''
                body {
                  background-color: #1a1a2e;
                }
                .headerTop {
                  background-color: #16213e;
                }
              '';
              loginDisclaimer = ''
                This is a test Jellyfin server.
                Please use your assigned credentials.
              '';
              splashscreenEnabled = true;
              splashscreenLocation =
                pkgs.runCommand "test-splashscreen.png"
                  {
                    buildInputs = [ pkgs.imagemagick ];
                  }
                  ''
                    magick -size 1920x1080 xc:#1a1a2e $out
                  '';
            };

            libraries = {
              "Test Movies" = {
                collectionType = "movies";
                paths = [
                  "/media/movies"
                  "/media/films"
                ];
                enabled = true;
                enablePhotos = false;
                enableRealtimeMonitor = false;
                enableLUFSScan = false;
                enableChapterImageExtraction = false;
                extractChapterImagesDuringLibraryScan = false;
                saveLocalMetadata = false;
                enableAutomaticSeriesGrouping = false;
                enableEmbeddedTitles = false;
                enableEmbeddedExtrasTitles = false;
                enableEmbeddedEpisodeInfos = false;
                automaticRefreshIntervalDays = 90;
                preferredMetadataLanguage = "en";
                metadataCountryCode = "US";
                seasonZeroDisplayName = "Extras";
                metadataSavers = [ "Nfo" ];
                disabledLocalMetadataReaders = [ "Nfo" ];
                localMetadataReaderOrder = [ "Nfo" ];
                disabledSubtitleFetchers = [ "Open Subtitles" ];
                subtitleFetcherOrder = [ "Open Subtitles" ];
                skipSubtitlesIfEmbeddedSubtitlesPresent = false;
                skipSubtitlesIfAudioTrackMatches = false;
                subtitleDownloadLanguages = [
                  "eng"
                  "spa"
                  "fra"
                ];
                requirePerfectSubtitleMatch = false;
                saveSubtitlesWithMedia = false;
                allowEmbeddedSubtitles = "AllowText";
                automaticallyAddToCollection = false;
              };

              "Test Music" = {
                collectionType = "music";
                paths = [ "/media/music" ];
                enabled = true;
                preferNonstandardArtistsTag = true;
                useCustomTagDelimiters = true;
                customTagDelimiters = [
                  ";"
                  "|"
                ];
                saveLyricsWithMedia = true;
                disabledLyricFetchers = [ ];
                lyricFetcherOrder = [ "LrcLib" ];
                disabledMediaSegmentProviders = [ ];
                mediaSegmentProviderOrder = [ "ChapterDb" ];
                typeOptions = [
                  {
                    type = "MusicAlbum";
                    metadataFetchers = [
                      "TheAudioDB"
                      "MusicBrainz"
                    ];
                    metadataFetcherOrder = [
                      "TheAudioDB"
                      "MusicBrainz"
                    ];
                    imageFetchers = [ "TheAudioDB" ];
                    imageFetcherOrder = [ "TheAudioDB" ];
                    imageOptions = [
                      {
                        type = "Primary";
                        limit = 1;
                        minWidth = 300;
                      }
                      {
                        type = "Backdrop";
                        limit = 3;
                        minWidth = 1920;
                      }
                    ];
                  }
                ];
              };
            };
          };

          jellyseerr = {
            enable = true;
            microvm.enable = true;
            microvm.startAfter = [ "microvm@jellyfin.service" ];
          };
        };
      };

    testScript = ''
      start_all()

      # virtiofsd requires source dirs to exist at mount time.
      machine.succeed("mkdir -p /data/.state/jellyfin /data/.state/jellyseerr")

      # microvm@jellyfin becomes active only after all guest setup oneshots complete
      # (wizard, users, system-config, encoding, branding, libraries); generous timeout.
      machine.wait_for_unit("microvm@jellyfin.service", timeout=1200)
      # Wait for the host-side poll service, not microvm@jellyseerr.service: vsock READY
      # fires when the guest reaches multi-user.target, before Jellyseerr binds port 5055.
      machine.wait_for_unit("jellyseerr.service", timeout=600)

      # Auth token lives inside the guest; use AuthenticateByName instead.
      import json
      auth_resp = json.loads(machine.wait_until_succeeds(
          "curl -sf -X POST http://10.100.0.30:8096/Users/AuthenticateByName"
          " -H 'Content-Type: application/json'"
          " -H 'Authorization: MediaBrowser Client=\"nixflix\", Device=\"NixOS\","
          " DeviceId=\"nixflix-auth\", Version=\"1.0.0\"'"
          " -d '{\"Username\":\"admin\",\"Pw\":\"testpassword\"}'",
          timeout=900
      ))
      access_token = auth_resp['AccessToken']
      api_token = (
          f'MediaBrowser Client="nixflix", Device="NixOS",'
          f' DeviceId="nixflix-auth", Version="1.0.0", Token="{access_token}"'
      )
      auth_header = f'"Authorization: {api_token}"'

      ${verifyJellyfin { host = "10.100.0.30"; }}

      # Verify Jellyseerr TCP and HTTP API from the host
      machine.succeed("bash -c 'echo >/dev/tcp/10.100.0.31/5055'")
      http_code = machine.succeed(
          "curl -s -o /dev/null -w '%{http_code}' "
          "http://10.100.0.31:5055/api/v1/status"
      ).strip()
      assert http_code in ("200", "401"), (
          f"Expected 200 or 401 from Jellyseerr /api/v1/status, got: {http_code}"
      )

      # The setup service calls /api/v1/settings/initialize; initialized=true proves
      # cross-VM Jellyfin auth worked.
      public = json.loads(machine.succeed(
          "curl -sf http://10.100.0.31:5055/api/v1/settings/public"
      ))
      assert public.get("initialized") == True, (
          f"Jellyseerr setup service should have initialized Jellyseerr, got: {public}"
      )
      print("Jellyseerr initialization verified (cross-VM auth to Jellyfin succeeded)")

      print("microvm-jellyfin-jellyseerr: both VMs started; all verifications passed")
    '';
  }
