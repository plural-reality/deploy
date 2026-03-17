# SOPS secret declarations for Cartographer
# Decrypted at boot by sops-nix via IAM Instance Profile -> KMS
#
# To add a secret:
#   1. `sops secrets/cartographer/{stg,prd}.yaml` -> add the key
#   2. Add a `secrets."key_name"` declaration below
#   3. Add the corresponding line to the cartographer-env template
{ config, lib, ... }:

let
  hostname = config.networking.hostName;
  environment = lib.removePrefix "cartographer-" hostname;
  domain = config.cartographer.domain;
  p = config.sops.placeholder;
in
{
  config.sops = {
    defaultSopsFile = config.cartographer.secretsFile;

    # KMS-only decryption (no age/pgp keys)
    age = { };

    secrets = {
      # --- App secrets (envContract.vars where secret = true) ---
      "supabase_service_role_key" = { };
      "openrouter_api_key" = { };
      "workos_api_key" = { };
      "workos_cookie_password" = { };
      "auth_supabase_service_role_key" = { };

      # --- TLS (Cloudflare Origin CA) ---
      "origin_cert" = {
        owner = "nginx";
        mode = "0644";
      };
      "origin_key" = {
        owner = "nginx";
        mode = "0640";
      };
    };

    # --- EnvironmentFile — all env-contract vars ---
    # Secret vars use SOPS placeholders; non-secret vars use NixOS config.
    templates."cartographer-env" = {
      content = builtins.concatStringsSep "\n" [
        # --- Required secrets ---
        "SUPABASE_SERVICE_ROLE_KEY=${p."supabase_service_role_key"}"
        "OPENROUTER_API_KEY=${p."openrouter_api_key"}"
        "WORKOS_API_KEY=${p."workos_api_key"}"
        "WORKOS_COOKIE_PASSWORD=${p."workos_cookie_password"}"
        # --- Required non-secrets (from NixOS config) ---
        "WORKOS_CLIENT_ID=${config.cartographer.workosClientId}"
        "NEXT_PUBLIC_SUPABASE_URL=${config.cartographer.supabaseUrl}"
        "NEXT_PUBLIC_SUPABASE_ANON_KEY=${config.cartographer.supabaseAnonKey}"
        # --- Optional non-secrets ---
        "NEXT_PUBLIC_SENTRY_ENVIRONMENT=${environment}"
        "NEXT_PUBLIC_SENTRY_DSN="
        "NEXT_PUBLIC_SITE_URL=https://${domain}"
        "NEXT_PUBLIC_WORKOS_REDIRECT_URI=https://${domain}/callback"
        "OPENROUTER_API_URL="
        "NEXT_PUBLIC_UMAMI_URL="
        "NEXT_PUBLIC_UMAMI_WEBSITE_ID="
        # --- Optional secrets ---
        "AUTH_SUPABASE_SERVICE_ROLE_KEY=${p."auth_supabase_service_role_key"}"
        # --- Legacy (deprecated, target removal: 2026-06-01) ---
        "NEXT_PUBLIC_AUTH_SUPABASE_URL="
        "NEXT_PUBLIC_AUTH_SUPABASE_ANON_KEY="
      ];
      owner = "cartographer";
    };
  };
}
