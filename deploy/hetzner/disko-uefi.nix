# deploy/hetzner/disko-uefi.nix
#
# ZFS disk layout for nixos-anywhere deployment on Hetzner dedicated servers (UEFI).
#
# Identical to disko.nix except the boot partition is a FAT32 EFI System
# Partition (EF00) instead of a BIOS boot partition.
#
# Designed for single-disk servers. diskDevice is auto-detected by deploy.sh
# and passed via nixos-anywhere's --disk flag. Default "/dev/sda" covers most
# Hetzner dedicated servers.
#
# Partition layout (GPT):
#   1 – 512 MiB  EFI System Partition (FAT32, /boot)
#   2 – rest     ZFS partition (rpool)
{ diskDevice ? "/dev/sda", ... }:
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = diskDevice;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };

            zfs = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "rpool";
              };
            };
          };
        };
      };
    };

    zpool = {
      rpool = {
        type = "zpool";

        options = {
          ashift = "12";
          autotrim = "on";
        };

        rootFsOptions = {
          compression = "lz4";
          "com.sun:auto-snapshot" = "false";
          xattr = "sa";
          acltype = "posixacl";
          dnodesize = "auto";
          normalization = "formD";
          mountpoint = "none";
          canmount = "off";
        };

        datasets = {
          "local" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
            };
          };

          "safe" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              canmount = "off";
            };
          };

          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
            };
            postCreateHook = "zfs snapshot rpool/local/root@blank";
          };

          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
            };
          };

          "local/var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options = {
              mountpoint = "legacy";
            };
          };

          "safe/home" = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
            };
          };
        };
      };
    };
  };
}
