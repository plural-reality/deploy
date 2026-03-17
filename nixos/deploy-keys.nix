# SSH deploy keys — SOPS declarations only.
# One key per GitHub repo (GitHub deploy key limitation).
# secrets/ssh/deploy.yaml fields: "deploy" (infra repo), app key (per-app).
{ config, lib, ... }:
{
  options.deploy.appSshKeyName = lib.mkOption {
    type = lib.types.str;
    default = "sonar";
    description = "Key name in secrets/ssh/deploy.yaml for the app repo SSH key";
  };

  config.sops = {
    age = { };
    secrets."deploy_ssh_key_infra" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = "deploy";
      owner = "root";
      mode = "0400";
    };
    secrets."deploy_ssh_key_app" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = config.deploy.appSshKeyName;
      owner = "root";
      mode = "0400";
    };
  };
}
