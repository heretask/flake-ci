# Pinned actions and steps shared by the workflow presets.
{extraNixConfig}: let
  # Preinstalled toolchains flake checks never use; together about 20 GB of the runner's root disk.
  reclaimPaths = [
    "/opt/ghc"
    "/usr/local/.ghcup"
    "/usr/local/lib/android"
    "/usr/share/dotnet"
  ];
in {
  checkout = {
    name = "Checkout (v7.0.1)";
    uses = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"; # v7.0.1
  };

  installNix =
    {
      name = "Install Determinate Nix (v23)";
      uses = "DeterminateSystems/nix-installer-action@3138316df39ed29be04236d7ffc686fa525866aa"; # v23
    }
    // (
      if extraNixConfig == ""
      then {}
      else {"with"."extra-conf" = extraNixConfig;}
    );

  magicCache = {
    name = "Enable Magic Nix Cache (v15)";
    uses = "DeterminateSystems/magic-nix-cache-action@84c0677f58dcedf3b91f8223ce36a9ea5b3c84b7"; # v15
  };

  hestia = {
    name = "Enable hestia cache (v3.1.0)";
    uses = "Mic92/hestia@dfed9ced335d28978ba74e513939a10db1f71025"; # v3.1.0
    "with" = {
      version = "v3.1.0";
      upstream-cache-filter = "true";
    };
  };

  flakeChecker = {
    name = "Check flake.lock (v14)";
    uses = "DeterminateSystems/flake-checker-action@786422608c7bded2bbc9741ad9f91356842bf520"; # v14
  };

  uploadArtifact = {
    name = "Upload artifact (v7.0.2)";
    uses = "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9"; # v7.0.2
  };

  updateFlakeLock = "DeterminateSystems/update-flake-lock@da03c0f078bc4b2c37ee4f7e072d34bf8f188bb3"; # v29
  createPullRequest = "peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1"; # v8.1.1

  # Writes `steps.app-token.outputs.token`. `app` names the App in the step name.
  appToken = app: {
    clientIdVariable,
    privateKeySecret,
  }: permissions: {
    name = "Create ${app} App token (v3.3.0)";
    id = "app-token";
    uses = "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510"; # v3.3.0
    "with" =
      {
        client-id = "\${{ vars.${clientIdVariable} }}";
        private-key = "\${{ secrets.${privateKeySecret} }}";
      }
      // permissions;
  };

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
        ${builtins.concatStringsSep " \\\n  " reclaimPaths}
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

  # Builds start on the ~14 GB already free while removal finishes behind Nix install and eval.
  # Output goes to a file so the step does not wait on the detached removal.
  reclaimDiskInBackground = {
    name = "Reclaim hosted runner disk in the background";
    run = ''
      reclaim() {
        local started="$SECONDS"
        for path in ${builtins.concatStringsSep " " reclaimPaths}; do
          sudo rm -rf -- "$path" &
        done
        wait
        printf 'Reclaimed in %ss\n' "$((SECONDS - started))"
        df -h /
      }

      reclaim > "$RUNNER_TEMP/reclaim-disk.log" 2>&1 &
    '';
  };

  # Mounts /nix on a btrfs volume over the free disk, then grows it as Carve's background purge
  # frees toolchains. Must run before Nix is installed. Carve keeps Docker and apt packages.
  nothingButNix = {
    name = "Make room for Nix (nothing-but-nix v12)";
    uses = "wimpysworld/nothing-but-nix@b2574ec1cf1462bee0a34de0fb6ff11ad3c43cb2"; # v12
    "with".hatchet-protocol = "carve";
  };

  # Flake config from the checkout is never trusted in CI.
  nixRun = "nix run --option accept-flake-config false";
  flakeCheck = "nix flake check -L --option accept-flake-config false";
  flakeCheckNoBuild = "nix flake check -L --no-build --option accept-flake-config false";
  nixBuild = "nix build -L --option accept-flake-config false";

  # Evaluates the flake once and lists the checks that are not cached yet. `flake` limits the matrix
  # to one system. Build jobs run on `runner`: hestia's default runner map would ignore it.
  # nix-eval-jobs comes from the consumer's `nixpkgs` input, which earlier steps already fetched;
  # the runner's registry nixpkgs would be downloaded only for this. Without such an input,
  # `--inputs-from .` changes nothing and the registry is used.
  hestiaMatrix = nixRun: flake: runner: {
    id = "matrix";
    name = "Build matrix (hestia)";
    uses = "Mic92/hestia/matrix@dfed9ced335d28978ba74e513939a10db1f71025"; # v3.1.0
    "with" = {
      inherit flake;
      runner-map = "x86_64-linux=${runner}";
      nix-eval-jobs = "${nixRun} --inputs-from . nixpkgs#nix-eval-jobs --";
    };
  };
}
