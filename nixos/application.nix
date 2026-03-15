# Sonar Application Services
# Next.js frontend + Supabase Docker Compose + nginx reverse proxy
{
  pkgs,
  lib,
  config,
  sonar-app,
  ...
}:

let
  supabaseDir = "/var/lib/sonar-deploy/repo/supabase";
  kongTemplate = "${supabaseDir}/volumes/api/kong.yml.template";
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

        # Webhook endpoint for self-deploy
        locations."/.well-known/deploy" = {
          proxyPass = "http://127.0.0.1:9000/hooks/deploy";
          extraConfig = ''
            proxy_read_timeout 600;
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
        "deploy-repo-init.service"
      ];
      wants = [ "network-online.target" ];
      requires = [
        "docker.service"
        "deploy-repo-init.service"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        WorkingDirectory = supabaseDir;
        TimeoutStartSec = 300;

        # 1. Copy SOPS-rendered .env to Docker Compose working directory
        # 2. Generate kong.yml from template with injected keys
        ExecStartPre = pkgs.writeShellScript "supabase-prepare" ''
          set -euo pipefail

          # Copy rendered .env
          cp ${config.sops.templates."supabase-env".path} ${supabaseDir}/.env

          # Generate kong.yml from template
          ANON_KEY=$(cat /run/secrets/anon_key 2>/dev/null || ${pkgs.coreutils}/bin/cat ${config.sops.secrets."anon_key".path})
          SERVICE_ROLE_KEY=$(cat /run/secrets/service_role_key 2>/dev/null || ${pkgs.coreutils}/bin/cat ${config.sops.secrets."service_role_key".path})

          ${pkgs.gnused}/bin/sed \
            -e "s|ANON_KEY_PLACEHOLDER|$ANON_KEY|g" \
            -e "s|SERVICE_ROLE_KEY_PLACEHOLDER|$SERVICE_ROLE_KEY|g" \
            ${kongTemplate} > ${supabaseDir}/volumes/api/kong.yml
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
        WorkingDirectory = "${sonar-app}/app";
        # Use the sonar wrapper: validates env vars via sonar-check-env, then
        # starts Node.js from the app's own nixpkgs (not deploy's pkgs.nodejs_22).
        ExecStart = "${sonar-app}/bin/sonar";
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
