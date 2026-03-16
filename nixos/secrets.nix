# SOPS secret declarations — decrypted at boot by sops-nix via IAM Instance Profile -> KMS
#
# To add a secret:
#   1. `sops secrets/sonar/{stg,prd}.yaml` → add the key
#   2. Add a `secrets."key_name"` declaration below
#   3. Add the corresponding line to the nextjs-env template
{ config, lib, ... }:

let
  environment = config.sonar.secretsEnvironment;
  envFile = { prod = "prd"; staging = "stg"; }.${environment};
  domain = config.sonar.domain;
  supabaseDomain = config.sonar.supabaseDomain;
  p = config.sops.placeholder;
in
{
  options.sonar.secretsEnvironment = lib.mkOption {
    type = lib.types.enum [ "prod" "staging" ];
    description = "Which SOPS secret file to use (secrets/sonar/{prd,stg}.yaml)";
  };

  config.sops = {
    defaultSopsFile = ../secrets/sonar/${envFile}.yaml;

    # KMS-only decryption (no age/pgp keys)
    age = { };

    # --- Supabase infrastructure secrets ---
    secrets = {
      "postgres_password" = { };
      "jwt_secret" = { };
      "anon_key" = { };
      "service_role_key" = { };
      "smtp_pass" = { };

      # --- App secrets (subset of envContract.vars where secret = true) ---
      "openrouter_api_key" = { };
      "resend_api_key" = { };
    };

    # Self-deploy SSH keys — one per repo (GitHub deploy key limitation)
    # Both keys live in secrets/ssh/deploy.yaml under "deploy" and "sonar" fields.
    secrets."deploy_ssh_key_infra" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = "deploy";
      owner = "root";
      mode = "0400";
    };
    secrets."deploy_ssh_key_app" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = "sonar";
      owner = "root";
      mode = "0400";
    };

    # --- Rendered templates ---

    # Docker Compose .env for Supabase
    templates."supabase-env" = {
      content = builtins.concatStringsSep "\n" [
        "POSTGRES_PASSWORD=${p."postgres_password"}"
        "JWT_SECRET=${p."jwt_secret"}"
        "ANON_KEY=${p."anon_key"}"
        "SERVICE_ROLE_KEY=${p."service_role_key"}"
        ""
        "API_EXTERNAL_URL=https://${supabaseDomain}"
        "SITE_URL=https://${domain}"
        "ADDITIONAL_REDIRECT_URLS=https://${domain}/auth/confirm"
        ""
        "SMTP_HOST=smtp.resend.com"
        "SMTP_PORT=465"
        "SMTP_USER=resend"
        "SMTP_PASS=${p."smtp_pass"}"
        "SMTP_ADMIN_EMAIL=noreply@plural-reality.com"
        "SMTP_SENDER_NAME=Sonar"
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

    # Next.js EnvironmentFile — covers all 16 envContract vars.
    # Secret vars use SOPS placeholders; non-secret vars use NixOS config.
    # Optional secrets not yet in SOPS YAML are set to empty string.
    templates."nextjs-env" = {
      content = builtins.concatStringsSep "\n" [
        # --- Required (envContract.vars where required = true) ---
        "SONAR_SUPABASE_URL=https://${supabaseDomain}"
        "SONAR_SUPABASE_ANON_KEY=${p."anon_key"}"
        "OPENROUTER_API_KEY=${p."openrouter_api_key"}"
        "SONAR_BASE_URL=https://${domain}"
        "SONAR_SITE_URL=https://${domain}"
        # --- Optional non-secret ---
        "SONAR_SENTRY_ENVIRONMENT=${environment}"
        "SONAR_SENTRY_DSN="
        "SONAR_UMAMI_URL="
        "SONAR_UMAMI_WEBSITE_ID="
        "RESEND_FROM_EMAIL=noreply@plural-reality.com"
        "GOOGLE_SHEETS_IMPERSONATE_EMAIL="
        "VERTEX_MODEL="
        # --- Optional secret (available in SOPS) ---
        "RESEND_API_KEY=${p."resend_api_key"}"
        # --- Optional secret (not yet in SOPS — set empty) ---
        "NOTIFICATION_SECRET="
        "GOOGLE_SERVICE_ACCOUNT_KEY="
        "VERTEX_API_KEY="
      ];
      owner = "sonar";
    };
  };
}
