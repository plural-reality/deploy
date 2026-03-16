# Sonar Application Services
# Next.js frontend + Supabase Docker Compose + nginx reverse proxy
{
  pkgs,
  lib,
  config,
  ...
}:

let
  supabaseDir = "/var/lib/supabase";
in
{
  options.sonar = {
    domain = lib.mkOption {
      type = lib.types.str;
      description = "The domain name for the application";
    };

    supabaseDomain = lib.mkOption {
      type = lib.types.str;
      description = "The domain name for Supabase API";
    };


    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "admin@plural-reality.com";
      description = "Email for Let's Encrypt ACME registration";
    };
  };

  config = {
    # --- ACME (Let's Encrypt) ---
    security.acme = {
      acceptTerms = true;
      defaults.email = config.sonar.acmeEmail;
    };

    # --- nginx reverse proxy ---
    services.nginx = {
      enable = true;
      serverNamesHashBucketSize = 128;
      recommendedTlsSettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedProxySettings = true;

      # App domain -> Next.js
      virtualHosts."${config.sonar.domain}" = {
        enableACME = true;
        forceSSL = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:3000";
          proxyWebsockets = true;
        };

        # Next.js static assets (long cache)
        locations."/_next/static/" = {
          proxyPass = "http://127.0.0.1:3000";
          extraConfig = ''
            expires 365d;
            add_header Cache-Control "public, immutable";
          '';
        };

};

      # Supabase domain -> Kong
      virtualHosts."${config.sonar.supabaseDomain}" = {
        enableACME = true;
        forceSSL = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:8000";
          proxyWebsockets = true;
          extraConfig = ''
            client_max_body_size 10m;
          '';
        };
      };
    };

    # --- Supabase (Docker Compose) ---
    systemd.services.supabase = {
      description = "Supabase Docker Compose stack";
      after = [
        "docker.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "supabase";
        WorkingDirectory = supabaseDir;
        TimeoutStartSec = 300;

        # 1. Sync docker-compose.yml and templates from nix store
        # 2. Render .env from SOPS and kong.yml from template
        ExecStartPre = pkgs.writeShellScript "supabase-prepare" ''
          set -euo pipefail

          # Sync static files from nix store (read-only) to writable state dir
          cp ${config.sonar.supabaseSource}/docker-compose.yml ${supabaseDir}/
          ${pkgs.coreutils}/bin/mkdir -p ${supabaseDir}/volumes/api ${supabaseDir}/volumes/db
          cp ${config.sonar.supabaseSource}/volumes/db/init-migrations.sh ${supabaseDir}/volumes/db/

          # Render .env from SOPS template
          cp ${config.sops.templates."supabase-env".path} ${supabaseDir}/.env

          # Generate kong.yml from template with injected keys
          ANON_KEY=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."anon_key".path})
          SERVICE_ROLE_KEY=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."service_role_key".path})

          ${pkgs.gnused}/bin/sed \
            -e "s|ANON_KEY_PLACEHOLDER|$ANON_KEY|g" \
            -e "s|SERVICE_ROLE_KEY_PLACEHOLDER|$SERVICE_ROLE_KEY|g" \
            ${config.sonar.supabaseSource}/volumes/api/kong.yml.template > ${supabaseDir}/volumes/api/kong.yml
        '';

        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up -d";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
      };
    };

    # --- Next.js frontend ---
    systemd.services.sonar = {
      description = "Sonar Next.js Frontend";
      after = [
        "network.target"
        "supabase.service"
      ];
      wants = [ "supabase.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NODE_ENV = "production";
        PORT = "3000";
        HOSTNAME = "0.0.0.0";
      };

      serviceConfig = {
        Type = "simple";
        User = "sonar";
        Group = "sonar";
        WorkingDirectory = "${config.sonar.package}/app";
        # Use the sonar wrapper: validates env vars via sonar-check-env, then
        # starts Node.js from the app's own nixpkgs (not deploy's pkgs.nodejs_22).
        ExecStart = "${config.sonar.package}/bin/sonar";
        EnvironmentFile = config.sops.templates."nextjs-env".path;
        Restart = "always";
        RestartSec = 5;
        OOMScoreAdjust = -900;
      };
    };

    # sops-nix decrypts via activation scripts (before service startup)

    networking.firewall.allowedTCPPorts = [
      80
      443
    ];
  };
}
