# Workflow presets owned by ci.github; release presets live in ../release.
{
  cfg,
  commits,
  lib,
}: let
  steps = import ./steps.nix {inherit (cfg) extraNixConfig;};
  inherit (steps) flakeCheck nixRun;
  hestiaCache = cfg.cache == "hestia";
  cacheStep =
    if hestiaCache
    then steps.hestia
    else steps.magicCache;
  # hestia uploads for up to 300 s after the step, even on failure; keep that inside the job timeout.
  flakeCheckTimeout = lib.throwIf (hestiaCache && cfg.flakeCheck.timeoutMinutes <= 10) "ci.github.flakeCheck.timeoutMinutes must be above 10 with ci.github.cache = \"hestia\"" cfg.flakeCheck.timeoutMinutes;
  checkFlake = jobTimeout:
    {
      name = "Check flake";
      run = flakeCheck;
    }
    // lib.optionalAttrs hestiaCache {timeout-minutes = jobTimeout - 10;};
  hestiaJobPermissions = lib.optionalAttrs hestiaCache {
    permissions = {
      actions = "read";
      contents = "read";
    };
  };

  updateInput = input: {schedule}: let
    title = "chore(nix): update ${input}";
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
          name = "Update ${input} (v28)";
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
            env = {
              PR_TITLE = "\${{ github.event.pull_request.title }}";
              TITLE_PATTERN = commits.titlePattern;
            };
            run = ''
              if [[ ! "$PR_TITLE" =~ $TITLE_PATTERN ]]; then
                printf 'Invalid PR title: %s\nExpected pattern: %s\n' "$PR_TITLE" "$TITLE_PATTERN" >&2
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
      concurrency = {
        group = "\${{ github.workflow }}-\${{ github.sha }}";
        cancel-in-progress = true;
      };
      jobs.flake-check =
        {
          name = "flake-check";
          runs-on = cfg.flakeCheck.runner;
          timeout-minutes = flakeCheckTimeout;
          steps = [
            steps.checkout
            steps.reclaimDisk
            steps.installNix
            cacheStep
            {
              name = "Lint pushed commit";
              "if" = "github.event_name == 'push'";
              env.HEAD_SHA = "\${{ github.sha }}";
              run = ''
                git show --no-patch --format=%B "$HEAD_SHA" |
                  ${nixRun} .#commitlint
              '';
            }
            (checkFlake flakeCheckTimeout)
          ];
        }
        // hestiaJobPermissions;
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
