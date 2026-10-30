{
  config,
  lib,
  ...
}: let
  cfg = config.cachenet.cacheServer;
in {
  options.cachenet.cacheServer = {
    enable = lib.mkEnableOption "harmonia binary cache reachable over the headscale tailnet only";
    loginServer = lib.mkOption {
      type = lib.types.str;
      example = "https://hs.example.com";
      description = "Headscale URL this machine joins.";
    };
    authKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/secrets/headscale-authkey";
      description = "File on the host holding a pre-auth key created with `--tags tag:cache`. The node gets its tag from the key; headscale rejects `--advertise-tags` on pre-auth registrations.";
    };
    signKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/secrets/harmonia.secret";
      description = ''
        Cache signing key on the host. Generate with:
        nix-store --generate-binary-cache-key <name>-1 secret public
        and distribute only the public key.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      authKeyFile = cfg.authKeyFile;
      extraUpFlags = [
        "--login-server=${cfg.loginServer}"
        "--accept-dns=false"
      ];
    };

    # harmonia has no auth of its own: listen on all interfaces but only open
    # the port on tailscale0, so access control is the headscale policy.
    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [cfg.signKeyFile];
      settings.bind = "[::]:${toString cfg.port}";
    };
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [cfg.port];

    nix.settings.allowed-users = ["harmonia"];
  };
}
