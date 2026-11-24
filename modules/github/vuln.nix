# Generated workflows that run `nix run .#vuln` for every `ci.vuln.targets` entry.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  github = config.ci.github;
  cfg = github.vuln;
  steps = import ./steps.nix {inherit (github) extraNixConfig;};

  # Only the names: reading a target's contents would tie the committed workflow to the inputs it
  # is built from, and a lock-only change would then make the workflow file stale.
  targets = builtins.attrNames (config.allSystems.${cfg.system}.ci.vuln.targets or {});

  hestiaCache = github.cache == "hestia";
  onSchedule = "github.event_name == 'schedule'";
  checkout = steps.checkout // {"with".persist-credentials = false;};
  tokenSteps = lib.optional (cfg.inputToken != null) (steps.appToken "input" {inherit (cfg.inputToken) clientIdVariable privateKeySecret;} {
    owner = "\${{ github.repository_owner }}";
    repositories = lib.concatStringsSep "," cfg.inputToken.repositories;
    permission-contents = "read";
  });
  # vuln runs nix itself, so the settings go in the environment, not on one command line.
  scanEnv.NIX_CONFIG =
    lib.optionalString (cfg.inputToken != null) "access-tokens = github.com=\${{ steps.app-token.outputs.token }}\n"
    + "accept-flake-config = false\n";
  concurrency = {
    group = "\${{ github.workflow }}-\${{ github.event.pull_request.number || github.ref }}";
    cancel-in-progress = "\${{ github.event_name == 'pull_request' }}";
  };

  # One open issue per title: opened by the first scheduled failure, closed by the next scheduled pass.
  report = title: needs: {
    name = "report";
    inherit needs;
    "if" = "always() && ${onSchedule}";
    runs-on = github.runner;
    timeout-minutes = 5;
    permissions.issues = "write";
    steps = [
      {
        name = "Open or close the failure issue";
        env = {
          GH_TOKEN = "\${{ github.token }}";
          GH_REPO = "\${{ github.repository }}";
          TITLE = title;
          PASSED = "\${{ !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') }}";
          RUN_URL = "\${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}";
        };
        run = ''
          number=$(gh issue list --state open --search "in:title \"$TITLE\"" --json number,title --jq 'map(select(.title == env.TITLE))[0].number // empty')
          if [[ $PASSED == true ]]; then
            if [[ -n $number ]]; then
              gh issue close "$number" --comment "The scheduled scan passed: $RUN_URL"
            fi
          elif [[ -z $number ]]; then
            gh issue create --title "$TITLE" --body "The scheduled scan failed: $RUN_URL

          This issue closes itself when a scheduled scan passes."
          fi
        '';
      }
    ];
  };

  full = {
    name = "Vulnerability scan";
    on =
      {
        schedule = [{cron = cfg.schedule;}];
        workflow_dispatch = {};
      }
      // lib.optionalAttrs (cfg.fullScanPaths != []) {
        push = {
          branches = ["main"];
          paths = cfg.fullScanPaths;
        };
        pull_request.paths = cfg.fullScanPaths;
      };
    permissions = {};
    inherit concurrency;
    jobs =
      {
        scan = {
          name = "scan";
          strategy = {
            fail-fast = false;
            matrix.target = targets;
          };
          runs-on = cfg.runner;
          timeout-minutes = cfg.timeoutMinutes;
          permissions = {contents = "read";} // lib.optionalAttrs hestiaCache {actions = "read";};
          steps =
            [checkout]
            ++ tokenSteps
            ++ lib.optional cfg.nothingButNix steps.nothingButNix
            ++ [
              steps.installNix
              (
                if hestiaCache
                then steps.hestia
                else steps.magicCache
              )
              ({
                  name = "Scan target";
                  env = scanEnv // {TARGET = "\${{ matrix.target }}";};
                  run = ''nix run .#vuln -- "$TARGET"'';
                }
                # hestia uploads for up to 300 s after the step; keep that inside the job timeout.
                // lib.optionalAttrs hestiaCache {timeout-minutes = cfg.timeoutMinutes - 10;})
            ];
        };
      }
      // lib.optionalAttrs (cfg.nixpkgsKeys != []) {
        # Its own job, so a stale pin does not hide the scan results.
        staleness = {
          name = "staleness";
          "if" = "${onSchedule} || github.event_name == 'workflow_dispatch'";
          runs-on = github.runner;
          timeout-minutes = 5;
          permissions.contents = "read";
          steps = [
            checkout
            (steps.flakeChecker
              // {
                "with" = {
                  fail-mode = true;
                  nixpkgs-keys = lib.concatStringsSep "," cfg.nixpkgsKeys;
                  send-statistics = false;
                };
              })
          ];
        };
      }
      // lib.optionalAttrs cfg.failureIssue {
        report = report "Vulnerability scan failed" (["scan"] ++ lib.optional (cfg.nixpkgsKeys != []) "staleness");
      };
  };

  quick = {
    name = "Vulnerability scan (lockfiles)";
    on =
      {workflow_dispatch = {};}
      // lib.optionalAttrs cfg.quick.pullRequests {pull_request = {};}
      // lib.optionalAttrs (cfg.quick.schedule != null) {schedule = [{cron = cfg.quick.schedule;}];};
    permissions = {};
    inherit concurrency;
    jobs =
      {
        lockfiles = {
          name = "lockfiles";
          runs-on = github.runner;
          timeout-minutes = 20;
          permissions.contents = "read";
          steps =
            [checkout]
            ++ tokenSteps
            ++ [
              steps.installNix
              {
                name = "Scan lockfiles";
                env = scanEnv;
                # Every target, so one finding does not hide another target's.
                run = ''
                  rc=0
                  for target in ${lib.escapeShellArgs targets}; do
                    nix run .#vuln -- "$target" --quick || rc=1
                  done
                  exit "$rc"
                '';
              }
            ];
        };
      }
      // lib.optionalAttrs (cfg.failureIssue && cfg.quick.schedule != null) {
        report = report "Vulnerability scan failed (lockfiles)" ["lockfiles"];
      };
  };
