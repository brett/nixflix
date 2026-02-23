{
  lib,
  nixosModules,
  microvm,
  pkgs ? import <nixpkgs> { inherit system; },
  system ? builtins.currentSystem,
  hypervisor ? "cloud-hypervisor",
}:
{
  # Import all test modules
  vm-tests = import ./vm-tests {
    inherit
      system
      pkgs
      nixosModules
      microvm
      lib
      hypervisor
      ;
  };
  unit-tests = import ./unit-tests { inherit system pkgs nixosModules; };
}
