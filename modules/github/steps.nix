# Pinned actions and steps shared by the workflow presets.
{extraNixConfig}: {
  checkout = {
    name = "Checkout (v7.0.1)";
    uses = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"; # v7.0.1
  };

  installNix =
    {
      name = "Install Determinate Nix (v22)";
      uses = "DeterminateSystems/nix-installer-action@ef8a148080ab6020fd15196c2084a2eea5ff2d25"; # v22
    }
    // (
      if extraNixConfig == ""
      then {}
      else {"with"."extra-conf" = extraNixConfig;}
    );

  magicCache = {
    name = "Enable Magic Nix Cache (v14)";
    uses = "DeterminateSystems/magic-nix-cache-action@908b263ff629f4cc17666315b7fd3ec127c6244d"; # v14
  };

  hestia = {
    name = "Enable hestia cache (v3.1.0)";
    uses = "Mic92/hestia@dfed9ced335d28978ba74e513939a10db1f71025"; # v3.1.0
    "with" = {
      version = "v3.1.0";
      upstream-cache-filter = "true";
    };
  };

  updateFlakeLock = "DeterminateSystems/update-flake-lock@834c491b2ece4de0bbd00d85214bb5e83b4da5c6"; # v28
  createAppToken = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"; # v3.2.0
  createPullRequest = "peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1"; # v8.1.1

  reclaimDisk = {
    name = "Reclaim hosted runner disk";
    run = ''
      df -h /

      remove() {
        local path="$1"
        local started="$SECONDS"
        sudo rm -rf -- "$path"
        printf 'Removed %s in %ss\n' "$path" "$((SECONDS - started))"
      }

      pids=()
      for path in \
        /opt/ghc \
        /usr/local/.ghcup \
        /usr/local/lib/android \
        /usr/share/dotnet
      do
        remove "$path" &
        pids+=("$!")
      done

      for pid in "''${pids[@]}"; do
        wait "$pid"
      done

      df -h /
    '';
  };

  # Flake config from the checkout is never trusted in CI.
  nixRun = "nix run --option accept-flake-config false";
  flakeCheck = "nix flake check -L --option accept-flake-config false";
}
