# Decides whether a push to main still needs the full scan. A pull request's scan records the tree
# it checked out, the merge of its head into main as main was then, as an artifact named
# `vuln-tree-<tree>`. When the push merged that pull request and its commit has the same tree,
# nothing landed on main in between: the push takes that run's result instead of scanning the
# same files again. Anything else, and anything unexpected, means "scan".
# Expects GH_TOKEN and WORKFLOW, this workflow's file name.
head=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
  --jq "[.[] | select(.merge_commit_sha == \"$GITHUB_SHA\")][0].head.sha // empty") || head=
if [[ -z $head ]]; then
  echo "This push merged no pull request: scanning."
  exit 0
fi

tree=$(gh api "repos/$GITHUB_REPOSITORY/git/commits/$GITHUB_SHA" --jq .tree.sha) || tree=
if [[ -z $tree ]]; then
  echo "Could not read this commit's tree: scanning."
  exit 0
fi

# Newest first. A cancelled run scanned nothing.
runs=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/$WORKFLOW/runs" \
  -f head_sha="$head" -f event=pull_request -f status=completed \
  --jq '.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure") | "\(.id) \(.conclusion) \(.html_url)"') || runs=
if [[ -z $runs ]]; then
  echo "The merged pull request's head $head has no finished scan: scanning."
  exit 0
fi

conclusion=
while read -r id result url; do
  if gh api "repos/$GITHUB_REPOSITORY/actions/runs/$id/artifacts" --jq '.artifacts[].name' |
    grep -qxF "vuln-tree-$tree"; then
    conclusion=$result
    break
  fi
done <<<"$runs"
if [[ -z $conclusion ]]; then
  echo "No finished scan of the merged pull request recorded this tree, $tree: scanning."
  exit 0
fi

echo "scanned=true" >>"$GITHUB_OUTPUT"
if [[ $conclusion == failure ]]; then
  echo "The pull request this push merged scanned the same tree and the scan failed: $url" >>"$GITHUB_STEP_SUMMARY"
  echo "::error title=Scan failed on the pull request::This push merged a pull request whose scan of the same tree failed: $url"
  exit 1
fi
echo "The pull request this push merged already scanned this tree: $url" | tee -a "$GITHUB_STEP_SUMMARY"
