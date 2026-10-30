{
  imports = [./hardware.nix ./disko.nix];

  networking.hostName = "panneer";
  system.stateVersion = "26.05";

  cachenet.headscale = {
    enable = true;
    domain = "hs.example.com";
    baseDomain = "tailnet.example.com";
    users = ["alice" "bob"];
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };
  users.users.root.openssh.authorizedKeys.keys = [
    # "ssh-ed25519 AAAA... you@host"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
}
