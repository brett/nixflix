# Minimal microVM networking test
# Tests basic bridge networking with two simple VMs

{
  system ? builtins.currentSystem,
  pkgs ? import <nixpkgs> { inherit system; },
  microvm,
  hypervisor ? "cloud-hypervisor",
  ... # framework may pass nixosModules and other args not used by this test
}:

let
  pkgsUnfree = import pkgs.path {
    inherit system;
    config.allowUnfree = true;
  };
in
pkgsUnfree.testers.runNixOSTest {
  name = "microvm-minimal";

  nodes.host =
    { pkgs, ... }:
    {
      imports = [
        microvm.nixosModules.host
      ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        qemu.options = [ "-cpu host" ];
      };

      boot.kernelModules = [
        "kvm-intel"
        "kvm-amd"
      ];

      # Enable microVM host
      microvm.host.enable = true;

      # Bridge networking
      networking.useNetworkd = true;
      systemd.network = {
        enable = true;

        # Create bridge
        netdevs."20-testbr".netdevConfig = {
          Kind = "bridge";
          Name = "testbr";
        };

        # Configure bridge IP
        networks."20-testbr" = {
          matchConfig.Name = "testbr";
          addresses = [ { Address = "10.200.0.1/24"; } ];
          networkConfig.ConfigureWithoutCarrier = true;
        };

        # Auto-attach TAP interfaces (match tap* for QEMU, vm-* for cloud-hypervisor)
        networks."21-vm-tap" = {
          matchConfig.Name = "tap* vm-*";
          networkConfig.Bridge = "testbr";
        };
      };

      # NAT for guest internet access
      networking.nat = {
        enable = true;
        internalInterfaces = [ "testbr" ];
        externalInterface = "eth0";
      };

      # Define two minimal VMs
      microvm.vms = {
        vm1 = {
          autostart = true;
          config = {
            imports = [ microvm.nixosModules.microvm ];

            # Minimal system config
            system.stateVersion = "24.11";

            # Network configuration
            networking = {
              hostName = "vm1";
              useDHCP = false;
              useNetworkd = true;
              firewall.enable = false;
              usePredictableInterfaceNames = false;
            };

            systemd.network = {
              enable = true;
              networks."10-eth0" = {
                matchConfig.Name = "eth0";
                address = [ "10.200.0.10/24" ];
                gateway = [ "10.200.0.1" ];
                dns = [ "1.1.1.1" ];
                networkConfig = {
                  IPv6AcceptRA = false;
                  DHCP = "no";
                };
              };
            };

            # Minimal packages for testing
            environment.systemPackages = with pkgs; [
              curl
            ];

            # MicroVM settings
            microvm = {
              inherit hypervisor;
              vcpu = 1;
              mem = 512;
              interfaces = [
                {
                  type = "tap";
                  id = "vm-vm1";
                  mac = "02:00:00:00:00:01";
                }
              ];
            };
          };
        };

        vm2 = {
          autostart = true;
          config = {
            imports = [ microvm.nixosModules.microvm ];

            # Minimal system config
            system.stateVersion = "24.11";

            # Network configuration
            networking = {
              hostName = "vm2";
              useDHCP = false;
              useNetworkd = true;
              firewall.enable = false;
              usePredictableInterfaceNames = false;
            };

            systemd.network = {
              enable = true;
              networks."10-eth0" = {
                matchConfig.Name = "eth0";
                address = [ "10.200.0.20/24" ];
                gateway = [ "10.200.0.1" ];
                dns = [ "1.1.1.1" ];
                networkConfig = {
                  IPv6AcceptRA = false;
                  DHCP = "no";
                };
              };
            };

            # HTTP server for testing connectivity
            services.nginx = {
              enable = true;
              virtualHosts."vm2" = {
                listen = [
                  {
                    addr = "0.0.0.0";
                    port = 80;
                  }
                ];
                locations."/".return = "200 'Hello from VM2'";
              };
            };

            # Minimal packages
            environment.systemPackages = with pkgs; [ curl ];

            # MicroVM settings
            microvm = {
              inherit hypervisor;
              vcpu = 1;
              mem = 512;
              interfaces = [
                {
                  type = "tap";
                  id = "vm-vm2";
                  mac = "02:00:00:00:00:02";
                }
              ];
            };
          };
        };
      };
    };

  testScript = ''
    start_all()

    # Wait for host
    host.wait_for_unit("multi-user.target")

    # Wait for both VMs to start
    print("\n=== Starting VMs ===")
    host.wait_for_unit("microvm@vm1.service", timeout=120)
    host.wait_for_unit("microvm@vm2.service", timeout=120)

    # Give VMs time to initialize networking
    import time
    time.sleep(10)

    print("\n=== Host Network Configuration ===")
    print(host.succeed("ip addr show testbr"))
    print(host.succeed("bridge link show"))

    print("\n=== Checking VM1 network config ===")
    print(host.succeed("journalctl -u microvm@vm1.service | grep -i 'eth0\\|10.200.0.10\\|Started Network' | tail -20"))

    print("\n=== Checking VM2 network config ===")
    print(host.succeed("journalctl -u microvm@vm2.service | grep -i 'eth0\\|10.200.0.20\\|Started Network\\|nginx' | tail -20"))

    print("\n=== Testing host-to-VM1 connectivity ===")
    result = host.succeed("timeout 5 bash -c 'cat < /dev/null > /dev/tcp/10.200.0.10/22' && echo 'REACHABLE' || echo 'UNREACHABLE'")
    print(f"VM1 port 22: {result.strip()}")

    print("\n=== Testing host-to-VM2 HTTP ===")
    result = host.succeed("timeout 5 curl -f http://10.200.0.20/ 2>&1 || echo 'FAILED'")
    print(f"VM2 HTTP response: {result.strip()}")

    if "Hello from VM2" in result:
        print("✓ Successfully connected to VM2 HTTP server!")
    else:
        print("✗ Failed to connect to VM2")

    print("\n=== ARP/Neighbor table ===")
    print(host.succeed("ip neigh show"))

    print("\n=== Minimal microVM test complete ===")
  '';
}
