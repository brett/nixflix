{
  pkgs,
  config,
  lib,
  ...
}:
with lib;
let
  secrets = import ../lib/secrets { inherit lib; };
  cfg = config.nixflix.mullvad;
  mullvadPkg = if cfg.gui.enable then pkgs.mullvad-vpn else pkgs.mullvad;
in
{
  options.nixflix.mullvad = {
    enable = mkOption {
      default = false;
      example = true;
      description = ''
        Whether to enable Mullvad VPN.

        #### Using Tailscale with Mullvad

        When `services.tailscale.enable` is true, nftables rules are automatically
        configured to route Tailscale traffic around the VPN tunnel. To disable
        this behaviour, set `nixflix.mullvad.tailscale.enable = false`.

        By default, all Tailscale traffic (mesh and exit node) bypasses Mullvad.
        To route exit node traffic through Mullvad while keeping mesh traffic
        direct, set `nixflix.mullvad.tailscale.exitNode = true`.
      '';
      type = types.bool;
    };

    accountNumber = secrets.mkSecretOption {
      nullable = true;
      default = null;
      description = "Mullvad account number.";
    };

    gui = {
      enable = mkEnableOption "Mullvad GUI application";
    };

    location = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "us"
        "nyc"
      ];
      description = ''
        Mullvad server location as a list of strings.

        Format: `["country"]` | `["country" "city"]` | `["country" "city" "full-server-name"]` | `["full-server-name"]`

        Examples: `["us"]`, `["us" "nyc"]`, `["se" "got" "se-got-wg-001"]`, `["se-got-wg-001"]`

        Use "mullvad relay list" to see available locations.
        Leave empty to use automatic location selection.
      '';
    };

    enableIPv6 = mkOption {
      type = types.bool;
      default = false;
      description = "Wether to enable IPv6 for Mullvad";
    };

    dns = mkOption {
      type = types.listOf types.str;
      default = [
        "1.1.1.1"
        "1.0.0.1"
        "8.8.8.8"
        "8.8.4.4"
      ];
      defaultText = literalExpression ''["1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4"]'';
      example = [
        "194.242.2.4"
        "194.242.2.3"
      ];
      description = ''
        DNS servers to use with the VPN.
        Defaults to Cloudflare (1.1.1.1, 1.0.0.1) and Google (8.8.8.8, 8.8.4.4) DNS servers.
      '';
    };

    autoConnect = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically connect to VPN on startup";
    };

    bypassPorts = mkOption {
      type = types.listOf types.port;
      default = [ ];
      example = [ 22 ];
      description = ''
        TCP ports whose traffic bypasses the Mullvad tunnel via nftables mark
        rules. Use this to keep services like SSH reachable on the server's
        public IP while all other traffic goes through the VPN.
      '';
    };

    killSwitch = {
      enable = mkEnableOption "VPN kill switch (lockdown mode) - blocks all traffic when VPN is down";

      allowLan = mkOption {
        type = types.bool;
        default = true;
        description = "Allow LAN traffic when VPN is down (only effective with kill switch enabled)";
      };
    };

    tailscale = {
      enable = mkOption {
        type = types.bool;
        default = config.services.tailscale.enable;
        defaultText = literalExpression "config.services.tailscale.enable";
        description = ''
          Automatically configure Tailscale to coexist with Mullvad VPN.

          Adds nftables rules to bypass Mullvad for Tailscale mesh traffic
          (100.64.0.0/10) and the Tailscale WireGuard port (UDP 41641).
        '';
      };

      exitNode = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Route Tailscale exit node traffic through Mullvad.

          When false (default), all Tailscale traffic bypasses Mullvad entirely.

          When true, direct mesh traffic (device to device) and Tailscale protocol
          traffic still bypass Mullvad, but exit node traffic (internet-bound traffic
          from Tailscale clients) is routed through the Mullvad VPN tunnel.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    # src_valid_mark required so reply packets from bypass ports pass the source-address check.
    boot.kernel.sysctl."net.ipv4.conf.all.src_valid_mark" = mkIf (cfg.bypassPorts != [ ]) 1;

    networking.nftables = mkIf (cfg.bypassPorts != [ ]) {
      enable = true;
      tables."mullvad-bypass" = {
        family = "inet";
        content = ''
          chain input {
            # raw (-300): before Mullvad's INPUT filter (policy drop) — accepts bypass ports.
            type filter hook input priority raw; policy accept;
            tcp dport { ${concatMapStringsSep ", " toString cfg.bypassPorts} } accept
            icmp type echo-request accept
            icmpv6 type echo-request accept
          }
          chain prerouting {
            # mangle (-150): after conntrack (-200), before rpfilter (-140).
            # Sets fwmark so rpfilter uses main table (not VPN table) for bypass ports.
            type filter hook prerouting priority mangle; policy accept;
            tcp dport { ${concatMapStringsSep ", " toString cfg.bypassPorts} } ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            icmp type echo-request ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            icmpv6 type echo-request ct mark set 0x00000f41 meta mark set 0x6d6f6c65
          }
          chain outgoing {
            # mangle (-150): conntrack has run (ct mark readable); before Mullvad filter (0, policy drop).
            type route hook output priority mangle; policy accept;
            # Match by port/protocol directly (not ct mark) so the first packet is also bypassed.
            tcp sport { ${concatMapStringsSep ", " toString cfg.bypassPorts} } ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            icmp type echo-reply ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            icmpv6 type echo-reply ct mark set 0x00000f41 meta mark set 0x6d6f6c65
            ct mark 0x00000f41 meta mark set 0x6d6f6c65
            # Handle mullvad-exclude wrapper (split-tunnel processes).
            meta mark 0x00080000 ct mark set 0x00000f41 meta mark set 0x6d6f6c65
          }
        '';
      };
    };

    services.resolved.enable = true;

    # When switch-to-configuration reloads nftables it atomically flushes all
    # tables — including Mullvad's dynamically-managed ones.  Mullvad's daemon
    # detects the disruption, re-adds its nftables rules, but clears its ip
    # rules (policy routing) without restoring them.  The firewall then blocks
    # DNS while the VPN routing no longer exists to satisfy it.
    #
    # Fix: restart mullvad-daemon after every nftables reload so it
    # re-establishes routing cleanly.  The After= ensures the restart happens
    # *after* nftables has finished reloading, not before.
    systemd.services.mullvad-daemon = {
      after = [ "nftables.service" ];
      restartTriggers = mkIf config.networking.nftables.enable [
        # Any change to the NixOS-managed nftables ruleset (new VM IPs, new
        # tables, etc.) causes nftables to reload and mullvad-daemon to restart.
        (builtins.toJSON config.networking.nftables.tables)
      ];
    };

    services.mullvad-vpn = {
      enable = true;
      enableExcludeWrapper = true;
      package = mullvadPkg;
    };

    systemd.services.mullvad-bypass-route = mkIf (cfg.bypassPorts != [ ]) {
      description = "Persistent bypass routing rule for Mullvad VPN (survives relay rotation)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      before = [ "mullvad-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "mullvad-bypass-route-up" ''
          ${pkgs.iproute2}/bin/ip   rule add fwmark 0x6d6f6c65 table main priority 10 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip -6 rule add fwmark 0x6d6f6c65 table main priority 10 2>/dev/null || true
        '';
        ExecStop = pkgs.writeShellScript "mullvad-bypass-route-down" ''
          ${pkgs.iproute2}/bin/ip   rule del fwmark 0x6d6f6c65 table main priority 10 2>/dev/null || true
          ${pkgs.iproute2}/bin/ip -6 rule del fwmark 0x6d6f6c65 table main priority 10 2>/dev/null || true
        '';
      };
    };

    systemd.services.mullvad-config = {
      description = "Configure Mullvad VPN settings";
      wantedBy = [ "multi-user.target" ];
      after = [
        "mullvad-daemon.service"
        "network-online.target"
      ];
      requires = [
        "mullvad-daemon.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "configure-mullvad" ''
          for i in {1..30}; do
            if ${mullvadPkg}/bin/mullvad status &>/dev/null; then
              echo "Mullvad daemon is ready with relay list available"
              sleep 2
              break
            fi
            sleep 1
          done

          ${optionalString (cfg.accountNumber != null) ''
            if ${mullvadPkg}/bin/mullvad account get | grep -q "Not logged in"; then
              echo "Logging in to Mullvad account..."
              # Retry login — on first boot the Mullvad API may be temporarily
              # unreachable while network routing stabilises.
              for i in {1..10}; do
                if echo "${secrets.toShellValue cfg.accountNumber}" | ${mullvadPkg}/bin/mullvad account login; then
                  echo "Mullvad login succeeded"
                  break
                fi
                echo "Login attempt $i/10 failed, retrying in 5s..."
                sleep 5
              done

              echo "Waiting for relay list to download..."
              for i in {1..30}; do
                RELAY_COUNT=$(${mullvadPkg}/bin/mullvad relay list 2>/dev/null | wc -l)
                if [ "$RELAY_COUNT" -gt 10 ]; then
                  echo "Relay list populated ($RELAY_COUNT lines)"
                  sleep 1
                  break
                fi
                sleep 1
              done
            fi
          ''}

          ${mullvadPkg}/bin/mullvad dns set custom ${concatStringsSep " " cfg.dns}

          ${mullvadPkg}/bin/mullvad tunnel set ipv6 ${if cfg.enableIPv6 then "on" else "off"}

          ${optionalString (cfg.location != [ ]) ''
            ${mullvadPkg}/bin/mullvad relay set location ${escapeShellArgs cfg.location}
          ''}

          ${optionalString cfg.killSwitch.enable ''
            ${mullvadPkg}/bin/mullvad lockdown-mode set on
            ${mullvadPkg}/bin/mullvad lan set ${if cfg.killSwitch.allowLan then "allow" else "block"}
          ''}

          ${optionalString (!cfg.killSwitch.enable) ''
            ${mullvadPkg}/bin/mullvad lockdown-mode set off
          ''}

          ${optionalString cfg.autoConnect ''
            ${mullvadPkg}/bin/mullvad auto-connect set on

            # Skip connect if not logged in — mullvad connect while logged out triggers block-all lockdown.
            if ${mullvadPkg}/bin/mullvad account get 2>/dev/null | grep -q "Not logged in"; then
              echo "Mullvad account not logged in — skipping connect to avoid lockdown"
            else
              ${mullvadPkg}/bin/mullvad connect
            fi
          ''}

          ${optionalString (!cfg.autoConnect) ''
            ${mullvadPkg}/bin/mullvad auto-connect set off
          ''}
        '';
        ExecStop = pkgs.writeShellScript "logout-mullvad" ''
          DEVICE_NAME=$(${mullvadPkg}/bin/mullvad account get | grep "Device name:" | sed 's/.*Device name:[[:space:]]*//')
          if [ -n "$DEVICE_NAME" ]; then
            echo "Revoking device: $DEVICE_NAME"
            ${mullvadPkg}/bin/mullvad account revoke-device "$DEVICE_NAME" || true
          fi
          ${mullvadPkg}/bin/mullvad account logout  || true
          ${mullvadPkg}/bin/mullvad disconnect || true
        '';
      };
    };

    networking.nftables.enable = mkIf cfg.tailscale.enable true;

    networking.nftables.tables."mullvad-tailscale" = mkIf cfg.tailscale.enable {
      enable = true;
      family = "inet";
      content =
        if cfg.tailscale.exitNode then
          ''
            chain prerouting {
              type filter hook prerouting priority -50; policy accept;

              # Allow Tailscale protocol traffic to bypass Mullvad
              udp dport 41641 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;

              # Allow direct mesh traffic (Tailscale device to Tailscale device) to bypass Mullvad
              ip saddr 100.64.0.0/10 ip daddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;

              # Exit node traffic: DON'T mark it - let it route through VPN without bypass mark
              iifname "tailscale0" ip daddr != 100.64.0.0/10 meta mark set 0;

              # Return traffic from VPN: Mark it so it routes via Tailscale table
              iifname "wg0-mullvad" ip daddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
            }

            chain outgoing {
              type route hook output priority -100; policy accept;
              meta mark 0x80000 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
              ip daddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
              udp sport 41641 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;

              # Fix Tailscale 1.96+ connmark interference with mullvad-exclude:
              # Tailscale's mangle/OUTPUT rule (priority -150) saves bits 16-23 of the
              # meta mark into the ct mark for every new connection. The Mullvad bypass
              # mark 0x6d6f6c65 has those bits set (& 0xff0000 = 0x6f0000), so Tailscale
              # saves 0x006f0000 into the ct mark. Its mangle/PREROUTING rule then
              # restores 0x006f0000 as the meta mark on incoming replies, which no longer
              # equals the full bypass mark 0x6d6f6c65 and is dropped by Mullvad's
              # INPUT firewall. Setting ct mark to 0x00000f41 here (whose bits 16-23 are
              # zero) prevents the PREROUTING restore from firing.
              ct state new meta mark == 0x6d6f6c65 ct mark set 0x00000f41;
            }

            chain postrouting {
              type nat hook postrouting priority 100; policy accept;

              # Masquerade exit node traffic going through Mullvad
              iifname "tailscale0" oifname "wg0-mullvad" masquerade;
            }
          ''
        else
          ''
            chain prerouting {
              type filter hook prerouting priority -100; policy accept;
              ip saddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
              udp dport 41641 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
            }

            chain outgoing {
              type route hook output priority -100; policy accept;
              meta mark 0x80000 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
              ip daddr 100.64.0.0/10 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;
              udp sport 41641 ct mark set 0x00000f41 meta mark set 0x6d6f6c65;

              # Fix Tailscale 1.96+ connmark interference with mullvad-exclude (see exit-node chain above).
              ct state new meta mark == 0x6d6f6c65 ct mark set 0x00000f41;
            }
          '';
    };
  };
}
