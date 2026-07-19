# hosts/disko-gateway.nix — disk layout for the GATEWAY node (node-D).
#
# A gateway holds NO Garage partitions (capacity 0, doc 00 §3/§5), so there is
# NO ZFS data pool and NO sanoid here — just a simple boot + root disk. Garage's
# meta/data dirs on node-D are tiny local dirs created by modules/garage.nix
# (the binary needs the dirs even with no data).
#
# ⚠️ node-D is ALREADY IN PRODUCTION (doc 01 Phase 3). This layout is for a
#    GREENFIELD reinstall only. If node-D is reconfigured ADDITIVELY in place
#    (the doc 01 Phase 3 path — do NOT wipe it), DO NOT import this disko module;
#    keep its existing partitioning and only add services.garage. This file
#    exists so node-D can be rebuilt from bare metal if ever needed.
{ lib, ... }:
{
  disko.devices.disk.boot = {
    type = "disk";
    # TODO operator: set node-D's actual OS disk device path.
    device = lib.mkDefault "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
