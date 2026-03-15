# deploy/hetzner/base.nix
#
# Base NixOS configuration for a Hetzner dedicated server.
# Intended for use with nixos-anywhere + disko.
#
# Pass via specialArgs in your nixosConfiguration:
#
#   nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";
#     specialArgs = {
#       sshKeys = [ "ssh-ed25519 AAAA... user@host" ];
#       hostName = "my-host";
#       hostId   = "deadbeef"; # 8-char hex, unique per host; `head -c4 /dev/urandom | xxd -p`
#     };
#     modules = [
#       disko.nixosModules.disko
#       ./deploy/hetzner/disko.nix
#       ./deploy/hetzner/base.nix
#       nixflixModule
#       { nixflix.enable = true; }
#     ];
#   };
#
# The `hostId` is required by ZFS to prevent pool imports on the wrong machine.
# Generate a fresh one per host: head -c4 /dev/urandom | xxd -p
{
  config,
  lib,
  pkgs,
  # specialArgs
  sshKeys ? [ ],
  hostName ? "nixflix",
  ...
}:
let
  resolvedHostId = builtins.substring 0 8 (builtins.hashString "md5" hostName);
in
{
  # ── Boot ────────────────────────────────────────────────────────────────────

  # Hetzner Cloud VMs use SeaBIOS (BIOS/legacy boot), not UEFI.
  # GRUB must be installed to the MBR; the GPT layout needs a BIOS boot
  # partition (type EF02) for GRUB's stage 1.5 — see disko.nix.
  boot.loader.grub = {
    enable = true;
    device = "nodev";
    # disko sets boot.loader.grub.devices from disko.devices.disk.*.device.
  };

  # Hetzner Cloud VMs expose disks via virtio — required in initrd for ZFS pool import.
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_scsi" "virtio_blk" "ahci" "sd_mod" ];

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs = {
    # kexec during nixos-anywhere install has a different hostId — allow mismatch on first boot.
    forceImportRoot = true;
    # Set to true if you later add ZFS native encryption to any dataset.
    requestEncryptionCredentials = false;
  };

  # Kernel params that improve ZFS behaviour on Hetzner (NVMe / SATA SSD).
  boot.kernelParams = [
    "zfs.zfs_arc_max=2147483648" # cap ARC at 2 GiB; tune per server RAM
  ];

  # ── Networking ──────────────────────────────────────────────────────────────

  networking.hostName = hostName;
  # ZFS requires a unique 8-hex-char hostId to prevent accidental pool imports.
  networking.hostId = resolvedHostId;

  # Interface name varies by VM type (eth0, ens3, enp1s0) — useDHCP handles all of them.
  networking.useDHCP = true;

  # Basic stateful firewall — allow SSH only by default.
  # Downstream configurations extend allowedTCPPorts as needed.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # ── SSH ─────────────────────────────────────────────────────────────────────

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # Keys passed via specialArgs land on root for nixos-anywhere's initial deploy.
  # Downstream host configs should migrate to a named user.
  users.users.root.openssh.authorizedKeys.keys = sshKeys;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ── System ──────────────────────────────────────────────────────────────────

  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [
    zfs # zpool / zfs CLI
    smartmontools # disk health monitoring
    btop
    socat
    tmux
    bat
    (pkgs.writeShellScriptBin "nixflix-monitor" (builtins.readFile ../scripts/monitor.sh))
    (pkgs.writeShellScriptBin "nixflix-check" (builtins.readFile ../tests/integration-microvm.sh))
  ];

  # Optional: automatic ZFS scrub on a weekly schedule.
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
  };

  system.stateVersion = "25.05";
}
