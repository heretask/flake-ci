# Workflow presets owned by ci.github; release presets live in ../release.
{
  cfg,
  commits,
  lib,
  checkVersionInvariance ? false,
}: let
  steps = import ./steps.nix {inherit (cfg) extraNixConfig;};
  inherit (steps) flakeCheck flakeCheckNoBuild nixBuild nixRun;
  hestiaCache = cfg.cache == "hestia";
  gcPushTtl = lib.optionalString (cfg.hestiaGc.pushTtlDays != null) " --push-ttl ${toString cfg.hestiaGc.pushTtlDays}";
  cacheStep =
    if hestiaCache
    then steps.hestia
    else steps.magicCache;
  # hestia uploads for up to 300 s after the step, even on failure; keep that inside the job timeout.
  flakeCheckTimeout = lib.throwIf (hestiaCache && cfg.flakeCheck.timeoutMinutes <= 10) "ci.github.flakeCheck.timeoutMinutes must be above 10 with ci.github.cache = \"hestia\"" cfg.flakeCheck.timeoutMinutes;
  flakeMatrix = lib.throwIf (cfg.flakeCheck.matrix && !hestiaCache) "ci.github.flakeCheck.matrix requires ci.github.cache = \"hestia\"" cfg.flakeCheck.matrix;
  timedStep = jobTimeout: step: step // lib.optionalAttrs hestiaCache {timeout-minutes = jobTimeout - 10;};
  checkFlake = jobTimeout:
    timedStep jobTimeout {
      name = "Check flake";
      run = flakeCheck;
    };
  evaluateFlake = timedStep flakeCheckTimeout {
    name = "Evaluate flake";
    run = flakeCheckNoBuild;
  };
  versionInvarianceStep = {
    name = "Check VERSION invariance";
    run = "${nixRun} .#release -- check-version-invariance";
  };
  hestiaJobPermissions = lib.optionalAttrs hestiaCache {
    permissions = {
      actions = "read";
      contents = "read";
    };
  };
  reclaimSteps = {
    foreground = steps.reclaimDisk;
    background = steps.reclaimDiskInBackground;
    nothing-but-nix = steps.nothingButNix;
  };
  reclaimStep = reclaimSteps.${cfg.flakeCheck.reclaimDisk};
  lintCommit = {
    name = "Lint pushed commit";
    "if" = "github.event_name == 'push'";
    env.HEAD_SHA = "\${{ github.sha }}";
    run = ''
      git show --no-patch --format=%B "$HEAD_SHA" |
        ${nixRun} .#commitlint -- --squash-merged
    '';
  };
  # Build jobs take the eval job's manifest version so they see the registered drv closures.
  hestiaBuild =
    steps.hestia
    // {
      "with" =
        steps.hestia."with"
        // {wait-manifest-version = "\${{ needs.eval.outputs.manifest-version }}";};
    };

  prHead = "\${{ github.event.pull_request.head.sha }}";
  sameRepository = "github.event.pull_request.head.repo.full_name == github.repository";
  # The Nix PR workflow starts on every push to a same-repository pull request, so its first job
  # lints the title there and posts it as the `PR title lint` commit status. The PR title workflow
  # then only has to run when the title changes, and for forks, whose token cannot post a status.
  lintTitleInNixPr = cfg.flakeCheck.enable && cfg.flakeCheck.pullRequests.enable;
  # `report` posts the commit status; `enforce` fails the step on an invalid title.
  lintTitle = {
    report,
    enforce,
  }: {
    name = "Lint PR title";
    env =
      {PR_TITLE = "\${{ github.event.pull_request.title }}";}
      // lib.optionalAttrs (report != "false") {
        REPORT = report;
        GH_TOKEN = "\${{ github.token }}";
        HEAD_SHA = prHead;
        PR_NUMBER = "\${{ github.event.pull_request.number }}";
      }
      // lib.optionalAttrs enforce {ENFORCE = "true";};
    run = ''
      ${commits.titleCheck}

      ${builtins.readFile ./pr-title.sh}'';
  };
  # A check job on a pull request also reads the title and posts its status.
  checkJobPermissions = pullRequest:
    if pullRequest
    then {
      permissions =
        {
          contents = "read";
          pull-requests = "read";
          statuses = "write";
        }
        // lib.optionalAttrs hestiaCache {actions = "read";};
    }
    else hestiaJobPermissions;
  flakeJobs = pullRequest: let
    filtered = pullRequest && cfg.flakeCheck.pullRequests.skipChecks != [];
    checkOutput =
      if filtered
      then "prChecks"
      else "checks";
    checkout =
      if pullRequest
      then
        steps.checkout
        // {
          "with" = {
            ref = prHead;
            persist-credentials = false;
          };
        }
      else steps.checkout;
    onlySameRepository = lib.optionalAttrs pullRequest {"if" = sameRepository;};
    # Early, so an invalid title is reported within seconds. An invalid title does not fail the job.
    lintPullRequestTitle = lib.optional pullRequest (lintTitle {
      report = "true";
      enforce = false;
    });
    setupSteps = [checkout] ++ lintPullRequestTitle ++ [reclaimStep steps.installNix cacheStep] ++ lib.optional (!pullRequest) lintCommit;
  in
    if flakeMatrix
    then {
      eval =
        {
          name = "eval";
          runs-on = cfg.flakeCheck.runner;
          timeout-minutes = flakeCheckTimeout;
          outputs = {
            matrix = "\${{ steps.matrix.outputs.matrix }}";
            any-jobs = "\${{ steps.matrix.outputs.any-jobs }}";
            manifest-version = "\${{ steps.matrix.outputs.manifest-version }}";
          };
          steps =
            setupSteps
            ++ [evaluateFlake]
            ++ lib.optional checkVersionInvariance versionInvarianceStep
            ++ [
              # One system only: the runner cannot build other systems' checks, and hestia's
              # default runner map would send darwin checks to macOS runners.
              (steps.hestiaMatrix nixRun ".#${checkOutput}.x86_64-linux" cfg.flakeCheck.runner)
            ];
        }
        // checkJobPermissions pullRequest
        // onlySameRepository;
      build =
        {
          name = "\${{ matrix.name }}";
          needs = "eval";
          "if" = "needs.eval.outputs.any-jobs == 'true'";
          runs-on = "\${{ matrix.os }}";
          strategy = {
            fail-fast = false;
            matrix = "\${{ fromJSON(needs.eval.outputs.matrix) }}";
          };
          timeout-minutes = flakeCheckTimeout;
          steps = [
            reclaimStep
            steps.installNix
            hestiaBuild
            {
              name = "Prefetch drv closure";
              run = "\"$HESTIA_BIN\" prefetch \${{ matrix.installables }}";
            }
            (timedStep flakeCheckTimeout {
              name = "Build check";
              run = "${nixBuild} \${{ matrix.installables }}";
            })
          ];
        }
        // hestiaJobPermissions;
    }
    else {
      flake-check =
        {
          name = "flake-check";
          runs-on = cfg.flakeCheck.runner;
          timeout-minutes = flakeCheckTimeout;
          steps =
            setupSteps
            ++ (
              if filtered
              then
                [evaluateFlake]
                ++ lib.optional checkVersionInvariance versionInvarianceStep
                ++ [
                  (timedStep flakeCheckTimeout {
                    name = "Build PR checks";
                    run = ''
                      set -o pipefail
                      system="$(nix eval --impure --raw --expr builtins.currentSystem)"
                      nix eval --option accept-flake-config false --raw ".#${checkOutput}.$system" \
                        --apply 'checks: builtins.concatStringsSep "\n" (map (check: check.drvPath + "^*") (builtins.attrValues checks))' |
                        ${nixBuild} --no-link --stdin
                    '';
                  })
                ]
              else lib.optional checkVersionInvariance versionInvarianceStep ++ [(checkFlake flakeCheckTimeout)]
            );
        }
        // checkJobPermissions pullRequest
        // onlySameRepository;
    };

  updateInput = input: {
    schedule,
    appToken,
  }: let
    title = "chore: update ${input}";
  in {
    name = "Update ${input}";
    on = {
      schedule = [{cron = schedule;}];
      workflow_dispatch = {};
    };
    permissions =
      if appToken == null
      then {
        contents = "write";
        pull-requests = "write";
      }
      else {contents = "read";};
    concurrency = {
      group = "update-${input}";
      cancel-in-progress = false;
    };
    jobs.update = {
      name = "update";
      "if" = "github.ref == 'refs/heads/main'";
      runs-on = cfg.runner;
      timeout-minutes = 15;
      steps =
        lib.optional (appToken != null) (steps.appToken "update" appToken {
          permission-contents = "write";
          permission-pull-requests = "write";
        })
        ++ [
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
            "with" =
              {
                inputs = input;
                nix-options = "--option accept-flake-config false";
                base = "main";
                branch = "automation/${input}";
                commit-msg = title;
                pr-title = title;
                pr-body = ''
                  Updates only the `${input}` flake input.

                  This PR is refreshed automatically. Make fixes in a separate PR to `main`.

                  ${
                    if appToken == null
                    then "Approve workflow runs when prompted, then run the normal checks and merge manually."
                    else "Merge manually once the checks pass."
                  }
                '';
              }
              // lib.optionalAttrs (appToken != null) {token = "\${{ steps.app-token.outputs.token }}";};
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
      jobs.lint =
        {
          name = "PR title lint";
          runs-on = cfg.runner;
          timeout-minutes = 5;
          steps = [
            (lintTitle {
              report =
                if lintTitleInNixPr
                then "\${{ ${sameRepository} }}"
                else "false";
              enforce = true;
            })
          ];
        }
        # Skipped on a push to a same-repository pull request: the skipped check satisfies the
        # required `PR title lint` check, and the Nix PR workflow posts the status of the same name.
        // lib.optionalAttrs lintTitleInNixPr {
          "if" = "github.event.pull_request.head.repo.full_name != github.repository || (github.event.action == 'edited' && github.event.changes.title != null)";
          permissions = {
            pull-requests = "read";
            statuses = "write";
          };
        };
    };

    # A null name omits the workflow.
    ${
      if cfg.flakeCheck.enable
      then "nix-check"
      else null
    } = {
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
      jobs = flakeJobs false;
    };
  }
  // lib.optionalAttrs (cfg.flakeCheck.enable && cfg.flakeCheck.pullRequests.enable) {
    nix-check-pr = {
      name = "Nix PR";
      on.pull_request = {};
      permissions.contents = "read";
      concurrency = {
        group = "\${{ github.workflow }}-\${{ github.event.pull_request.number }}";
        cancel-in-progress = true;
      };
      jobs =
        flakeJobs true
        // {
          publish =
            {
              name = "Publish Nix result";
              runs-on = cfg.runner;
              timeout-minutes = 5;
              permissions.statuses = "write";
              steps = [
                {
                  name = "Sign off on the tested commit";
                  env = {
                    GH_TOKEN = "\${{ github.token }}";
                    HEAD_SHA = prHead;
                  };
                  run = ''
                    gh api --method POST "repos/$GITHUB_REPOSITORY/statuses/$HEAD_SHA" \
                      -f context=signoff -f state=success -f 'description=Nix PR checks passed' \
                      -f "target_url=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
                  '';
                }
              ];
            }
            // (
              if flakeMatrix
              then {
                needs = ["eval" "build"];
                "if" = "!cancelled() && !failure() && needs.eval.result == 'success' && (needs.build.result == 'success' || (needs.build.result == 'skipped' && needs.eval.outputs.any-jobs == 'false'))";
              }
              else {needs = "flake-check";}
            );
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
            run = "\"$HESTIA_BIN\" gc${gcPushTtl} \${{ inputs.dry-run && '--dry-run' || '' }}";
            env.GITHUB_TOKEN = "\${{ github.token }}";
          }
        ];
      };
    };
  }
  // lib.mapAttrs' (input: update: lib.nameValuePair "update-${input}" (updateInput input update)) cfg.inputUpdates
