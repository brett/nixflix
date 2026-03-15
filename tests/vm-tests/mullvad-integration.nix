# Mullvad integration test: daemon starts and configuration is applied correctly.
# Does NOT set accountNumber, so the login/relay-list download block is skipped
# entirely — no internet required. Verifies that the mullvad-config service
# correctly applies kill switch, LAN, DNS, and auto-connect settings locally.
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  nixosModules,
}:
pkgs.testers.runNixOSTest {
  name = "mullvad-integration-test";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ nixosModules ];

      virtualisation.cores = 2;
      virtualisation.memorySize = 1024;

      nixflix = {
        enable = true;
        mullvad = {
          enable = true;
          # accountNumber deliberately omitted — skips login and relay-list
          # download so the test runs without internet access.
          autoConnect = false;
          killSwitch = {
            enable = true;
            allowLan = true;
          };
          dns = [
            "1.1.1.1"
            "1.0.0.1"
          ];
        };
      };
    };

  testScript = ''
    start_all()

    # Daemon and config service must both reach active/exited.
    machine.wait_for_unit("mullvad-daemon.service", timeout=60)
    machine.wait_for_unit("mullvad-config.service", timeout=60)

    # Daemon is responsive.
    machine.succeed("mullvad status")

    # Kill switch enabled.
    status = machine.succeed("mullvad lockdown-mode get")
    assert "on" in status.lower(), f"Kill switch not enabled: {status}"

    # LAN access allowed.
    lan = machine.succeed("mullvad lan get")
    assert "allow" in lan.lower(), f"LAN access not allowed: {lan}"

    # Custom DNS applied.
    dns = machine.succeed("mullvad dns get")
    assert "1.1.1.1" in dns, f"DNS 1.1.1.1 not found: {dns}"
    assert "1.0.0.1" in dns, f"DNS 1.0.0.1 not found: {dns}"

    # Auto-connect disabled.
    ac = machine.succeed("mullvad auto-connect get")
    assert "off" in ac.lower(), f"Auto-connect not disabled: {ac}"

    print("mullvad-integration: daemon started, kill switch/LAN/DNS/auto-connect all verified")
  '';
}
