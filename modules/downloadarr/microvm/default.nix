{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  sabnzbdMicrovm = config.nixflix.usenetClients.sabnzbd.microvm;
  sabnzbdEnabled = config.nixflix.usenetClients.sabnzbd.enable or false;
  sabnzbdIsEnabled = sabnzbdEnabled && (sabnzbdMicrovm.enable or false);

  qbtCfg = config.nixflix.torrentClients.qbittorrent;
  qbtMicrovm = qbtCfg.microvm;
  qbtIsEnabled = (qbtCfg.enable or false) && (qbtMicrovm.enable or false);
in
{
  config = mkMerge [
    (mkIf sabnzbdIsEnabled {
      nixflix.downloadarr.sabnzbd.host = sabnzbdMicrovm.address;

      # sabnzbd-categories runs inside the VM; stub it out so *-downloadclients can depend on it
      systemd.services.sabnzbd-categories = mkForce {
        description = "SABnzbd categories (delegating to microVM)";
        after = [ "microvm@sabnzbd.service" ];
        requires = [ "microvm@sabnzbd.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };
    })

    (mkIf qbtIsEnabled {
      nixflix.downloadarr.qbittorrent.host = qbtMicrovm.address;
    })
  ];
}
