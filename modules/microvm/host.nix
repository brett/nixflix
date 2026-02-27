{ microvm }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.microvm;
  vmsToCreate = config.nixflix.globals.microVMHostConfigurations;

  # Detect CPU vendor from /proc/cpuinfo at eval time so we load only the
  # relevant KVM module.  Falls back to both if the file is unreadable (e.g.
  # during cross-compilation or in sandbox environments).
  cpuInfo = if builtins.pathExists "/proc/cpuinfo" then builtins.readFile "/proc/cpuinfo" else "";
  kvmModules =
    lib.optional (lib.hasInfix "GenuineIntel" cpuInfo) "kvm-intel"
    ++ lib.optional (lib.hasInfix "AuthenticAMD" cpuInfo) "kvm-amd"
    ++ lib.optionals (cpuInfo == "") [ "kvm-intel" "kvm-amd" ];

  # Detect whether the user has sops-nix / agenix imported AND has declared
  # at least one secret.  We check options first (short-circuit) so that
  # accessing config.sops / config.age is safe even when the module is absent.
  hasSopsNix = (options ? sops) && (options.sops ? secrets) && config.sops.secrets != { };
  hasAgenix = (options ? age) && (options.age ? secrets) && config.age.secrets != { };

  # Generate a deterministic MAC address from a VM's IP last octet.
  toHex =
    n:
    let
      hexChars = "0123456789abcdef";
      high = n / 16;
      low = lib.mod n 16;
    in
    "${lib.substring high 1 hexChars}${lib.substring low 1 hexChars}";

  mkMac =
    vmAddress:
    let
      parts = lib.splitString "." vmAddress;
      lastOctet = lib.toInt (lib.last parts);
    in
    "02:00:00:00:00:${toHex lastOctet}";

  # CIDs 0 (wildcard), 1 (hypervisor), 2 (host) are reserved; +100 keeps nixflix VMs at 102–131.
  mkVsockCid =
    vmAddress:
    let
      parts = lib.splitString "." vmAddress;
      lastOctet = lib.toInt (lib.last parts);
    in
    lastOctet + 100;
in
{
  imports = [ microvm.nixosModules.host ];

  config = mkIf cfg.enable {
    boot.kernelModules = [ "tun" "tap" ] ++ kvmModules;

    # The upstream microvm.nixosModules.host unconditionally adds both
    # "kvm-intel" and "kvm-amd" to boot.kernelModules.  NixOS merges lists so
    # our conditional kvmModules above is not enough — blacklist the wrong
    # vendor's module so it is never loaded.
    boot.blacklistedKernelModules =
      lib.optional (lib.hasInfix "AuthenticAMD" cpuInfo) "kvm-intel"
      ++ lib.optional (lib.hasInfix "GenuineIntel" cpuInfo) "kvm-amd";

    # Create stub directories so virtiofsd can start even before the secrets
    # manager has run (sops-nix / agenix populate these during activation).
    systemd.tmpfiles.rules =
      optional hasSopsNix "d /run/secrets 0700 root root -"
      ++ optional hasAgenix "d /run/agenix 0700 root root -";

    environment.etc."qemu/bridge.conf".text = ''
      allow ${cfg.network.bridge}
    '';

    microvm.vms = mapAttrs (
      name: vmSpec:
      let
        vmAddress = vmSpec.address;
        macAddress = mkMac vmAddress;
        # Tap interface ID: "vm-<name>" (max 15 chars).
        # The host networkd rule matches "tap* vm-*" to attach to the bridge.
        tapId = "vm-${name}";
        vsockCid = mkVsockCid vmAddress;
      in
      {
        inherit pkgs;
        config = {
          imports = [
            microvm.nixosModules.microvm
            (import ../default.nix)
            (import ./common-guest.nix {
              inherit vmAddress macAddress tapId;
              inherit (cfg.network) hostAddress;
              inherit (config.nixflix) mediaDir;
              inherit (config.nixflix) downloadsDir;
              inherit hasSopsNix hasAgenix;
              needsMedia = vmSpec.needsMedia or true;
              needsDownloads = vmSpec.needsDownloads or true;
              readOnlyMedia = vmSpec.readOnlyMedia or false;
            })
            vmSpec.module
          ]
          ++ (vmSpec.extraModules or [ ]);

          networking.hostName = "nixflix-${name}";

          nixflix.enable = true;
          nixflix.stateDir = config.nixflix.stateDir;
          nixflix.mediaDir = config.nixflix.mediaDir;
          nixflix.downloadsDir = config.nixflix.downloadsDir;

          microvm.hypervisor = cfg.hypervisor;
          microvm.mem = vmSpec.memoryMB;
          microvm.vcpu = vmSpec.vcpus;
          # vsock CID enables sd_notify relay: microvm@{name}.service is Type=notify and
          # becomes active only when the guest's multi-user.target is reached.
          microvm.vsock.cid = vsockCid;
        };
      }
    ) vmsToCreate;

    # Upstream microvm@.service has TimeoutSec=150, too short for first-boot DB migrations.
    # Override to 600s; per-VM modules can set mkForce to a higher value (e.g. prowlarr=900s).
    systemd.services = mapAttrs' (
      name: _:
      nameValuePair "microvm@${name}" {
        # Use mkDefault so individual service modules can override with mkForce.
        serviceConfig.TimeoutStartSec = lib.mkDefault "600";
      }
    ) vmsToCreate;

  };
}
