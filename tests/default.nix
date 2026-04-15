{
  lib,
  nixosModules,
  pkgs ? import <nixpkgs> { inherit system; },
  system ? builtins.currentSystem,
  microvmModules ? null,
}:
{
  # Import all test modules
  vm-tests = import ./vm-tests {
    inherit
      system
      pkgs
      nixosModules
      lib
      microvmModules
      ;
  };
  unit-tests = import ./unit-tests {
    inherit
      system
      pkgs
      nixosModules
      microvmModules
      ;
  };
}
