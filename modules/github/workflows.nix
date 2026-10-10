# Workflow presets owned by ci.github; release presets live in ../release.
{
  cfg,
  commits,
  lib,
}: let
  steps = import ./steps.nix {inherit (cfg) extraNixConfig;};
  inherit (steps) flakeCheck nixRun;

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
      jobs.flake-check = {
        name = "flake-check";
        runs-on = cfg.flakeCheck.runner;
        timeout-minutes = cfg.flakeCheck.timeoutMinutes;
        steps = [
          steps.checkout
          steps.reclaimDisk
          steps.installNix
          steps.magicCache
          {
            name = "Lint pushed commit";
            "if" = "github.event_name == 'push'";
            env.HEAD_SHA = "\${{ github.sha }}";
            run = ''
              git show --no-patch --format=%B "$HEAD_SHA" |
                ${nixRun} .#commitlint
            '';
          }
          {
            name = "Check flake";
            run = flakeCheck;
          }
        ];
      };
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
      jobs.flake-check-darwin = {
        name = "flake-check (aarch64-darwin)";
        runs-on = "macos-15";
        timeout-minutes = 60;
        steps = [
          steps.checkout
          steps.installNix
          steps.magicCache
          {
            name = "Check flake";
            run = flakeCheck;
          }
        ];
      };
    };
  }
  // lib.mapAttrs' (input: update: lib.nameValuePair "update-${input}" (updateInput input update)) cfg.inputUpdates
