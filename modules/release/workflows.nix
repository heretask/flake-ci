# Release presets: one dispatch prepares main, waits for its Nix run, tags and publishes;
# channel pushes notify the receiving repository.
{
  cfg,
  github,
  lib,
}: let
  steps = import ../github/steps.nix {inherit (github) extraNixConfig;};
  inherit (steps) nixRun;
  owner = builtins.head (lib.splitString "/" cfg.notify.repository);

  appToken = permissions: {
    name = "Create release App token (v3.3.0)";
    id = "app-token";
    uses = steps.createAppToken;
    "with" =
      {
        client-id = "\${{ vars.${cfg.appToken.clientIdVariable} }}";
        private-key = "\${{ secrets.${cfg.appToken.privateKeySecret} }}";
      }
      // permissions;
  };

  notifyToken = appToken {
    inherit owner;
    repositories = lib.removePrefix "${owner}/" cfg.notify.repository;
    permission-contents = "write";
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
      on.workflow_dispatch.inputs = {
        channel = {
          description = "Release channel";
          type = "choice";
          required = true;
          default = "rc";
          options = ["rc" "stable"];
        };
        skip_ci = {
          description = "Urgent: release without waiting for the Nix run on the commit";
          type = "boolean";
          default = false;
        };
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
        outputs.sha = "\${{ steps.result.outputs.sha }}";
        steps = [
          (appToken {permission-contents = "write";})
          (checkoutAt "Checkout main" "main")
          steps.installNix
          {
            name = "Prepare release files and push them to main";
            id = "result";
            env.GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
            run = ''
              set -euo pipefail

              remote="https://x-access-token:''${GH_TOKEN}@github.com/''${GITHUB_REPOSITORY}.git"

              # A push that loses a race with another merge is retried once on the new main.
              for attempt in 1 2; do
                ${nixRun} .#release -- prepare
                changed="$(git status --porcelain)"
                if [[ -z "$changed" ]]; then
                  break
                fi
                if grep -qvE '^.. (VERSION|CHANGELOG\.md)$' <<< "$changed"; then
                  printf 'prepare changed files other than VERSION and CHANGELOG.md:\n%s\n' "$changed" >&2
                  exit 1
                fi
                git add VERSION CHANGELOG.md
                git -c user.name='github-actions[bot]' \
                  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
                  commit --quiet -m "chore: prepare v$(tr -d '[:space:]' < VERSION)"
                if git push "$remote" HEAD:refs/heads/main; then
                  break
                fi
                if [[ "$attempt" == 2 ]]; then
                  echo 'main moved twice while preparing; run Release again' >&2
                  exit 1
                fi
                git fetch "$remote" main
                git reset --quiet --hard FETCH_HEAD
              done

              echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"
            '';
          }
        ];
      };
      # A null name omits the job.
      jobs.${
        if cfg.notify != null && cfg.notify.prebuildEventType != null
        then "prebuild"
        else null
      } = {
        name = "prebuild";
        needs = ["prepare"];
        runs-on = github.runner;
        timeout-minutes = 5;
        steps = [
          notifyToken
          {
            # The receiver builds the commit while its Nix run is still going, so the
            # deployment after the channel moves finds the result in its cache.
            name = "Ask ${cfg.notify.repository} to build the commit";
            env = {
              CHANNEL = "\${{ inputs.channel == 'stable' && '${cfg.branches.stable}' || '${cfg.branches.rc}' }}";
              SHA = "\${{ needs.prepare.outputs.sha }}";
              GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
            };
            run = ''
              gh api --method POST "/repos/${cfg.notify.repository}/dispatches" \
                -f event_type=${cfg.notify.prebuildEventType} \
                -f "client_payload[channel]=$CHANNEL" \
                -f "client_payload[sha]=$SHA"
            '';
          }
        ];
      };
      jobs.release = {
        name = "release";
        needs = ["prepare"];
        runs-on = github.runner;
        # Covers the wait for the Nix run.
        timeout-minutes = 90;
        steps = [
          (appToken {
            permission-actions = "read";
            permission-contents = "write";
          })
          (checkoutAt "Checkout exact SHA" "\${{ needs.prepare.outputs.sha }}")
          steps.installNix
          {
            name = "Wait for the Nix run on the commit";
            "if" = "inputs.skip_ci == false";
            env = {
              GH_TOKEN = "\${{ steps.app-token.outputs.token }}";
              SHA = "\${{ needs.prepare.outputs.sha }}";
            };
            run = ''
              set -euo pipefail

              missing=0
              while :; do
                state="$(gh api --method GET \
                  "/repos/''${GITHUB_REPOSITORY}/actions/workflows/nix-check.yaml/runs" \
                  -f head_sha="$SHA" \
                  -f branch=main \
                  -f per_page=1 \
                  --jq '.workflow_runs[0] | if . then "\(.status) \(.conclusion)" else "missing" end')"
                case "$state" in
                  "completed success") break ;;
                  completed*)
                    printf 'Nix workflow for %s ended as: %s\n' "$SHA" "$state" >&2
                    exit 1
                    ;;
                  missing)
                    missing=$((missing + 1))
                    if ((missing > 15)); then
                      printf 'no Nix workflow run for %s on main\n' "$SHA" >&2
                      exit 1
                    fi
                    ;;
                esac
                sleep 20
              done
            '';
          }
          {
            name = "Verify main reachability and perform";
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
          notifyToken
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
