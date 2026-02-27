{ lib, ... }:
with lib;
{
  options.nixflix.microvm = {
    enable = mkEnableOption "nixflix microVM support";

    hypervisor = mkOption {
      type = types.enum [
        "cloud-hypervisor"
        "qemu"
        "kvmtool"
        "firecracker"
        "crosvm"
      ];
      default = "cloud-hypervisor";
      description = "Hypervisor to use for microVMs";
    };

    network = {
      bridge = mkOption {
        type = types.str;
        default = "nixflix-br0";
        description = "Bridge interface name for the microVM subnet";
      };

      subnet = mkOption {
        type = types.str;
        default = "10.100.0.0/24";
        description = "Subnet CIDR for microVM networking";
      };

      hostAddress = mkOption {
        type = types.str;
        default = "10.100.0.1";
        description = "Host IP address on the microVM bridge";
      };
    };

    defaults = {
      vcpus = mkOption {
        type = types.int;
        default = 1;
        description = "Default number of vCPUs per microVM";
      };

      memoryMB = mkOption {
        type = types.int;
        default = 512;
        description = "Default memory in MB per microVM";
      };
    };
  };
}
