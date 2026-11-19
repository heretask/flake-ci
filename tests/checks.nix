# Tool self-tests, evaluated against the fixture consumer in ./default.nix.
{config, ...}: let
  inherit (config.ci) commits github;
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
        flakeCheck = job "nix-check" "flake-check";
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
        assert github.workflows.nix-check.concurrency
        == {
          group = "\${{ github.workflow }}-\${{ github.ref }}";
          cancel-in-progress = false;
          queue = "max";
        };
          pkgs.runCommandLocal "flake-check-job" {} "touch $out";

      # separateChecks builds each listed check in its own job; flake-check builds the rest.
      separate-checks = let
        jobs = github.workflows.nix-check.jobs;
        lastRun = job: (lib.last job.steps).run;
        separate = jobs.check-commitlint;
      in
        assert github.flakeCheck.separateChecks == ["commitlint"];
        assert builtins.attrNames jobs == ["check-commitlint" "flake-check"];
        assert separate.name == "commitlint";
        assert separate.runs-on == github.flakeCheck.runner;
        assert separate.permissions == jobs.flake-check.permissions;
        assert lib.hasInfix ''".#checks.$system.\"commitlint\""'' (lastRun separate);
        assert lib.hasInfix "nix flake check -L --option accept-flake-config false --no-build" (lastRun jobs.flake-check);
        assert lib.hasInfix "declare -A separate=([commitlint]=1 )" (lastRun jobs.flake-check);
          pkgs.runCommandLocal "separate-checks" {} "touch $out";

      # cache = "hestia" swaps the flake-check cache step and adds what hestia needs.
      hestia-cache = let
        flakeCheck = github.workflows.nix-check.jobs.flake-check;
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
    };
  };
}
