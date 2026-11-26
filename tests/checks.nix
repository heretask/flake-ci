# Tool self-tests, evaluated against the fixture consumer in ./default.nix.
{
  config,
  lib,
  ...
}: let
  inherit (config.ci) commits github release;
  # The non-matrix workflows, for the checks that cover the flake-check job.
  plain = import ../modules/github/workflows.nix {
    cfg = github // {flakeCheck = github.flakeCheck // {matrix = false;};};
    inherit commits lib;
  };
in {
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    commitlint = lib.getExe config.packages.commitlint;
    description = char: length: lib.concatStrings (lib.genList (_: char) length);
    atLimit = "fix(api): ${description "x" commits.maxLength}";
    overLimit = "fix(api): ${description "x" (commits.maxLength + 1)}";
    valid = ["feat(app): validate commit messages" "revert: description" "chore(ci): pin actions" "docs(api)!: drop old guide" atLimit];
    invalid = {
      "not conventional" = ''missing ": " after the type'';
      "fix(api: unclosed" = ''is not "type", "type(scope)"'';
      "feature(api): x" = ''unknown type "feature"'';
      "fix(): x" = ''empty scope'';
      "fix(other): x" = ''unknown scope "other". Allowed scopes: api app ci'';
      "feat(ci): x" = ''use a type without a changelog entry, e.g. "chore(ci): x"'';
      "fix(api):  " = ''description after ": " is empty'';
      ${overLimit} = ''description is ${toString (commits.maxLength + 1)} characters, the limit is ${toString commits.maxLength}. Shorten it by 1'';
    };
  in {
    checks = {
      commitlint = pkgs.runCommandLocal "commitlint-check" {} ''
        ${lib.concatMapStringsSep "\n" (title: ''
            printf '%s\n' ${lib.escapeShellArg title} | ${commitlint}
          '')
          valid}

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (title: message: ''
            if printf '%s\n' ${lib.escapeShellArg title} | ${commitlint} 2> error; then
              echo ${lib.escapeShellArg "commitlint accepted an invalid fixture: ${title}"} >&2
              exit 1
            fi
            if ! grep -qF -- ${lib.escapeShellArg message} error; then
              echo ${lib.escapeShellArg "commitlint did not explain: ${title}; expected: ${message}"} >&2
              cat error >&2
              exit 1
            fi
          '')
          invalid)}

        # The limit counts characters, not bytes.
        printf '%s\n' ${lib.escapeShellArg "fix: ${description "æ" commits.maxLength}"} | ${commitlint}

        # A squash-merged subject: the " (#<PR number>)" suffix does not count,
        # and a description over the limit is reported without failing.
        printf '%s\n\nBody.\n' ${lib.escapeShellArg "${atLimit} (#1234)"} | ${commitlint} --squash-merged
        if printf '%s\n' ${lib.escapeShellArg "${atLimit} (#1234)"} | ${commitlint}; then
          echo "commitlint accepted a subject over the limit" >&2
          exit 1
        fi
        printf '%s\n' ${lib.escapeShellArg "${overLimit} (#1234)"} | ${commitlint} --squash-merged 2> warning
        grep -qF 'description is ${toString (commits.maxLength + 1)} characters' warning
        grep -q '^warning: ' warning
        if printf '%s\n' "not conventional (#1234)" | ${commitlint} --squash-merged; then
          echo "commitlint --squash-merged accepted an invalid subject" >&2
          exit 1
        fi

        touch "$out"
      '';

      release-lifecycle =
        pkgs.runCommand "release-lifecycle" {
          src = lib.fileset.toSource {
            root = ../modules/release;
            fileset = lib.fileset.unions [../modules/release/release.py ../modules/release/test_release.py];
          };
          cogToml = config.files.file."cog.toml".source;
          nativeBuildInputs = [pkgs.git pkgs.python3 pkgs.cocogitto];
        } ''
          export HOME="$TMPDIR"
          git config --global user.email test@example.com
          git config --global user.name Test
          cp -r "$src" ./release
          cp "$cogToml" ./cog.toml
          chmod -R u+w ./release
          cd ./release
          python3 -m unittest test_release.py
          touch "$out"
        '';

      release-version = let
        stepNames = steps: map (step: step.name or null) steps;
        evalSteps = stepNames github.workflows.nix-check.jobs.eval.steps;
        prEvalSteps = stepNames github.workflows.nix-check-pr.jobs.eval.steps;
        plainSteps = stepNames plain.nix-check.jobs.flake-check.steps;
      in
        assert release.version == "1.2.3";
        assert release.formatBuildVersion {
          lastModifiedDate = "20261122065721";
          shortRev = "abc1234";
        }
        == "1.2.3+202611220657.abc1234";
        assert release.formatBuildVersion {
          lastModifiedDate = "20261122065721";
          shortRev = null;
        }
        == "1.2.3+202611220657";
        assert release.formatBuildVersion {
          lastModifiedDate = null;
          shortRev = "abc1234";
        }
        == "1.2.3+abc1234";
        assert release.formatBuildVersion {
          lastModifiedDate = null;
          shortRev = null;
        }
        == "1.2.3";
        assert lib.hasPrefix "1.2.3" release.buildVersion;
        assert builtins.elem "Check VERSION invariance" evalSteps;
        assert builtins.elem "Check VERSION invariance" prEvalSteps;
        assert !(builtins.elem "Check VERSION invariance" plainSteps);
          pkgs.runCommandLocal "release-version-check" {} "touch $out";

      workflow-behavior = pkgs.runCommand "workflow-behavior-check" {nativeBuildInputs = [pkgs.bash pkgs.python3];} ''
        python3 ${../modules/release/test_workflows.py} ${pkgs.writeText "workflows.json" (builtins.toJSON (
          lib.mapAttrs' (stem: lib.nameValuePair ".github/workflows/${stem}.yaml") github.workflows
        ))}
        touch "$out"
      '';

      # flakeCheck.* settings change only the flake-check job; other Linux jobs keep runner.
      flake-check-job = let
        job = stem: name: github.workflows.${stem}.jobs.${name};
        flakeCheck = plain.nix-check.jobs.flake-check;
        stepNames = map (step: step.name or null) flakeCheck.steps;
      in
        assert flakeCheck.runs-on == github.flakeCheck.runner;
        assert flakeCheck.timeout-minutes == github.flakeCheck.timeoutMinutes;
        assert (job "pr-title" "lint").runs-on == github.runner;
        assert github.flakeCheck.runner != github.runner;
        assert github.flakeCheck.timeoutMinutes != 30;
        assert github.flakeCheck.reclaimDisk == "background";
        assert builtins.elem "Reclaim hosted runner disk in the background" stepNames;
        assert !(builtins.elem "Reclaim hosted runner disk" stepNames);
        assert github.flakeCheck.queue;
        assert plain.nix-check.concurrency
        == {
          group = "\${{ github.workflow }}-\${{ github.ref }}";
          cancel-in-progress = false;
          queue = "max";
        };
          pkgs.runCommandLocal "flake-check-job" {} "touch $out";

      # flakeCheck.enable = false drops both Nix check workflows.
      flake-check-disabled = let
        disabled = import ../modules/github/workflows.nix {
          cfg = github // {flakeCheck = github.flakeCheck // {enable = false;};};
          inherit commits lib;
        };
      in
        assert github.workflows ? nix-check;
        assert !(disabled ? nix-check);
        assert builtins.attrNames disabled == builtins.filter (name: !builtins.elem name ["nix-check" "nix-check-pr"]) (builtins.attrNames plain);
          pkgs.runCommandLocal "flake-check-disabled" {} "touch $out";

      # cache = "hestia" swaps the flake-check cache step and adds what hestia needs.
      hestia-cache = let
        flakeCheck = plain.nix-check.jobs.flake-check;
        uses = prefix: builtins.any (step: lib.hasPrefix prefix (step.uses or "")) flakeCheck.steps;
        checkStep = lib.findFirst (step: (step.name or null) == "Check flake") {} flakeCheck.steps;
        gcSteps = cfg: (import ../modules/github/workflows.nix {inherit cfg commits lib;}).hestia-gc.jobs.gc.steps;
        gcRun = cfg: (lib.findFirst (step: (step.name or null) == "Run garbage collection") {} (gcSteps cfg)).run;
        gcJob = github.workflows.hestia-gc.jobs.gc;
        gcStepNames = map (step: step.name) gcJob.steps;
        # gh api [--paginate] <endpoint> --jq <filter> prints CACHES_JSON, or AFTER_JSON for the
        # default branch's own listing; gh api --method DELETE .../caches/<id> records the ID.
        stubCacheGh = pkgs.writeShellScriptBin "gh" ''
          jq_expr=""
          endpoint=""
          method=GET
          while (( $# )); do
            case "$1" in
              --jq)
                jq_expr="$2"
                shift 2
                ;;
              --method)
                method="$2"
                shift 2
                ;;
              api|--paginate)
                shift
                ;;
              *)
                endpoint="$1"
                shift
                ;;
            esac
          done
          case "$method $endpoint" in
            "DELETE repos/example/app/actions/caches/"*)
              echo "''${endpoint##*/}" >>"$TMPDIR/deleted"
              ;;
            "GET repos/example/app/actions/caches?per_page=100&key=m3%23&ref=refs/heads/main")
              printf '%s\n' "$AFTER_JSON" | ${lib.getExe pkgs.jq} -r "$jq_expr"
              ;;
            "GET repos/example/app/actions/caches?per_page=100&key=m3%23")
              printf '%s\n' "$CACHES_JSON" | ${lib.getExe pkgs.jq} -r "$jq_expr"
              ;;
            *)
              echo "unexpected gh call: $method $endpoint" >&2
              exit 99
              ;;
          esac
        '';
        pruneManifests = ../modules/github/hestia-gc-manifests.sh;
        checkManifests = ../modules/github/hestia-gc-check.sh;
      in
        assert github.cache == "hestia";
        assert uses "Mic92/hestia@";
        assert !(uses "DeterminateSystems/magic-nix-cache-action@");
        assert (flakeCheck.permissions.actions or null) == "read";
        assert (checkStep.timeout-minutes or null) == github.flakeCheck.timeoutMinutes - 10;
        assert github.workflows ? hestia-gc;
        assert (github.workflows.hestia-gc.jobs.gc.permissions.actions or null) == "write";
        assert lib.hasInfix " gc --push-ttl 3 " (gcRun github);
        assert !(lib.hasInfix "--push-ttl" (gcRun (github // {hestiaGc.pushTtlDays = null;})));
        # Manifest versions are pruned before the hestia daemon starts, and the result is checked after gc.
        assert builtins.head gcStepNames == "Prune manifest versions";
        assert lib.last gcStepNames == "Check the default branch kept its manifest";
        assert (builtins.head gcJob.steps).env.DEFAULT_REF == "refs/heads/\${{ github.event.repository.default_branch }}";
        assert (lib.last gcJob.steps)."if" == "steps.manifests.outputs.head == 'true' && inputs.dry-run != true";
        assert gcJob.timeout-minutes == 45;
          pkgs.runCommandLocal "hestia-cache" {nativeBuildInputs = [stubCacheGh];} ''
            export GITHUB_REPOSITORY=example/app DEFAULT_REF=refs/heads/main GITHUB_OUTPUT="$TMPDIR/output"
            recent=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S.123456Z)
            entry() {
              printf '{"id":%s,"ref":"%s","version":"%s","key":"%s","created_at":"%s"}' "$@"
            }
            # On main: the newest version, a superseded one, and a stale one with a higher index.
            # A second cache version namespace on main. A pull request's own versions, one of them
            # keyed like main's newest. A key that is not a manifest version.
            export CACHES_JSON="{\"actions_caches\":[$(
              entry 10 refs/heads/main A 'm3#7' "$recent"
            ),$(
              entry 11 refs/heads/main A 'm3#6' 2026-01-02T00:00:00.5Z
            ),$(
              entry 12 refs/heads/main A 'm3#900' 2026-01-01T00:00:00.5Z
            ),$(
              entry 20 refs/heads/main B 'm3#2' 2026-01-02T00:00:00.5Z
            ),$(
              entry 21 refs/heads/main B 'm3#1' 2026-01-01T00:00:00.5Z
            ),$(
              entry 30 refs/pull/1/merge A 'm3#7' 2026-01-03T00:00:00.5Z
            ),$(
              entry 31 refs/pull/1/merge A 'm3#8' "$recent"
            ),$(
              entry 40 refs/heads/main A 'm3#draft' 2026-01-01T00:00:00.5Z
            )]}"

            # 1. A dry run deletes nothing.
            DRY_RUN=true bash ${pruneManifests} > output
            test ! -e "$TMPDIR/deleted"
            grep -qx 'Dry run: 4 manifest version(s) would be deleted.' output

            # 2. Deleted: main's superseded versions in both namespaces and the pull request's old one.
            # Kept: each namespace's newest on main, and the pull request's version a job may still read.
            DRY_RUN= bash ${pruneManifests} > output
            test "$(sort -n "$TMPDIR/deleted" | paste -sd ' ')" = '11 12 21 30'
            grep -qx 'keep    m3#7 on refs/heads/main' output
            grep -qx 'keep    m3#2 on refs/heads/main' output
            grep -qx 'recent  m3#8 on refs/pull/1/merge' output
            grep -qx 'head=true' "$GITHUB_OUTPUT"

            # 3. A cache without manifest versions has no head to lose.
            : >"$GITHUB_OUTPUT"
            CACHES_JSON='{"actions_caches":[]}' bash ${pruneManifests}
            test ! -s "$GITHUB_OUTPUT"

            # 4. After gc, a default branch without a manifest version fails the job.
            AFTER_JSON="{\"actions_caches\":[$(entry 50 refs/heads/main A 'm3#8' "$recent")]}" bash ${checkManifests}
            if AFTER_JSON='{"actions_caches":[]}' bash ${checkManifests} > output; then
              echo "a default branch without a manifest version passed" >&2
              exit 1
            fi
            grep -qF '::error title=hestia cache reset::' output

            touch "$out"
          '';

      # ci.github.vuln scans every declared target: all in the matrix, all in the lockfile loop.
      vuln-workflow = let
        full = github.workflows.vuln;
        quick = github.workflows.vuln-quick;
        inherit (full.jobs) scan;
        stepNamed = prefix: job: lib.findFirst (step: lib.hasPrefix prefix (step.name or "")) {} job.steps;
        scanStep = stepNamed "Scan target" scan;
        quickStep = stepNamed "Scan lockfiles" quick.jobs.lockfiles;
        names = job: map (step: step.name or null) job.steps;
        index = prefix: job: lib.lists.findFirstIndex (lib.hasPrefix prefix) null (names job);
      in
        assert scan.strategy.matrix.target == ["api" "host"];
        assert !scan.strategy.fail-fast;
        assert full.on.schedule == [{cron = "7 6 * * *";}];
        assert full.on.push
        == {
          branches = ["main"];
          paths = ["flake.lock" "modules/**"];
        };
        assert full.on.pull_request.paths == ["flake.lock" "modules/**"];
        assert full.permissions == {};
        assert scan.timeout-minutes == 90;
        # hestia's post step uploads after the scan; the App token must exist before Nix fetches inputs.
        assert scanStep.timeout-minutes == 80;
        assert scan.permissions.actions == "read";
        # The database must not land on the root disk that nothing-but-nix leaves nearly full.
        assert lib.hasInfix "export GRYPE_DB_CACHE_DIR=\"\${TMPDIR:-$RUNNER_TEMP}/grype-db\"\n" scanStep.run;
        assert index "Create input App token" scan < index "Install Determinate Nix" scan;
        assert index "Make room for Nix" scan < index "Install Determinate Nix" scan;
        assert (stepNamed "Create input App token" scan)."with".repositories == "platform,other";
        assert lib.hasPrefix "access-tokens = github.com=\${{ steps.app-token.outputs.token }}\n" scanStep.env.NIX_CONFIG;
        assert lib.hasInfix "accept-flake-config = false" scanStep.env.NIX_CONFIG;
        assert (lib.last full.jobs.staleness.steps)."with".nixpkgs-keys == "nixpkgs,nixpkgs-small";
        # Findings are reported by the failed run, its summary and its artifact; nothing else is written to the forge.
        assert builtins.attrNames full.jobs == ["scan" "staleness"];
        assert lib.hasInfix "scan \"$RUNNER_TEMP/vuln\" \"$TARGET\"\nexit \"$status\"\n" scanStep.run;
        assert lib.hasInfix ">>\"$GITHUB_STEP_SUMMARY\"" scanStep.run;
        assert (lib.last scan.steps)."if" == "\${{ !cancelled() }}";
        assert (lib.last scan.steps)."with".path == "\${{ runner.temp }}/vuln/findings.json";
        assert lib.hasInfix "scan \"$RUNNER_TEMP/vuln/$target\" \"$target\" --quick\n" quickStep.run;
        assert (lib.last quick.jobs.lockfiles.steps)."with".name == "vuln-quick";
        assert builtins.attrNames quick.jobs == ["lockfiles"];
        assert quick.on.pull_request == {};
        assert quick.on.schedule == [{cron = "11 */4 * * *";}];
        assert lib.hasInfix "for target in api host; do" quickStep.run;
        assert quickStep.env == {inherit (scanStep.env) NIX_CONFIG;};
          pkgs.runCommandLocal "vuln-workflow" {} "touch $out";

      # flakeCheck.matrix replaces flake-check with an eval job and one build job per check.
      matrix-job = let
        nixCheck = github.workflows.nix-check;
        evalJob = nixCheck.jobs.eval;
        buildJob = nixCheck.jobs.build;
        stepWith = prefix: job: lib.findFirst (step: lib.hasPrefix prefix (step.uses or "")) {} job.steps;
        prebuild = lib.last evalJob.steps;
        withoutPrebuild = import ../modules/github/workflows.nix {
          cfg = github // {flakeCheck = github.flakeCheck // {prebuildShared = false;};};
          inherit commits lib;
        };
      in
        assert github.flakeCheck.matrix;
        # prebuildShared builds after the matrix step, from its output, and is bounded like the other Nix steps.
        assert github.flakeCheck.prebuildShared;
        assert prebuild.name == "Build dependencies shared by build jobs";
        assert prebuild.env.MATRIX == "\${{ steps.matrix.outputs.matrix }}";
        assert prebuild."if" == "steps.matrix.outputs.any-jobs == 'true'";
        assert prebuild.timeout-minutes == github.flakeCheck.timeoutMinutes - 10;
        assert (lib.last github.workflows.nix-check-pr.jobs.eval.steps).name == prebuild.name;
        assert (lib.last withoutPrebuild.nix-check.jobs.eval.steps).id == "matrix";
        assert !(nixCheck.jobs ? flake-check);
        assert (stepWith "Mic92/hestia/matrix@" evalJob) != {};
        # The evaluator is pinned by the consumer's lock, not by the runner's registry.
        assert lib.hasInfix " --inputs-from . nixpkgs#nix-eval-jobs " (stepWith "Mic92/hestia/matrix@" evalJob)."with".nix-eval-jobs;
        assert evalJob.outputs ? manifest-version;
        assert buildJob.needs == "eval";
        assert buildJob.strategy.matrix == "\${{ fromJSON(needs.eval.outputs.matrix) }}";
        assert buildJob.runs-on == "\${{ matrix.os }}";
        assert (stepWith "Mic92/hestia@" buildJob)."with".wait-manifest-version == "\${{ needs.eval.outputs.manifest-version }}";
        assert buildJob.permissions.actions == "read";
          pkgs.runCommandLocal "matrix-job" {} "touch $out";

      # prebuild-shared.sh builds exactly the uncached derivations that two or more jobs need.
      prebuild-shared = let
        # nix-store --query --requisites <drv>...: the fixture closure of each job's derivations.
        stubNixStore = pkgs.writeShellScriptBin "nix-store" ''
          for drv in "''${@:3}"; do
            echo "$drv"
            case "$drv" in
              */a.drv) printf '/nix/store/%s\n' shared.drv cached.drv only-a.drv same-job.drv source.tar.gz ;;
              */a2.drv) printf '/nix/store/%s\n' shared.drv same-job.drv ;;
              */b.drv) printf '/nix/store/%s\n' shared.drv cached.drv ;;
              */c.drv) printf '/nix/store/%s\n' only-c.drv ;;
            esac
          done
        '';
        # nix build --dry-run --stdin: everything but cached.drv is missing from the caches.
        stubNix = pkgs.writeShellScriptBin "nix" ''
          cat >/dev/null
          {
            echo "these 8 derivations will be built:"
            printf '  /nix/store/%s\n' a.drv a2.drv b.drv c.drv shared.drv only-a.drv only-c.drv same-job.drv
            echo "these 2 paths will be fetched (1.0 MiB download, 2.0 MiB unpacked):"
            printf '  /nix/store/%s\n' cached source.tar.gz
          } >&2
        '';
        # Stands in for NIX_BUILD: records its arguments and the installables on stdin.
        recordBuild = pkgs.writeShellScriptBin "record-build" ''
          printf '%s\n' "$*" >"$TMPDIR/build-args"
          cat >"$TMPDIR/built"
          exit "''${BUILD_EXIT:-0}"
        '';
        matrix = jobs: builtins.toJSON {include = map (installables: {inherit installables;}) jobs;};
        script = ../modules/github/prebuild-shared.sh;
      in
        pkgs.runCommandLocal "prebuild-shared" {
          nativeBuildInputs = [pkgs.jq stubNix stubNixStore recordBuild];
          threeJobs = matrix ["/nix/store/a.drv^* /nix/store/a2.drv^*" "/nix/store/b.drv^*" "/nix/store/c.drv^*"];
          oneJob = matrix ["/nix/store/a.drv^* /nix/store/a2.drv^*"];
        } ''
          export NIX_BUILD=record-build

          # 1. Only shared.drv: cached.drv is shared but cached, same-job.drv is needed twice by one job.
          MATRIX="$threeJobs" bash -e ${script}
          test "$(cat "$TMPDIR/built")" = '/nix/store/shared.drv^*'
          test "$(cat "$TMPDIR/build-args")" = '--no-link --keep-going --stdin'

          # 2. One job shares with nobody: nothing is built.
          rm "$TMPDIR/built"
          MATRIX="$oneJob" bash -e ${script}
          test ! -e "$TMPDIR/built"

          # 3. A failed build is a warning, not a failed step.
          output="$(MATRIX="$threeJobs" BUILD_EXIT=1 bash -e ${script})"
          grep -qF '::warning title=Shared dependencies::' <<<"$output"

          touch "$out"
        '';

      flake-check-pr = let
        matrixPR = github.workflows.nix-check-pr;
        plainPR = plain.nix-check-pr;
        unfiltered = matrix:
          (import ../modules/github/workflows.nix {
            cfg =
              github
              // {
                flakeCheck =
                  github.flakeCheck
                  // {
                    inherit matrix;
                    pullRequests = github.flakeCheck.pullRequests // {skipChecks = [];};
                  };
              };
            inherit commits lib;
          }).nix-check-pr;
        unfilteredMatrixPR = unfiltered true;
        unfilteredPlainPR = unfiltered false;
        head = "\${{ github.event.pull_request.head.sha }}";
        sameRepo = "github.event.pull_request.head.repo.full_name == github.repository";
        matrixPublish = matrixPR.jobs.publish;
        publish = builtins.head matrixPublish.steps;
        matrixStep = job: lib.findFirst (step: (step.id or null) == "matrix") {} job.steps;
      in
        assert matrixPR.on.pull_request == {};
        assert matrixPR.concurrency
        == {
          group = "\${{ github.workflow }}-\${{ github.event.pull_request.number }}";
          cancel-in-progress = true;
        };
        assert matrixPR.jobs.eval."if" == sameRepo;
        assert plainPR.jobs.flake-check."if" == sameRepo;
        assert (builtins.head matrixPR.jobs.eval.steps)."with".ref == head;
        assert (builtins.head plainPR.jobs.flake-check.steps)."with".ref == head;
        assert (matrixStep github.workflows.nix-check.jobs.eval)."with".flake == ".#checks.x86_64-linux";
        assert (matrixStep matrixPR.jobs.eval)."with".flake == ".#prChecks.x86_64-linux";
        assert (matrixStep unfilteredMatrixPR.jobs.eval)."with".flake == ".#checks.x86_64-linux";
        assert lib.hasInfix ''--raw ".#prChecks.$system"'' (lib.last plainPR.jobs.flake-check.steps).run;
        assert (lib.last unfilteredPlainPR.jobs.flake-check.steps).name == "Check flake";
        assert matrixPublish.needs == ["eval" "build"];
        assert lib.hasInfix "needs.eval.result == 'success'" matrixPublish."if";
        assert lib.hasInfix "needs.build.result == 'skipped' && needs.eval.outputs.any-jobs == 'false'" matrixPublish."if";
        assert plainPR.jobs.publish.needs == "flake-check";
        assert matrixPublish.permissions == {statuses = "write";};
        assert publish.env.HEAD_SHA == head;
          pkgs.runCommandLocal "flake-check-pr" {} "touch $out";

      # signoff with pullRequests enabled reuses passing status, defers while CI runs, and allows --local.
      signoff-pr = let
        stubGh = pkgs.writeShellScriptBin "gh" ''
          jq_expr=""
          endpoint=""
          while (( $# )); do
            case "$1" in
              --jq)
                jq_expr="$2"
                shift 2
                ;;
              --method|-f|-F)
                shift 2
                ;;
              api)
                shift
                ;;
              *)
                if [[ -z "$endpoint" ]]; then
                  endpoint="$1"
                fi
                shift
                ;;
            esac
          done
          case "$endpoint" in
            */status)
              if [[ -n "''${STATUS_EXIT:-}" && "$STATUS_EXIT" != 0 ]]; then
                echo "gh: Not Found (HTTP 404)" >&2
                exit "$STATUS_EXIT"
              fi
              body="$STATUS_JSON"
              ;;
            */runs)
              if [[ -n "''${RUNS_EXIT:-}" && "$RUNS_EXIT" != 0 ]]; then
                echo "gh: Not Found (HTTP 404)" >&2
                exit "$RUNS_EXIT"
              fi
              body="$RUNS_JSON"
              ;;
            *)
              echo "unexpected gh api endpoint: $endpoint" >&2
              exit 99
              ;;
          esac
          printf '%s\n' "$body" | ${lib.getExe pkgs.jq} -r "$jq_expr"
        '';
        stubNix = pkgs.writeShellScriptBin "nix" ''
          echo "NIX_CALLED" >&2
          exit 42
        '';
        signoffWithStub = import ../modules/signoff/package.nix {
          pkgs = pkgs // {gh = stubGh;};
          reusePullRequestChecks = true;
        };
      in
        pkgs.runCommandLocal "signoff-pr" {
          # Also build the real packaged signoff so shellcheck covers its reusePullRequestChecks branch.
          realSignoff = config.packages.signoff;
          nativeBuildInputs = [pkgs.git stubNix];
        } ''
          export HOME="$TMPDIR"
          git init -q -b main repo
          git -C repo config user.email test@example.com
          git -C repo config user.name Test
          touch repo/file
          git -C repo add file
          git -C repo commit -q -m "init"
          git init -q --bare remote.git
          git -C repo remote add origin "$PWD/remote.git"
          git -C repo push -q -u origin main
          cd repo

          # 1. Existing signoff success exits 0 without invoking nix.
          output="$(STATUS_JSON='{"statuses":[{"context":"signoff","state":"success"}]}' RUNS_JSON='{"workflow_runs":[]}' ${lib.getExe signoffWithStub} 2>&1)"
          grep -qF "Already signed off:" <<< "$output"

          # 2. Active run behind a newer completed run still exits 75 and prints its URL.
          set +e
          output="$(STATUS_JSON='{"statuses":[]}' RUNS_JSON='{"workflow_runs":[{"status":"completed","html_url":"https://example.test/old"},{"status":"in_progress","html_url":"https://example.test/active"}]}' ${lib.getExe signoffWithStub} 2>&1)"
          code=$?
          set -e
          test "$code" -eq 75
          grep -qF "https://example.test/active" <<< "$output"

          # 3. --local bypasses the pending CI check and reaches nix.
          set +e
          output="$(STATUS_JSON='{"statuses":[]}' RUNS_JSON='{"workflow_runs":[{"status":"in_progress","html_url":"https://example.test/active"}]}' ${lib.getExe signoffWithStub} --local 2>&1)"
          code=$?
          set -e
          test "$code" -eq 1
          grep -qF "NIX_CALLED" <<< "$output"

          # 4. Empty workflow_runs falls through to nix.
          set +e
          output="$(STATUS_JSON='{"statuses":[]}' RUNS_JSON='{"workflow_runs":[]}' ${lib.getExe signoffWithStub} 2>&1)"
          code=$?
          set -e
          test "$code" -eq 1
          grep -qF "NIX_CALLED" <<< "$output"

          # 5. Missing workflow (HTTP 404 before rollout) falls through silently without gh error noise.
          set +e
          output="$(STATUS_JSON='{"statuses":[]}' RUNS_EXIT=1 ${lib.getExe signoffWithStub} 2>&1)"
          code=$?
          set -e
          test "$code" -eq 1
          grep -qF "NIX_CALLED" <<< "$output"
          ! grep -qF "HTTP 404" <<< "$output"

          touch "$out"
        '';

      # An App token opens the update PR, so its checks run without anyone approving them.
      input-update-token = let
        job = stem: github.workflows.${stem}.jobs.update;
        update = stem: lib.last (job stem).steps;
      in
        assert (builtins.head (job "update-app-input").steps).id == "app-token";
        assert (update "update-app-input")."with".token == "\${{ steps.app-token.outputs.token }}";
        assert !(lib.hasInfix "Approve workflow runs" (update "update-app-input")."with".pr-body);
        assert github.workflows.update-app-input.permissions == {contents = "read";};
        assert !((update "update-plain-input")."with" ? token);
        assert lib.hasInfix "Approve workflow runs" (update "update-plain-input")."with".pr-body;
          pkgs.runCommandLocal "input-update-token" {} "touch $out";

      # Cheap checks share the "light" runner group, so hestia runs them on one job.
      flake-ci-groups = assert config.checks.workflow-orphans.meta.hestia.group == "light";
      assert config.checks.actionlint.meta.hestia.group == "light";
      assert lib.all (name: config.checks."files:${name}".meta.hestia.group == "light") (builtins.attrNames config.files.file);
        pkgs.runCommandLocal "flake-ci-groups" {} "touch $out";
    };
  };
}
