# SOPS secret declarations — decrypted at boot by sops-nix via IAM Instance Profile -> KMS
#
# The canonical env var contract lives in the sonar app repo (env-contract.json),
# passed here as `envContract` via specialArgs. This module maps each contract var
# to either a SOPS placeholder (secret) or a NixOS-derived value (non-secret).
#
# Optional secret vars not yet in the SOPS YAML are omitted — the app handles
# their absence gracefully. To add one:
#   1. `sops secrets/sonar-{staging,prod}.yaml` → add the key
#   2. Add a `secrets."key_name"` declaration below
#   3. Add the corresponding line to the nextjs-env template
#
# Currently missing optional secrets:
#   - notification_secret       → NOTIFICATION_SECRET
#   - google_service_account_key → GOOGLE_SERVICE_ACCOUNT_KEY
#   - vertex_api_key            → VERTEX_API_KEY
{ config, lib, envContract, ... }:

let
  environment = config.sonar.secretsEnvironment;
  domain = config.sonar.domain;
  supabaseDomain = config.sonar.supabaseDomain;
  p = config.sops.placeholder;
in
{
  options.sonar.secretsEnvironment = lib.mkOption {
    type = lib.types.enum [ "prod" "staging" ];
    description = "Which SOPS secret file to use (sonar-prod.yaml or sonar-staging.yaml)";
  };

  config.sops = {
    defaultSopsFile = ../secrets/sonar-${environment}.yaml;

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
