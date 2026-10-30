# Oracle Cloud Ampere A1 (aarch64, UEFI, KVM/virtio).
{
  boot.initrd.availableKernelModules = ["virtio_pci" "virtio_scsi" "virtio_blk" "nvme" "xhci_pci" "usbhid"];
  boot.kernelParams = ["console=ttyAMA0,115200" "console=tty1"];
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  nixpkgs.hostPlatform = "aarch64-linux";
}
