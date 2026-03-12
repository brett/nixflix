# deploy/hetzner/disko.nix
#
# ZFS disk layout for nixos-anywhere deployment on Hetzner.
#
# Designed for single-disk servers (sda). The ZFS pool is named "rpool"
# and uses a mirroring-capable dataset structure so a second vdev can be
# added later without restructuring the pool.
#
# Partition layout (GPT):
#   1 – 512 MiB  EFI System Partition (FAT32, /boot)
#   2 – rest     ZFS partition (rpool)
#
# ZFS datasets:
#   rpool/local/root   →  /          (blank snapshot for impermanence-ready)
#   rpool/local/nix    →  /nix       (no atime, large working set)
#   rpool/local/var    →  /var
#   rpool/safe/home    →  /home      (separate for easy snapshot/backup policy)
#
# Usage:
#   nix run github:nix-community/nixos-anywhere -- \
#     --flake .#hetzner-host --disk-encryption-keys ... \
#     root@<rescue-ip>
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        # nixos-anywhere will substitute the actual device at deploy time when
        # passed via --disk /dev/sda=main.  Hardcode sda as the safe default
        # for Hetzner dedicated servers; override in host config if needed.
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            BIOS = {
              size = "1M";
              type = "EF02"; # BIOS boot — required for GRUB on GPT
              # No filesystem; GRUB writes its stage 1.5 here.
            };

            boot = {
              size = "512M";
              content = {
                type = "filesystem";
                format = "ext4";
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

        # Pool-level options tuned for Linux / NixOS on a single SSD/HDD.
        # Mirror vdevs can be added later with:
        #   zpool attach rpool <existing-disk-part> <new-disk-part>
        options = {
          ashift = "12"; # 4 KiB sectors (safe default for SSD and HDD)
          autotrim = "on";
        };

        rootFsOptions = {
          compression = "lz4";
          "com.sun:auto-snapshot" = "false";
          xattr = "sa";
          acltype = "posixacl";
          dnodesize = "auto";
          normalization = "formD";
          mountpoint = "none"; # datasets control their own mountpoints
          canmount = "off";
        };

        datasets = {
          # Container datasets (not mounted themselves)
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

          # Root filesystem
          "local/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
            };
            # Blank snapshot lets you implement opt-in persistence / impermanence
            # later: zfs rollback -r rpool/local/root@blank
            postCreateHook = "zfs snapshot rpool/local/root@blank";
          };

          # /nix — large, read-heavy; disable atime for performance
          "local/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
              atime = "off";
            };
          };

          # /var — logs, databases, state
          "local/var" = {
            type = "zfs_fs";
            mountpoint = "/var";
            options = {
              mountpoint = "legacy";
            };
          };

          # /home — separate dataset for snapshot / backup policy
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
