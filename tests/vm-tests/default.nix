{
  lib,
  nixosModules,
  microvm,
  pkgs ? import <nixpkgs> { inherit system; },
  system ? builtins.currentSystem,
  hypervisor ? "cloud-hypervisor",
}:
let
  testFiles = builtins.filter (name: name != "default.nix" && pkgs.lib.hasSuffix ".nix" name) (
    builtins.attrNames (builtins.readDir ./.)
  );

  testNameFromFile = file: pkgs.lib.removeSuffix ".nix" file;

  importTest =
    file:
    let
      fn = import (./. + "/${file}");
      acceptedArgs = builtins.functionArgs fn;
      args = {
        inherit system pkgs nixosModules;
      }
      // lib.optionalAttrs (acceptedArgs ? microvm) { inherit microvm; }
      // lib.optionalAttrs (acceptedArgs ? lib) { inherit lib; }
      // lib.optionalAttrs (acceptedArgs ? hypervisor) { inherit hypervisor; };
      test = fn args;
      fileContents = builtins.readFile (./. + "/${file}");
    in
    test
    // {
      passthru = (test.passthru or { }) // {
        meta = (test.passthru.meta or { }) // {
          requiresNetwork = lib.boolToString (
            builtins.match ".*networking\\.useDHCP[[:space:]]*=[[:space:]]*true.*" fileContents != null
          );
        };
      };
    };
in
builtins.listToAttrs (
  map (file: {
    name = testNameFromFile file;
    value = importTest file;
  }) testFiles
)
