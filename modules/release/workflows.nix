# Release presets: prepare/tag/publish on dispatch, and notify on channel pushes.
{
  cfg,
  github,
  lib,
}: let
  steps = import ../github/steps.nix {inherit (github) extraNixConfig;};
  inherit (steps) nixRun;
  owner = builtins.head (lib.splitString "/" cfg.notify.repository);
  appToken = permissions: {
    name = "Create release App token (v3.2.0)";
    id = "app-token";
    uses = steps.createAppToken;
    "with" =
      {
        client-id = "\${{ vars.${cfg.appToken.clientIdVariable} }}";
        private-key = "\${{ secrets.${cfg.appToken.privateKeySecret} }}";
      }
      // permissions;
  };

  checkoutAt = name: ref:
    steps.checkout
    // {
      name = "${name} (v7.0.1)";
      "with" = {
        fetch-depth = 0;
        persist-credentials = false;
        inherit ref;
      };
    };
in
  {
    release = {
      name = "Release";
      on.workflow_dispatch.inputs.channel = {
        description = "Release channel";
        type = "choice";
        required = true;
        default = "rc";
        options = ["rc" "stable"];
      };
      permissions.contents = "read";
      concurrency = {
        group = "release-request";
        cancel-in-progress = false;
      };
      jobs.prepare = {
        name = "prepare";
        runs-on = github.runner;
        timeout-minutes = 15;
        outputs = {
          ready = "\${{ steps.result.outputs.ready }}";
          sha = "\${{ steps.result.outputs.sha }}";
        };
        steps = [
          (appToken {
            permission-contents = "write";
            permission-pull-requests = "write";
          })
          (checkoutAt "Checkout main" "main")
          steps.installNix
          {
            name = "Prepare release files";
            "if" = "inputs.channel == 'rc'";
            run = "${nixRun} .#release -- prepare";
          }
          {
            name = "Check preparation result";
            id = "result";
            env.CHANNEL = "\${{ inputs.channel }}";
            run = ''
              set -euo pipefail

              sha="$(git rev-parse HEAD)"
              echo "sha=$sha" >> "$GITHUB_OUTPUT"

              # Stable promotes main HEAD as it is; `release stable` refuses unless it is an RC.
              if [[ "$CHANNEL" == stable ]]; then
                echo "ready=true" >> "$GITHUB_OUTPUT"
                exit 0
              fi

              if git diff --quiet -- VERSION CHANGELOG.md; then
                echo "ready=true" >> "$GITHUB_OUTPUT"
              else
                echo "ready=false" >> "$GITHUB_OUTPUT"
                echo "title=chore(release): prepare v$(tr -d '[:space:]' < VERSION)" >> "$GITHUB_OUTPUT"
              fi
            '';
          }
          {
            name = "Create or update preparation PR";
            "if" = "steps.result.outputs.ready == 'false'";
            uses = steps.createPullRequest;
            "with" = {
              token = "\${{ steps.app-token.outputs.token }}";
              branch = "automation/prepare-release";
              base = "main";
              add-paths = ''
                VERSION
                CHANGELOG.md
              '';
              commit-message = "\${{ steps.result.outputs.title }}";
              title = "\${{ steps.result.outputs.title }}";
              body = "Merge this PR, wait for Nix to pass, then rerun Release with the desired channel.";
            };
          }
        ];
      };
      jobs.release = {
        name = "release";
        needs = ["prepare"];
        "if" = "needs.prepare.outputs.ready == 'true'";
        runs-on = github.runner;
        timeout-minutes = 20;
        steps = [
          (appToken {
            permission-actions = "read";
            permission-contents = "write";
          })
          (checkoutAt "Checkout exact SHA" "\${{ needs.prepare.outputs.sha }}")
          steps.installNix
          {
            name = "Verify Nix success, main reachability, and perform";
            id = "perform";
            env = {
              CHANNEL = "\${{ inputs.channel }}";
              GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
              SHA = "\${{ needs.prepare.outputs.sha }}";
            };
            run = ''
              set -euo pipefail

              case "$CHANNEL" in
                rc) branch=${cfg.branches.rc} ;;
                stable) branch=${cfg.branches.stable} ;;
                *)
                  printf 'unsupported channel: %s\n' "$CHANNEL" >&2
                  exit 1
                  ;;
              esac

              remote="https://x-access-token:''${GH_TOKEN}@github.com/''${GITHUB_REPOSITORY}.git"
              git remote set-url origin "$remote"
              git fetch origin main
              if ! git merge-base --is-ancestor "$SHA" origin/main; then
                printf '%s is not reachable from origin/main\n' "$SHA" >&2
                exit 1
              fi

              run="$(gh api --method GET \
                "/repos/''${GITHUB_REPOSITORY}/actions/workflows/nix-check.yaml/runs" \
                -f head_sha="$SHA" \
                -f branch=main \
                -f status=success \
                -f per_page=1 \
                --jq '.workflow_runs[0].id // empty')"
              if [[ -z "$run" ]]; then
                printf 'no successful Nix workflow for %s on main\n' "$SHA" >&2
                exit 1
              fi

              tag="$(${nixRun} .#release -- "$CHANNEL")"
              git push --atomic "$remote" "refs/tags/$tag:refs/tags/$tag" "$SHA:refs/heads/$branch"
              echo "tag=$tag" >> "$GITHUB_OUTPUT"
            '';
          }
          {
            name = "Publish GitHub Release";
            env = {
              CHANNEL = "\${{ inputs.channel }}";
              GH_REPO = "\${{ github.repository }}";
              GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
              TAG = "\${{ steps.perform.outputs.tag }}";
            };
            run = ''
              set -euo pipefail

              notes="$RUNNER_TEMP/release-notes.md"
              ${nixRun} .#release -- notes "$TAG" > "$notes"
              args=(--verify-tag --title "$TAG" --notes-file "$notes")
              if [[ "$CHANNEL" == rc ]]; then
                args+=(--prerelease --latest=false)
              fi
              gh release create "$TAG" "''${args[@]}" ||
                gh release view "$TAG" --json isDraft --jq .isDraft | grep -qx false
            '';
          }
        ];
      };
    };
  }
  // lib.optionalAttrs (cfg.notify != null) {
    release-notify = {
      name = "Notify ${cfg.notify.repository}";
      on.push.branches = [cfg.branches.stable cfg.branches.rc];
      permissions = {};
      jobs.notify = {
        name = "notify";
        "if" = "github.event.deleted == false";
        runs-on = github.runner;
        timeout-minutes = 5;
        steps = [
          (appToken {
            inherit owner;
            repositories = lib.removePrefix "${owner}/" cfg.notify.repository;
            permission-contents = "write";
          })
          {
            name = "Notify ${cfg.notify.repository} of channel update";
            env = {
              CHANNEL = "\${{ github.ref_name }}";
              SHA = "\${{ github.event.after }}";
              GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
            };
            run = ''
              gh api --method POST "/repos/${cfg.notify.repository}/dispatches" \
                -f event_type=${cfg.notify.eventType} \
                -f "client_payload[channel]=$CHANNEL" \
                -f "client_payload[sha]=$SHA"
            '';
          }
        ];
      };
    };
  }
