{pkgs}:
pkgs.writeShellApplication {
  name = "remote-ci";
  runtimeInputs = [pkgs.gh];
  text = ''
    usage() {
      cat >&2 <<'EOF'
    Usage: remote-ci <command> <owner/repo> <ref>

    <ref> is a commit SHA (full or short), a branch or tag, or #<pr> for a pull request's head.
    Each command resolves <ref> to one full SHA first, acts only on that SHA, and prints it.

    Commands:
      sha      print the SHA
      check    nix flake check -L --option accept-flake-config false github:<owner/repo>/<sha>
      signoff  set the `signoff` commit status to success on the SHA

    Example:
      sha=$(remote-ci check heretask/platform '#719') && remote-ci signoff heretask/platform "$sha"
    EOF
      exit 2
    }

    (( $# == 3 )) || usage
    command=$1 repo=$2 ref=$3
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage

    if [[ "$ref" =~ ^#([0-9]+)$ ]]; then
      sha=$(gh api "repos/$repo/pulls/''${BASH_REMATCH[1]}" --jq .head.sha)
    else
      sha=$(gh api "repos/$repo/commits/$ref" --jq .sha)
    fi
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || {
      echo "remote-ci: could not resolve $ref in $repo" >&2
      exit 1
    }
    echo "remote-ci: $repo $ref -> $sha" >&2

    case "$command" in
      sha) ;;
      check)
        nix flake check -L --option accept-flake-config false "github:$repo/$sha" >&2 || {
          echo "remote-ci: nix flake check failed for $sha" >&2
          exit 1
        }
        ;;
      signoff)
        login=$(gh api user --jq .login)
        gh api --method POST "repos/$repo/statuses/$sha" \
          -f state=success -f context=signoff -f "description=$login signed off" >/dev/null
        echo "remote-ci: signed off $sha as $login" >&2
        ;;
      *) usage ;;
    esac
    echo "$sha"
  '';
}
