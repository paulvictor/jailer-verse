{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.cachenet.headscale;

  user = name: "${name}@";

  # Team nodes may reach the cache and nothing else, including each other.
  policy = pkgs.writeText "headscale-policy.json" (builtins.toJSON {
    groups."group:team" = map user cfg.users;
    tagOwners."tag:cache" = [(user cfg.adminUser)];
    acls = [
      {
        action = "accept";
        src = ["group:team"];
        dst = ["tag:cache:${toString cfg.cachePort}"];
      }
    ];
  });
in {
  options.cachenet.headscale = {
    enable = lib.mkEnableOption "headscale behind nginx with ACME";
    domain = lib.mkOption {
      type = lib.types.str;
      example = "hs.example.com";
      description = "Public domain the headscale control server is served on.";
    };
    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "tailnet.example.com";
      description = "MagicDNS base domain; must differ from `domain`.";
    };
    prefixV4 = lib.mkOption {
      type = lib.types.str;
      default = "100.72.0.0/16";
      description = ''
        IPv4 prefix handed to nodes. Kept to a narrow subrange of 100.64.0.0/10
        to make collisions with an official Tailscale tailnet on the same
        machine unlikely.
      '';
    };
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Headscale user that owns `tag:cache` (creates the office machine's pre-auth key).";
    };
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["alice" "bob"];
      description = "One headscale user per teammate. Users must be created with `headscale users create`.";
    };
    cachePort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port on `tag:cache` nodes that team members may reach.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.headscale = {
      enable = true;
      address = "127.0.0.1";
      port = 8080;
      settings = {
        server_url = "https://${cfg.domain}";
        # NOTE: if nodes get odd addresses, fail to connect, or collide with an
        # official Tailscale tailnet on the same machine, check this first.
        # headscale only supports subranges of 100.64.0.0/10 and
        # fd7a:115c:a1e0::/48 ("any other range is NOT supported"), so this
        # overlaps official Tailscale's pool by design. Avoid Tailscale's reserved
        # 100.100.0.0/24, 100.100.100.0/24 and 100.115.92.0/23.
        prefixes.v4 = cfg.prefixV4;
        policy = {
          mode = "file";
          path = policy;
        };
        dns = {
          base_domain = cfg.baseDomain;
          magic_dns = true;
          nameservers.global = ["1.1.1.1" "9.9.9.9"];
        };
      };
    };

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.domain} = {
        enableACME = true;
        forceSSL = true;
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.headscale.port}";
          proxyWebsockets = true;
        };
      };
    };

    networking.firewall.allowedTCPPorts = [80 443];

    # Losing the database forces every node to re-register, so snapshot it daily.
    # Copy /var/backup/headscale off the machine (restic, rclone, ...).
    systemd.services.headscale-backup = {
      description = "Snapshot the headscale SQLite database";
      serviceConfig = {
        Type = "oneshot";
        User = "headscale";
        StateDirectory = "headscale";
        ExecStart = pkgs.writeShellScript "headscale-backup" ''
          set -eu
          dest=/var/backup/headscale
          ${pkgs.sqlite}/bin/sqlite3 /var/lib/headscale/db.sqlite ".backup '$dest/db-$(date +%F).sqlite'"
          find "$dest" -name 'db-*.sqlite' -mtime +14 -delete
        '';
      };
    };
    systemd.timers.headscale-backup = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
    systemd.tmpfiles.rules = ["d /var/backup/headscale 0700 headscale headscale -"];
  };
}
