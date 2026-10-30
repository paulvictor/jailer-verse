# Placeholder so the flake evaluates. Replace with the output of
# `nixos-generate-config --show-hardware-config` on the office machine.
{
  boot.loader.grub = {
    enable = true;
    device = "nodev";
  };
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
