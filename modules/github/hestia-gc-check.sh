# Fails when `hestia gc` left the default branch without a manifest version it had before: the
# next job would start from an empty cache and rebuild everything. Expects GH_TOKEN and DEFAULT_REF.
set -euo pipefail

heads=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/caches?per_page=100&key=m3%23&ref=$DEFAULT_REF" \
  --jq '.actions_caches[] | select(.key | test("^m3#[0-9]+$")) | .key' | wc -l)
if ((heads == 0)); then
  echo "::error title=hestia cache reset::hestia gc left $DEFAULT_REF without a manifest version. The cache starts empty and the next jobs rebuild everything."
  exit 1
fi
echo "$DEFAULT_REF has $heads manifest version(s)."
