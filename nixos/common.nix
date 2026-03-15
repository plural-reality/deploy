{ pkgs, ... }:

{
  config = {
    # --- Nix daemon resource limits (4GB RAM budget, Docker needs more) ---
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

    # --- Swap (2GB — Docker Compose consumes significant RAM) ---
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
      docker-compose
    ];

    # --- SSH ---
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };

    # --- Docker ---
    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
      };
    };

    # --- Application user ---
    users.users.sonar = {
      isSystemUser = true;
      group = "sonar";
      home = "/var/lib/sonar";
      createHome = true;
      extraGroups = [ "docker" ];
    };
    users.groups.sonar = { };

    # --- IMDS route (Docker veth interfaces steal 169.254.0.0/16) ---
    # Policy routing: a dedicated table (100) with a high-priority rule.
    # Docker only modifies the main table; this survives any bridge/veth changes.
    networking.localCommands = ''
      ${pkgs.iproute2}/bin/ip rule del to 169.254.169.254/32 lookup 100 2>/dev/null || true
      ${pkgs.iproute2}/bin/ip rule add to 169.254.169.254/32 lookup 100 priority 100
      ${pkgs.iproute2}/bin/ip route replace 169.254.169.254/32 dev ens5 table 100
    '';

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
