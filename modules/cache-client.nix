{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cachenet.client;

  socket = "/run/tailscaled-cache/tailscaled.sock";
  tailscale = "${pkgs.tailscale}/bin/tailscale --socket=${socket}";
  listen = "127.0.0.1:${toString cfg.localPort}";
in {
  options.cachenet.client = {
    enable = lib.mkEnableOption "a second, userspace tailscaled joined to the headscale tailnet, used only to reach the nix cache";
    loginServer = lib.mkOption {
      type = lib.types.str;
      example = "https://hs.example.com";
      description = "Headscale URL to join.";
    };
    authKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/cachenet-authkey";
      description = ''
        File holding this person's headscale pre-auth key. It must be created
        with `--reusable` if the person has several devices.
      '';
    };
    cacheNode = lib.mkOption {
      type = lib.types.str;
      default = "varman";
      description = "Tailnet name (or IP) of the node running harmonia.";
    };
    cachePort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
    };
    publicKey = lib.mkOption {
      type = lib.types.str;
      example = "cache.example.com-1:AAAA...=";
      description = "Public half of the cache signing key.";
    };
    localPort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port on 127.0.0.1 that Nix uses as its substituter.";
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      default = "${config.networking.hostName}-cache";
      description = "Node name registered in headscale.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Userspace networking: no TUN device, no routes, no rules, no DNS changes,
    # and a random UDP port, so it coexists with an official Tailscale install.
    systemd.services.tailscaled-cache = {
      description = "tailscaled (userspace, headscale cache tailnet)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "notify";
        DynamicUser = true;
        RuntimeDirectory = "tailscaled-cache";
        StateDirectory = "tailscaled-cache";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.tailscale}/bin/tailscaled"
          "--tun=userspace-networking"
          "--socket=${socket}"
          "--state=/var/lib/tailscaled-cache/tailscaled.state"
          "--port=0"
        ];
        Restart = "on-failure";
      };
    };

    systemd.services.tailscaled-cache-login = {
      description = "Log tailscaled-cache into headscale";
      wantedBy = ["multi-user.target"];
      after = ["tailscaled-cache.service"];
      requires = ["tailscaled-cache.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = "authkey:${cfg.authKeyFile}";
        ExecStart = pkgs.writeShellScript "tailscaled-cache-login" ''
          exec ${tailscale} up \
            --login-server=${lib.escapeShellArg cfg.loginServer} \
            --auth-key="file:$CREDENTIALS_DIRECTORY/authkey" \
            --hostname=${lib.escapeShellArg cfg.hostname} \
            --accept-dns=false \
            --operator=tailscale-cache \
            --timeout=60s
        '';
      };
    };

    # tailscaled only lets root or its "operator" dial out, so the forwarder
    # runs as a static user that the login unit registers as operator.
    users.users.tailscale-cache = {
      isSystemUser = true;
      group = "tailscale-cache";
    };
    users.groups.tailscale-cache = {};

    # Nix sees a plain http://127.0.0.1:<localPort>; each connection is piped
    # into the tailnet with `tailscale nc`.
    systemd.sockets.nix-cache-fwd = {
      wantedBy = ["sockets.target"];
      listenStreams = [listen];
      socketConfig.Accept = true;
    };
    systemd.services."nix-cache-fwd@" = {
      description = "Forward a connection to the nix cache over the tailnet";
      after = ["tailscaled-cache-login.service"];
      serviceConfig = {
        User = "tailscale-cache";
        StandardInput = "socket";
        StandardOutput = "socket";
        ExecStart = "${tailscale} nc ${cfg.cacheNode} ${toString cfg.cachePort}";
      };
    };

    nix.settings = {
      extra-substituters = ["http://${listen}"];
      extra-trusted-public-keys = [cfg.publicKey];
      # Fail fast and fall back to cache.nixos.org when the tailnet is down.
      connect-timeout = lib.mkDefault 5;
    };

    # `tailscale-cache status` shows direct vs relay for peers.
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "tailscale-cache" ''
        exec ${tailscale} "$@"
      '')
    ];
  };
}
