# Sonar Application Services
# Next.js frontend + Supabase Docker Compose + nginx reverse proxy + Docker
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
    # --- Sonar user ---
    users.users.sonar = {
      isSystemUser = true;
      group = "sonar";
      home = "/var/lib/sonar";
      createHome = true;
      extraGroups = [ "docker" ];
    };
    users.groups.sonar = { };

    # --- Docker (for Supabase) ---
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    environment.systemPackages = [ pkgs.docker-compose ];

    # --- IMDS route (Docker veth interfaces steal 169.254.0.0/16) ---
    # Policy routing: a dedicated table (100) with a high-priority rule.
    # Docker only modifies the main table; this survives any bridge/veth changes.
    networking.localCommands = ''
      ${pkgs.iproute2}/bin/ip rule del to 169.254.169.254/32 lookup 100 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add to 169.254.169.254/32 lookup 100 priority 100
      ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 dev ens5 table 100
    '';

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

        ExecStartPre = pkgs.writeShellScript "supabase-prepare" ''
          set -euo pipefail

          cp ${config.sonar.supabaseSource}/docker-compose.yml ${supabaseDir}/
          ${pkgs.coreutils}/bin/mkdir -p ${supabaseDir}/volumes/api ${supabaseDir}/volumes/db
          cp ${config.sonar.supabaseSource}/volumes/db/init-migrations.sh ${supabaseDir}/volumes/db/

          cp ${config.sops.templates."supabase-env".path} ${supabaseDir}/.env

          ANON_KEY=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."anon_key".path})
          SERVICE_ROLE_KEY=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."service_role_key".path})

          ${pkgs.gnused}/bin/sed \
            -e "s|ANON_KEY_PLACEHOLDER|$ANON_KEY|g" \
            -e "s|SERVICE_ROLE_KEY_PLACEHOLDER|$SERVICE_ROLE_KEY|g" \
            ${config.sonar.supabaseSource}/volumes/api/kong.yml.template > ${supabaseDir}/volumes/api/kong.yml
        '';

        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up -d";

        ExecStartPost = pkgs.writeShellScript "supabase-sync-passwords" ''
          set -euo pipefail
          PW=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."postgres_password".path})
          for i in $(seq 1 20); do
            ${pkgs.docker-compose}/bin/docker-compose exec -T db \
              pg_isready -U supabase_admin -d postgres >/dev/null 2>&1 && break
            sleep 2
          done
          ${pkgs.docker-compose}/bin/docker-compose exec -T db \
            env PGPASSWORD="$PW" psql -U supabase_admin -d postgres -c \
            "ALTER ROLE supabase_auth_admin WITH PASSWORD '$PW'; ALTER ROLE authenticator WITH PASSWORD '$PW';"
        '';

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
        ExecStart = "${config.sonar.package}/bin/sonar";
        EnvironmentFile = config.sops.templates."nextjs-env".path;
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
