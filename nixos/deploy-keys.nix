# SSH deploy keys — SOPS declarations only.
# One key per GitHub repo (GitHub deploy key limitation).
# secrets/ssh/deploy.yaml fields: "deploy" (infra repo), "sonar" (app repo).
{ ... }:
{
  sops = {
    age = { };
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
  };
}
