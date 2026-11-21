# Tool self-tests, evaluated against the fixture consumer in ./default.nix.
{
  config,
  lib,
  ...
}: let
  inherit (config.ci) commits github;
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
      in
        assert github.cache == "hestia";
        assert uses "Mic92/hestia@";
        assert !(uses "DeterminateSystems/magic-nix-cache-action@");
        assert (flakeCheck.permissions.actions or null) == "read";
        assert (checkStep.timeout-minutes or null) == github.flakeCheck.timeoutMinutes - 10;
        assert github.workflows ? hestia-gc;
        assert (github.workflows.hestia-gc.jobs.gc.permissions.actions or null) == "write";
          pkgs.runCommandLocal "hestia-cache" {} "touch $out";

      # flakeCheck.matrix replaces flake-check with an eval job and one build job per check.
      matrix-job = let
        nixCheck = github.workflows.nix-check;
        evalJob = nixCheck.jobs.eval;
        buildJob = nixCheck.jobs.build;
        stepWith = prefix: job: lib.findFirst (step: lib.hasPrefix prefix (step.uses or "")) {} job.steps;
      in
        assert github.flakeCheck.matrix;
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

      flake-check-pr = let
        matrixPR = github.workflows.nix-check-pr;
        plainPR = plain.nix-check-pr;
        head = "\${{ github.event.pull_request.head.sha }}";
        matrixPublish = matrixPR.jobs.publish;
        publish = builtins.head matrixPublish.steps;
      in
        assert matrixPR.on.pull_request == {};
        assert matrixPR.concurrency
        == {
          group = "\${{ github.workflow }}-\${{ github.event.pull_request.number }}";
          cancel-in-progress = true;
        };
        assert (builtins.head matrixPR.jobs.eval.steps)."with".ref == head;
        assert (builtins.head plainPR.jobs.flake-check.steps)."with".ref == head;
        assert matrixPublish.needs == ["eval" "build"];
        assert plainPR.jobs.publish.needs == "flake-check";
        assert matrixPublish.permissions == {statuses = "write";};
        assert publish.env.HEAD_SHA == head;
          pkgs.runCommandLocal "flake-check-pr" {} "touch $out";

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
