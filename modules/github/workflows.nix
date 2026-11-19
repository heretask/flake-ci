# Workflow presets owned by ci.github; release presets live in ../release.
{
  cfg,
  commits,
  lib,
}: let
  steps = import ./steps.nix {inherit (cfg) extraNixConfig;};
  inherit (steps) flakeCheck nixBuild nixEval nixRun;
  separateChecks = cfg.flakeCheck.separateChecks;
  hestiaCache = cfg.cache == "hestia";
  cacheStep =
    if hestiaCache
    then steps.hestia
    else steps.magicCache;
  # hestia uploads for up to 300 s after the step, even on failure; keep that inside the job timeout.
  flakeCheckTimeout = lib.throwIf (hestiaCache && cfg.flakeCheck.timeoutMinutes <= 10) "ci.github.flakeCheck.timeoutMinutes must be above 10 with ci.github.cache = \"hestia\"" cfg.flakeCheck.timeoutMinutes;
  stepTimeout = jobTimeout: lib.optionalAttrs hestiaCache {timeout-minutes = jobTimeout - 10;};
  checkFlake = jobTimeout:
    {
      name = "Check flake";
      run = flakeCheck;
    }
    // stepTimeout jobTimeout;
  currentSystem = ''system="$(nix eval --impure --raw --expr builtins.currentSystem)"'';
  # Evaluates everything, then builds the checks the separate jobs do not.
  checkFlakeExceptSeparate =
    {
      name = "Check flake";
      run = ''
        ${flakeCheck} --no-build
        ${currentSystem}
        names="$(${nixEval} --raw ".#checks.$system" --apply 'checks: builtins.concatStringsSep "\n" (builtins.attrNames checks)')"
        declare -A separate=(${lib.concatMapStrings (name: "[${lib.escapeShellArg name}]=1 ") separateChecks})
        installables=()
        while IFS= read -r name; do
          if [[ -z "''${separate[$name]:-}" ]]; then
            installables+=(".#checks.$system.\"$name\"")
          fi
        done <<< "$names"
        if (( ''${#installables[@]} )); then
          ${nixBuild} "''${installables[@]}"
        fi
      '';
    }
    // stepTimeout flakeCheckTimeout;
  flakeCheckJob = name: checkStep:
    {
      inherit name;
      runs-on = cfg.flakeCheck.runner;
      timeout-minutes = flakeCheckTimeout;
      steps =
        [
          steps.checkout
          (
            if cfg.flakeCheck.reclaimDisk == "background"
            then steps.reclaimDiskInBackground
            else steps.reclaimDisk
          )
          steps.installNix
          cacheStep
        ]
        ++ checkStep;
    }
    // hestiaJobPermissions;
  hestiaJobPermissions = lib.optionalAttrs hestiaCache {
    permissions = {
      actions = "read";
      contents = "read";
    };
  };

  updateInput = input: {schedule}: let
    title = "chore: update ${input}";
  in {
    name = "Update ${input}";
    on = {
      schedule = [{cron = schedule;}];
      workflow_dispatch = {};
    };
    permissions = {
      contents = "write";
      pull-requests = "write";
    };
    concurrency = {
      group = "update-${input}";
      cancel-in-progress = false;
    };
    jobs.update = {
      name = "update";
      "if" = "github.ref == 'refs/heads/main'";
      runs-on = cfg.runner;
      timeout-minutes = 15;
      steps = [
        (steps.checkout
          // {
            name = "Checkout main (v7.0.1)";
            "with" = {
              ref = "main";
              persist-credentials = false;
            };
          })
        steps.installNix
        {
          name = "Update ${input} (v29)";
          uses = steps.updateFlakeLock;
          "with" = {
            inputs = input;
            nix-options = "--option accept-flake-config false";
            base = "main";
            branch = "automation/${input}";
            commit-msg = title;
            pr-title = title;
            pr-body = ''
              Updates only the `${input}` flake input.

              This PR is refreshed automatically. Make fixes in a separate PR to `main`.

              Approve workflow runs when prompted, then run the normal checks and merge manually.
            '';
          };
        }
      ];
    };
  };
in
  {
    pr-title = {
      name = "PR title";
      on.pull_request.types = [
        "opened"
        "edited"
        "reopened"
        "synchronize"
      ];
      permissions.contents = "read";
      jobs.lint = {
        name = "PR title lint";
        runs-on = cfg.runner;
        timeout-minutes = 5;
        steps = [
          {
            name = "Lint PR title";
            env.PR_TITLE = "\${{ github.event.pull_request.title }}";
            run = ''
              ${commits.titleCheck}

              if ! problem=$(check_title "$PR_TITLE" 2>&1); then
                printf '::error title=Invalid PR title::%s Edit the PR title; this check reruns.\n' "$problem"
                exit 1
              fi
            '';
          }
        ];
      };
    };

    nix-check = {
      name = "Nix";
      on.push.branches = ["main"];
      permissions.contents = "read";
      concurrency =
        if cfg.flakeCheck.queue
        then {
          group = "\${{ github.workflow }}-\${{ github.ref }}";
          cancel-in-progress = false;
          queue = "max";
        }
        else {
          group = "\${{ github.workflow }}-\${{ github.sha }}";
          cancel-in-progress = true;
        };
      jobs =
        {
          flake-check = flakeCheckJob "flake-check" [
            {
              name = "Lint pushed commit";
              "if" = "github.event_name == 'push'";
              env.HEAD_SHA = "\${{ github.sha }}";
              run = ''
                git show --no-patch --format=%B "$HEAD_SHA" |
                  ${nixRun} .#commitlint -- --squash-merged
              '';
            }
            (
              if separateChecks == []
              then checkFlake flakeCheckTimeout
              else checkFlakeExceptSeparate
            )
          ];
        }
        // lib.listToAttrs (map (check:
          lib.nameValuePair "check-${check}" (flakeCheckJob check [
            ({
                name = "Build ${check}";
                run = ''
                  ${currentSystem}
                  ${nixBuild} ".#checks.$system.\"${check}\""
                '';
              }
              // stepTimeout flakeCheckTimeout)
          ]))
        separateChecks);
    };
  }
  // lib.optionalAttrs cfg.darwinCheck {
    nix-check-darwin = {
      name = "Nix Darwin";
      on.workflow_dispatch = {};
      permissions.contents = "read";
      concurrency = {
        group = "\${{ github.workflow }}-\${{ github.ref }}";
        cancel-in-progress = true;
      };
      jobs.flake-check-darwin =
        {
          name = "flake-check (aarch64-darwin)";
          runs-on = "macos-15";
          timeout-minutes = 60;
          steps = [
            steps.checkout
            steps.installNix
            cacheStep
            (checkFlake 60)
          ];
        }
        // hestiaJobPermissions;
    };
  }
  // lib.optionalAttrs hestiaCache {
    hestia-gc = {
      name = "Hestia cache GC";
      on = {
        schedule = [{cron = "23 3 * * *";}];
        workflow_dispatch.inputs.dry-run = {
          description = "Plan only; do not repack, touch, or delete anything.";
          type = "boolean";
          default = false;
        };
      };
      permissions.contents = "read";
      concurrency = {
        group = "hestia-gc";
        cancel-in-progress = false;
      };
      jobs.gc = {
        name = "hestia-gc";
        runs-on = cfg.runner;
        timeout-minutes = 15;
        permissions = {
          actions = "write";
          contents = "read";
        };
        steps = [
          steps.installNix
          (steps.hestia // {"with" = {inherit (steps.hestia."with") version;};})
          {
            name = "Run garbage collection";
            run = "\"$HESTIA_BIN\" gc \${{ inputs.dry-run && '--dry-run' || '' }}";
            env.GITHUB_TOKEN = "\${{ github.token }}";
          }
        ];
      };
    };
  }
  // lib.mapAttrs' (input: update: lib.nameValuePair "update-${input}" (updateInput input update)) cfg.inputUpdates
