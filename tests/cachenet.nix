# Three-node end-to-end test: panneer (headscale), varman (harmonia on a kernel
# tailscale interface) and a client using the userspace tailscaled + forwarder.
{
  pkgs,
  lib,
  ...
}: let
  tlsCert = pkgs.runCommand "selfSignedCerts" {nativeBuildInputs = [pkgs.openssl];} ''
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
      -out cert.pem -keyout key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out
    cp key.pem cert.pem $out
  '';

  # Throwaway key pair, only ever used by this test.
  cacheSecretKey = pkgs.writeText "cachenet-test-secret" "cachenet-test-1:Yd8ZIqvEmmhyOPlE6lZRHx30J1/5m2YUF7NayUj3AXgPK5RHSCe5hGvC20aI8p/ZIeyMGHArM4eOI2F/IgCzdg==";
  cachePublicKey = "cachenet-test-1:DyuUR0gnuYRrwttGiPKf2SHsjBhwKzOHjiNhfyIAs3Y=";

  trustCert = {security.pki.certificateFiles = ["${tlsCert}/cert.pem"];};
in {
  name = "cachenet";

  nodes = {
    headscale = {
      imports = [../modules/headscale.nix trustCert];

      cachenet.headscale = {
        enable = true;
        domain = "headscale";
        baseDomain = "tailnet";
        users = ["alice"];
      };

      # No ACME in the sandbox: serve the same vhost with a self-signed cert.
      services.nginx.virtualHosts.headscale = {
        enableACME = lib.mkForce false;
        sslCertificate = "${tlsCert}/cert.pem";
        sslCertificateKey = "${tlsCert}/key.pem";
      };

      # No internet either: use an embedded DERP map instead of Tailscale's.
      services.headscale.settings.derp = {
        server = {
          enabled = true;
          region_id = 999;
          stun_listen_addr = "0.0.0.0:3478";
        };
        urls = [];
      };
      networking.firewall.allowedUDPPorts = [3478];

      environment.systemPackages = [pkgs.headscale];
    };

    varman = {
      imports = [../modules/cache-server.nix trustCert];

      cachenet.cacheServer = {
        enable = true;
        loginServer = "https://headscale";
        authKeyFile = "/var/lib/secrets/headscale-authkey";
        signKeyFile = toString cacheSecretKey;
      };

      # Port 8000 is open in the firewall but not in the ACL, so a failure to
      # reach it proves the headscale policy (not the firewall) is blocking it.
      networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8000];
      systemd.services.denied-port = {
        wantedBy = ["multi-user.target"];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /";
      };

      environment.systemPackages = [pkgs.curl];
    };

    client = {
      imports = [../modules/cache-client.nix trustCert];

      cachenet.client = {
        enable = true;
        loginServer = "https://headscale";
        authKeyFile = "/var/lib/client-authkey";
        publicKey = cachePublicKey;
      };

      # Only the tailnet cache is reachable in the sandbox.
      nix.settings.substituters = lib.mkForce [];

      environment.systemPackages = [pkgs.curl];
    };
  };

  testScript = ''
    start_all()

    headscale.wait_for_unit("headscale")
    headscale.wait_for_open_port(443)

    headscale.succeed("headscale users create admin")
    headscale.succeed("headscale users create alice")
    cache_key = headscale.succeed("headscale preauthkeys create --user 1 --reusable --tags tag:cache").strip()
    alice_key = headscale.succeed("headscale preauthkeys create --user 2 --reusable").strip()

    # Secrets are written after boot, then the units that need them are restarted.
    varman.succeed(f"mkdir -p /var/lib/secrets && echo {cache_key} > /var/lib/secrets/headscale-authkey")
    varman.succeed("systemctl restart tailscaled-autoconnect.service")
    varman.wait_for_unit("harmonia.socket")
    varman.wait_for_open_port(5000)
    varman.wait_for_unit("denied-port.service")
    varman.wait_for_open_port(8000)

    client.succeed(f"echo {alice_key} > /var/lib/client-authkey && chmod 600 /var/lib/client-authkey")
    client.succeed("systemctl restart tailscaled-cache-login.service")
    client.wait_for_unit("tailscaled-cache.service")

    with subtest("client resolves and reaches varman through the userspace tailscaled"):
        client.wait_until_succeeds("tailscale-cache ping --timeout 10s varman", timeout=120)

    with subtest("harmonia is served through the local forwarder"):
        out = client.succeed("curl -sf http://127.0.0.1:5000/nix-cache-info")
        assert "StoreDir: /nix/store" in out, out

    with subtest("client substitutes a signed store path from varman"):
        path = varman.succeed("echo hello-cachenet > /tmp/f && nix-store --add /tmp/f").strip()
        client.fail(f"test -e {path}")
        client.succeed(f"nix-store --realise {path}")
        assert "hello-cachenet" in client.succeed(f"cat {path}")

    with subtest("headscale policy only allows the cache port"):
        varman.succeed("curl -sf http://127.0.0.1:8000/ >/dev/null")
        client.fail("timeout 15 tailscale-cache nc varman 8000 < /dev/null")
  '';
}