in {
  options.ci.github.vuln = {
    enable = lib.mkEnableOption "generated workflows that scan every `ci.vuln.targets` entry";

    system = mkOption {
      type = types.str;
      default = "x86_64-linux";
      description = "System whose `ci.vuln.targets` names the workflows scan. It must be the runner's.";
    };

    schedule = mkOption {
      type = types.str;
      default = "41 5 * * *";
      description = "Cron schedule (UTC) of the full scan of every target.";
    };

    fullScanPaths = mkOption {
      type = types.listOf types.str;
      default = ["flake.lock"];
      example = ["flake.lock" "modules/**"];
      description = ''
        Paths that change what a target ships. A pull request or a push to `main` that touches one
        runs the full scan, so a change is scanned when it is made instead of at the next schedule.
        `[]` leaves the full scan to the schedule.
      '';
    };

    quick.pullRequests = mkOption {
      type = types.bool;
      default = true;
      description = "Run `vuln <target> --quick` for every target on each pull request. It builds nothing.";
    };

    quick.schedule = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "11 */4 * * *";
      description = ''
        Cron schedule (UTC) for `--quick` on every target, e.g. several times a day: osv.dev lists
        an advisory within the hour, and this lane needs no build.
      '';
    };

    nixpkgsKeys = mkOption {
      type = types.listOf types.str;
      default = ["nixpkgs"];
      example = ["nixpkgs" "nixpkgs-small"];
      description = ''
        Flake inputs the scheduled run fails on once they are older than 30 days or off a supported
        branch. `[]` removes the job.
      '';
    };

    runner = mkOption {
      type = types.str;
      default = github.runner;
      defaultText = lib.literalExpression "config.ci.github.runner";
      description = "Runner for the full-scan jobs.";
    };

    timeoutMinutes = mkOption {
      type = types.ints.positive;
      default = 60;
      example = 120;
      description = "Timeout in minutes of one target's full scan, which builds or downloads what the target lists.";
    };

    nothingButNix = lib.mkEnableOption ''
      wimpysworld/nothing-but-nix before the full scan, for targets whose closure does not fit the
      runner's free disk
    '';

    inputToken = mkOption {
      default = null;
      description = ''
        GitHub App whose token lets Nix fetch private flake inputs during a scan. The App needs
        contents read on the repositories. Pull requests from forks get no secrets, so their scans fail.
      '';
      type = types.nullOr (types.submodule {
        options = {
          clientIdVariable = mkOption {
            type = types.str;
            description = "Repository variable with the App client ID.";
          };
          privateKeySecret = mkOption {
            type = types.str;
            description = "Repository secret with the App private key.";
          };
          repositories = mkOption {
            type = types.listOf types.str;
            example = ["platform"];
            description = "Repositories of this owner the token can read.";
          };
        };
      });
    };

    failureIssue = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open an issue when a scheduled scan fails and close it when one passes again. A failed
        scheduled run notifies nobody by itself.
      '';
    };
  };

  config = lib.mkIf (github.enable && cfg.enable) {
    ci.github.workflows =
      lib.throwIf (targets == []) "ci.github.vuln.enable needs at least one ci.vuln.targets entry for ${cfg.system}"
      lib.throwIf (hestiaCache && cfg.timeoutMinutes <= 10) "ci.github.vuln.timeoutMinutes must be above 10 with ci.github.cache = \"hestia\""
      ({vuln = full;} // lib.optionalAttrs (cfg.quick.pullRequests || cfg.quick.schedule != null) {vuln-quick = quick;});
  };
}
