# Decides whether a push to main still needs the full scan. When the push merged a pull request
# whose head this workflow already scanned, the push takes that run's result instead of scanning
# the same change again. Anything unexpected means "scan".
# Expects GH_TOKEN and WORKFLOW, this workflow's file name.
head=$(gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" \
  --jq "[.[] | select(.merge_commit_sha == \"$GITHUB_SHA\")][0].head.sha // empty") || head=
if [[ -z $head ]]; then
  echo "This push merged no pull request: scanning."
  exit 0
fi

# Newest first. A cancelled run scanned nothing.
run=$(gh api --method GET "repos/$GITHUB_REPOSITORY/actions/workflows/$WORKFLOW/runs" \
  -f head_sha="$head" -f event=pull_request -f status=completed \
  --jq '[.workflow_runs[] | select(.conclusion == "success" or .conclusion == "failure")][0] // empty | "\(.conclusion) \(.html_url)"') || run=
if [[ -z $run ]]; then
  echo "The merged pull request's head $head has no finished scan: scanning."
  exit 0
fi

read -r conclusion url <<<"$run"
echo "scanned=true" >>"$GITHUB_OUTPUT"
if [[ $conclusion == failure ]]; then
  echo "The pull request this push merged was scanned and the scan failed: $url" >>"$GITHUB_STEP_SUMMARY"
  echo "::error title=Scan failed on the pull request::This push merged a pull request whose scan failed: $url"
  exit 1
fi
echo "The pull request this push merged was already scanned: $url" | tee -a "$GITHUB_STEP_SUMMARY"
