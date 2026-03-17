# Cartographer Application Services
# Haskell backend + Next.js frontend + Agent + EFS mount + nginx (Cloudflare Origin CA)
{
  pkgs,
  lib,
  config,
  ...
}:

let
  backendPkg = config.cartographer.backendPackage;
  frontendPkg = config.cartographer.frontendPackage;
  agentPkg = config.cartographer.agentPackage;
  nodejs = pkgs.nodejs_20;

  versionJson = builtins.toJSON {
    configurationRevision = config.system.configurationRevision or "dirty";
    nixosVersion = config.system.nixos.version;
    hostname = config.networking.hostName;
  };
in
{
  config = {
    # --- Cachix (Haskell builds) ---
    nix.settings = {
      substituters = [ "https://kotto5.cachix.org" ];
      trusted-public-keys = [ "kotto5.cachix.org-1:kIqTVHIxWyPkkiJ24ceZpS6JVvs2BE8GTIA48virk/s=" ];
    };

    # --- Operator SSH access ---
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHcjDeqStU70L2swBOL3E4IJgwnDt3EwR5e3A8iBuTC2 sonar-deploy-yui-20260304"
    ];

    # --- Application user ---
    users.users.cartographer = {
      isSystemUser = true;
      group = "cartographer";
      home = "/var/lib/cartographer";
      createHome = true;
    };
    users.groups.cartographer = { };

    # --- EFS mount (M36 data) ---
    environment.systemPackages = [ pkgs.nfs-utils ];

    fileSystems."/mnt/efs" = {
      device = "${config.cartographer.efsFileSystemId}.efs.ap-northeast-1.amazonaws.com:/";
      fsType = "nfs4";
      options = [
        "nfsvers=4.1"
        "rsize=1048576"
        "wsize=1048576"
        "hard"
        "timeo=600"
        "retrans=2"
        "_netdev"
      ];
    };

    # --- nginx (Cloudflare Origin CA) ---
    services.nginx = {
      enable = true;
      serverNamesHashBucketSize = 128;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;

      virtualHosts."${config.cartographer.domain}" = {
        forceSSL = true;
        sslCertificate = config.sops.secrets."origin_cert".path;
        sslCertificateKey = config.sops.secrets."origin_key".path;

        locations."/" = {
          proxyPass = "http://127.0.0.1:3000";
          proxyWebsockets = true;
        };

        locations."/_next/static/" = {
          proxyPass = "http://127.0.0.1:3000";
          extraConfig = ''
            expires 365d;
            add_header Cache-Control "public, immutable";
          '';
        };

        locations."= /.well-known/version" = {
          extraConfig = ''
            root /etc;
            try_files /nixos-version.json =404;
            default_type application/json;
            add_header Cache-Control "no-cache, no-store";
            add_header X-Content-Type-Options nosniff;
          '';
        };
      };
    };

    # --- Version endpoint ---
    environment.etc."nixos-version.json".source =
      pkgs.writeText "nixos-version.json" versionJson;

    # --- Haskell backend (port 8080) ---
    systemd.services.cartographer-backend = {
      description = "Cartographer Haskell Backend";
      requires = [ "mnt-efs.mount" ];
      after = [
        "network.target"
        "mnt-efs.mount"
      ];
      wantedBy = [ "multi-user.target" ];

      environment.M36_DATA_PATH = "/mnt/efs/m36-data";

      serviceConfig = {
        Type = "simple";
        User = "cartographer";
        Group = "cartographer";
        WorkingDirectory = "/var/lib/cartographer";
        ExecStartPre = "+${pkgs.coreutils}/bin/chown cartographer:cartographer /mnt/efs";
        ExecStart = "${lib.getExe backendPkg}";
        EnvironmentFile = config.sops.templates."cartographer-env".path;
        Restart = "always";
        RestartSec = 5;
        OOMScoreAdjust = -900;
      };
    };

    # --- Next.js frontend (port 3000, behind nginx) ---
    systemd.services.cartographer-frontend = {
      description = "Cartographer Next.js Frontend";
      after = [
        "network.target"
        "cartographer-backend.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NODE_ENV = "production";
        PORT = "3000";
        HOSTNAME = "0.0.0.0";
        HASKELL_BACKEND_URL = "http://localhost:8080";
      };

      serviceConfig = {
        Type = "simple";
        User = "cartographer";
        Group = "cartographer";
        WorkingDirectory = "${frontendPkg}/app";
        ExecStart = "${lib.getExe frontendPkg}";
        EnvironmentFile = config.sops.templates."cartographer-env".path;
        Restart = "always";
        RestartSec = 5;
        OOMScoreAdjust = -900;
      };
    };

    # --- Agent (event thread) ---
    systemd.services.cartographer-agent = {
      description = "Cartographer Event Thread Agent";
      after = [
        "network.target"
        "cartographer-backend.service"
        "cartographer-frontend.service"
      ];
      wantedBy = [ "multi-user.target" ];

      environment.NODE_ENV = "production";

      serviceConfig = {
        Type = "simple";
        User = "cartographer";
        Group = "cartographer";
        WorkingDirectory = agentPkg;
        ExecStart = "${nodejs}/bin/node ${agentPkg}/node_modules/tsx/dist/cli.mjs ${agentPkg}/agents/index.ts";
        EnvironmentFile = config.sops.templates."cartographer-env".path;
        Restart = "always";
        RestartSec = 5;
        OOMScoreAdjust = -900;
      };
    };

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
