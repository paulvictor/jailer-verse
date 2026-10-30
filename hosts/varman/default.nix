{
  imports = [./hardware-configuration.nix];

  networking.hostName = "varman";
  system.stateVersion = "26.05";

  cachenet.cacheServer = {
    enable = true;
    loginServer = "https://hs.example.com";
    authKeyFile = "/var/lib/secrets/headscale-authkey";
    signKeyFile = "/var/lib/secrets/harmonia.secret";
  };

  services.openssh.enable = true;
  nix.settings.experimental-features = ["nix-command" "flakes"];
}
