# Testing Guide for Nixflix

This directory contains tests for the Nixflix NixOS modules that configure \*arr applications (Sonarr, Radarr, Lidarr, Prowlarr).

## Test Structure

```
tests/
├── README.md           # This file
├── default.nix         # Main test entry point
├── vm-tests/           # NixOS VM integration tests
│   ├── default.nix
│   └── *.nix          # Individual VM test files
└── unit-tests/         # Configuration generation tests
    └── default.nix
```

## Test Types

### 1. VM Tests (Integration Tests)

VM tests spin up actual NixOS virtual machines and test the full service stack, including:

- Service startup and availability
- API connectivity with configured API keys
- Configuration service execution
- Multi-service integration

#### MicroVM Tests

MicroVM tests verify the optional microVM isolation feature that runs each service in its own lightweight virtual machine using `microvm.nix`. These tests include:

- `microvm-basic.nix` - Single service (Sonarr) in microVM
- `microvm-networking.nix` - Network connectivity between host and microVM
- `microvm-storage.nix` - virtiofs mounts and hardlink functionality
- `microvm-full-stack.nix` - Complete stack with multiple microVMs
- `microvm-nginx.nix` - nginx reverse proxy routing to microVM services
- `microvm-jellyfin-jellyseerr.nix` - Jellyfin and Jellyseerr in microVMs
- `microvm-minimal.nix` - Minimal bridge networking test (standalone, no nixflix modules)

All microVM tests default to the QEMU hypervisor. See [Running MicroVM Tests with a Different Hypervisor](#running-microvm-tests-with-a-different-hypervisor) for how to select cloud-hypervisor at test-run time.

### 2. Unit Tests (Configuration Tests)

Unit tests verify that NixOS module options generate correct systemd service definitions without actually running the services. They validate:

- Service generation from module options
- Correct systemd unit dependencies
- Default value application

## Running Tests

### List Available Tests

```bash
nix eval --json '.#checks.x86_64-linux' --apply builtins.attrNames
```

### Run Individual Tests

```bash
nix build -L .#checks.x86_64-linux.<test-name>
```

The `-L` flag shows detailed logs during the build/test process.

#### Tests that require internet access

Some tests will require internet access for their services to reach
a successful state. In order to do so you will neet to set `networking.useDHCP = true;`
inside your test and run the test with sandbox disabled:

```bash
nix build .#checks.x86_64-linux.<test-name> -L --option sandbox false
```

It should be noted that running tests that require internet access is a big no-no
because the test is no longer deterministic. It is basically the same as `nix build . --impure`.
So, you should only use this when absolutely necessary. As soon as you add the internet
as a dependency, you instantly make your tests more error prone and brittle.

### Running MicroVM Tests with a Different Hypervisor

By default, all microVM tests use QEMU. To run them with `cloud-hypervisor` instead, use the `lib.microvmTests` flake output, which accepts a `hypervisor` argument at evaluation time:

```bash
# Run a single microvm test with cloud-hypervisor
nix build --impure --expr \
  '((builtins.getFlake "path:.").lib.microvmTests { hypervisor = "cloud-hypervisor"; }).microvm-basic'

# Run the full-stack test with cloud-hypervisor
nix build --impure --expr \
  '((builtins.getFlake "path:.").lib.microvmTests { hypervisor = "cloud-hypervisor"; }).microvm-full-stack'
```

`lib.microvmTests` accepts:

- `hypervisor` — `"cloud-hypervisor"` (default) or `"qemu"`
- `system` — defaults to `"x86_64-linux"`

The standard `nix build .#checks.x86_64-linux.microvm-*` commands always use QEMU and remain unchanged.

### Run Tests Locally with Interactive VM

For debugging, you can run VM tests interactively:

```bash
nix build .#checks.x86_64-linux.sonarr-basic.driverInteractive
./result/bin/nixos-test-driver
```

This opens a Python REPL where you can interact with the VM:

```python
>>> start_all()
>>> machine.wait_for_unit("sonarr.service")
>>> machine.succeed("curl http://127.0.0.1:8989")
>>> machine.screenshot("screenshot.png")
```

## Continuous Integration

Tests run automatically on GitHub Actions for every push and pull request.

When you add new tests to `tests/vm-tests/default.nix` or `tests/unit-tests/default.nix`, they are automatically included in CI - no workflow updates needed!

## Writing New Tests

### Adding a New VM Test

Create a new file in `tests/vm-tests/`, e.g., `my-test.nix`:

```nix
{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> {inherit system;},
  nixosModules,
}:
pkgs.testers.runNixOSTest {
  name = "my-test";

  nodes.machine = {config, pkgs, ...}: {
    imports = [nixosModules];

    services.nixflix = {
      enable = true;
      user = "testuser";
      # ... your configuration
    };

    users.users.testuser = {
      isNormalUser = true;
      createHome = true;
    };
  };

  testScript = ''
    start_all()
    machine.wait_for_unit("sonarr.service")
    # ... your test assertions
  '';
}
```

The test will automatically appear in `nix flake check` and GitHub Actions!

### Adding a New Unit Test

Add a new test to `tests/unit-tests/default.nix`:

```nix
{
  # ... existing tests
  my-unit-test = let
    config = evalConfig [
      {
        services.nixflix = {
          # ... your config
        };
      }
    ];
    # ... assertions
  in
    assertTest "my-unit-test" (/* condition */);
}
```

## Debugging Failed Tests

### VM Test Failures

1. Run the test with `-L` flag for detailed logs:

   ```bash
   nix build .#checks.x86_64-linux.sonarr-basic -L
   ```

1. Use the interactive driver to explore:

   ```bash
   nix build .#checks.x86_64-linux.sonarr-basic.driverInteractive
   ./result/bin/nixos-test-driver
   ```

1. Start the test suite and watch the magic

   ```python
   start_all()
   ```

1. Check service logs in the VM:

   ```python
   >>> exit_code, out = machine.execute("journalctl -u sonarr.service")
   >>> print(out)
   ```

### Unit Test Failures

Unit tests will show Nix evaluation errors. Check:

- Module syntax errors
- Missing or incorrect options
- Type mismatches in configuration

## Current Test Status (2026-02-17)

All 28 checks pass.

**MicroVM tests (7/7):**

- ✅ microvm-basic
- ✅ microvm-networking
- ✅ microvm-storage
- ✅ microvm-full-stack
- ✅ microvm-nginx
- ✅ microvm-jellyfin-jellyseerr
- ✅ microvm-minimal

**Non-microVM VM tests (19/19):**

- ✅ sonarr-basic, radarr-basic, lidarr-basic, prowlarr-basic, sonarr-anime-basic
- ✅ jellyfin-basic, jellyfin-integration
- ✅ jellyseerr-basic
- ✅ sabnzbd-basic
- ✅ recyclarr-basic
- ✅ postgresql-integration
- ✅ mullvad-integration
- ✅ nginx-integration
- ✅ full-stack

**Other checks (2/2):**

- ✅ formatting
- ✅ docs-build

## Resources

- [NixOS VM Tests Documentation](https://nixos.org/manual/nixos/stable/#sec-nixos-tests)
- [Testing NixOS Modules](https://nix.dev/tutorials/nixos/integration-testing-using-virtual-machines)
- [microvm.nix Documentation](https://microvm-nix.github.io/microvm.nix/)
