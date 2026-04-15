# Shared setup for microVM NixOS tests.
# Returns pkgsUnfree (unfree-enabled nixpkgs) and kvmModule (a NixOS module
# that enables nested KVM and passes -cpu host to QEMU so cloud-hypervisor can
# use /dev/kvm inside the test VM).
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
}:
let
  cpuInfo = if builtins.pathExists "/proc/cpuinfo" then builtins.readFile "/proc/cpuinfo" else "";
  kvmModules =
    pkgs.lib.optional (pkgs.lib.hasInfix "GenuineIntel" cpuInfo) "kvm-intel"
    ++ pkgs.lib.optional (pkgs.lib.hasInfix "AuthenticAMD" cpuInfo) "kvm-amd"
    ++ pkgs.lib.optionals (cpuInfo == "") [
      "kvm-intel"
      "kvm-amd"
    ];
in
{
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
  kvmModule = {
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.kernelModules = kvmModules;
  };
}
