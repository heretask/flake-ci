{pkgs}: let
  ghSignoff = pkgs.fetchFromGitHub {
    owner = "basecamp";
    repo = "gh-signoff";
    rev = "a8d5ce1cab7f88848f9962e047d26c5cd75f7b92";
    hash = "sha256-gfEPoW1FpWuLSkVwGnF7GNWUeQ1mDyJIsTxQafWJgNk=";
  };
in
  pkgs.writeShellApplication {
    name = "signoff";
    runtimeInputs = [
      pkgs.gh
      pkgs.git
      pkgs.jujutsu
    ];
    text = ''
      if (( $# != 0 )); then
        echo "Usage: signoff" >&2
        exit 1
      fi

      if workspace_root="$(jj workspace root 2>/dev/null)" && git_dir="$(jj git root 2>/dev/null)"; then
        mode=jj
        export GIT_DIR="$git_dir"
      else
        mode=git
        unset GIT_DIR
        if ! workspace_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
          echo "signoff must run from a Jujutsu workspace or Git repository" >&2
          exit 1
        fi
      fi
      cd "$workspace_root"

      snapshot() {
        local status tested_commit tested_tree workspace_commit workspace_tree

        if [[ "$mode" == jj ]]; then
          if ! tested_commit="$(jj log --no-graph -r '@-' -T 'commit_id ++ "\n"')"; then
            echo "Could not resolve Jujutsu parent commit" >&2
            return 1
          fi
          if [[ -z "$tested_commit" || "$tested_commit" == *$'\n'* ]]; then
            echo "Jujutsu parent must resolve to exactly one commit" >&2
            return 1
          fi
          if ! workspace_commit="$(jj log --no-graph -r '@' -T 'commit_id ++ "\n"')"; then
            echo "Could not resolve Jujutsu workspace commit" >&2
            return 1
          fi
          if [[ -z "$workspace_commit" || "$workspace_commit" == *$'\n'* ]]; then
            echo "Jujutsu workspace must resolve to exactly one commit" >&2
            return 1
          fi
          if ! tested_tree="$(git rev-parse "$tested_commit^{tree}")"; then
            echo "Could not resolve Jujutsu parent tree" >&2
            return 1
          fi
          if ! workspace_tree="$(git rev-parse "$workspace_commit^{tree}")"; then
            echo "Could not resolve Jujutsu workspace tree" >&2
            return 1
          fi
        else
          if ! status="$(git status --porcelain)"; then
            echo "Could not inspect Git worktree" >&2
            return 1
          fi
          if [[ -n "$status" ]]; then
            echo "Git worktree is dirty" >&2
            return 1
          fi
          if ! tested_commit="$(git rev-parse --verify 'HEAD^{commit}')"; then
            echo "Could not resolve Git HEAD commit" >&2
            return 1
          fi
          if ! tested_tree="$(git rev-parse "$tested_commit^{tree}")"; then
            echo "Could not resolve Git HEAD tree" >&2
            return 1
          fi
          workspace_tree="$tested_tree"
        fi

        printf '%s %s %s\n' "$tested_commit" "$tested_tree" "$workspace_tree"
      }

      if ! before="$(snapshot)"; then
        exit 1
      fi
      read -r tested_commit tested_tree workspace_tree <<< "$before"
      if [[ "$workspace_tree" != "$tested_tree" ]]; then
        echo "Current workspace tree differs from the commit to test" >&2
        exit 1
      fi

      if [[ "$mode" == git ]]; then
        if ! upstream_commit="$(git rev-parse --verify '@{upstream}^{commit}')"; then
          echo "Could not resolve Git HEAD upstream commit" >&2
          exit 1
        fi
        if [[ "$tested_commit" != "$upstream_commit" ]]; then
          echo "Git HEAD differs from its configured upstream; push before signing off" >&2
          exit 1
        fi
      fi

      if ! nix flake check -L --option accept-flake-config false; then
        echo "nix flake check failed; signoff is refused" >&2
        exit 1
      fi

      if ! after="$(snapshot)"; then
        echo "Repository state could not be verified after nix flake check; signoff is refused" >&2
        exit 1
      fi
      read -r post_commit post_tree post_workspace_tree <<< "$after"
      if [[ "$post_commit" != "$tested_commit" ]]; then
        echo "Tested commit changed while checking; signoff is refused" >&2
        exit 1
      fi
      if [[ "$post_tree" != "$tested_tree" ]]; then
        echo "Tested tree changed while checking; signoff is refused" >&2
        exit 1
      fi
      if [[ "$post_workspace_tree" != "$workspace_tree" ]]; then
        echo "Current workspace tree changed while checking; signoff is refused" >&2
        exit 1
      fi
      if [[ "$post_workspace_tree" != "$post_tree" ]]; then
        echo "Current workspace tree differs from the tested tree after checking; signoff is refused" >&2
        exit 1
      fi

      exec ${pkgs.runtimeShell} ${ghSignoff}/gh-signoff create --commit "$tested_commit"
    '';
  }
