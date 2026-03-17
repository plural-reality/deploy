# Common NixOS configuration — shared by all app nodes.
# App-specific concerns (Docker, users, etc.) belong in the app's own module.
{ pkgs, ... }:

{
  config = {
    # --- Nix daemon resource limits (4GB RAM budget) ---
    nix.settings = {
      max-jobs = 1;
      cores = 2;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      substituters = [
        "https://plural-reality.cachix.org"
        "https://cache.nixos.org"
      ];
      trusted-public-keys = [
        "plural-reality.cachix.org-1:239F7m1UlqIqB/08o1JTXsUbICmBZgRV/65dtiDrzR8="
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    systemd.services.nix-daemon.serviceConfig = {
      MemoryMax = "2048M";
      MemorySwapMax = "0";
      OOMScoreAdjust = 500;
    };

    # --- Swap (2GB — useful for on-target builds) ---
    swapDevices = [
      {
        device = "/swapfile";
        size = 2048;
      }
    ];

    # --- System packages ---
    environment.systemPackages = with pkgs; [
      vim
      htop
      git
    ];

    # --- SSH ---
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    # --- Firewall ---
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [
        22
        80
        443
      ];
    };

    system.stateVersion = "25.11";
  };
}
