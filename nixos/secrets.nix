# SOPS secret declarations — decrypted at boot by sops-nix via IAM Instance Profile -> KMS
{ config, lib, ... }:

{
  options.sonar.secretsEnvironment = lib.mkOption {
    type = lib.types.enum [ "prod" "staging" ];
    description = "Which SOPS secret file to use (sonar-prod.yaml or sonar-staging.yaml)";
  };

  config.sops = {
    defaultSopsFile = ../secrets/sonar-${config.sonar.secretsEnvironment}.yaml;

    # KMS-only decryption (no age/pgp keys)
    age = { };

    secrets = {
      "postgres_password" = { };
      "jwt_secret" = { };
      "anon_key" = { };
      "service_role_key" = { };
      "openrouter_api_key" = { };
      "resend_api_key" = { };
      "smtp_pass" = { };
    };

    # Self-deploy GitHub App credentials (from ci.yaml)
    secrets."github_app_id" = {
      sopsFile = ../secrets/ci.yaml;
      owner = "root";
      mode = "0400";
      path = "/run/secrets/github-app-id";
    };

    secrets."github_app_installation_id" = {
      sopsFile = ../secrets/ci.yaml;
      owner = "root";
      mode = "0400";
      path = "/run/secrets/github-app-installation-id";
    };

    secrets."github_app_private_key" = {
      sopsFile = ../secrets/ci.yaml;
      owner = "root";
      mode = "0400";
      path = "/run/secrets/github-app-private-key";
    };

    # Webhook HMAC secret (from ci.yaml)
    secrets."webhook_secret" = {
      sopsFile = ../secrets/ci.yaml;
      owner = "root";
      mode = "0400";
      path = "/run/secrets/webhook-secret";
    };

    # --- Rendered templates ---

    # Docker Compose .env for Supabase
    templates."supabase-env" = {
      content = builtins.concatStringsSep "\n" [
        "POSTGRES_PASSWORD=${config.sops.placeholder."postgres_password"}"
        "JWT_SECRET=${config.sops.placeholder."jwt_secret"}"
        "ANON_KEY=${config.sops.placeholder."anon_key"}"
        "SERVICE_ROLE_KEY=${config.sops.placeholder."service_role_key"}"
        ""
        "API_EXTERNAL_URL=https://${config.sonar.supabaseDomain}"
        "SITE_URL=https://${config.sonar.domain}"
        "ADDITIONAL_REDIRECT_URLS=https://${config.sonar.domain}/auth/confirm"
        ""
        "SMTP_HOST=${config.sonar.smtp.host}"
        "SMTP_PORT=${toString config.sonar.smtp.port}"
        "SMTP_USER=${config.sonar.smtp.user}"
        "SMTP_PASS=${config.sops.placeholder."smtp_pass"}"
        "SMTP_ADMIN_EMAIL=${config.sonar.smtp.adminEmail}"
        "SMTP_SENDER_NAME=${config.sonar.smtp.senderName}"
        ""
        "POSTGRES_VERSION=15.14.1.093"
        "GOTRUE_VERSION=v2.164.0"
        "POSTGREST_VERSION=v12.2.3"
        "KONG_VERSION=2.8.1"
        "META_VERSION=v0.84.2"
        "STUDIO_VERSION=2026.03.02-sha-5644bee"
        "JWT_EXPIRY=3600"
      ];
      owner = "root";
    };

    # Next.js EnvironmentFile
    templates."nextjs-env" = {
      content = builtins.concatStringsSep "\n" [
        "SONAR_SUPABASE_URL=https://${config.sonar.supabaseDomain}"
        "SONAR_SUPABASE_ANON_KEY=${config.sops.placeholder."anon_key"}"
        "OPENROUTER_API_KEY=${config.sops.placeholder."openrouter_api_key"}"
        "RESEND_API_KEY=${config.sops.placeholder."resend_api_key"}"
        "SONAR_BASE_URL=https://${config.sonar.domain}"
        "SONAR_SITE_URL=https://${config.sonar.domain}"
      ];
      owner = "sonar";
    };
  };
}
