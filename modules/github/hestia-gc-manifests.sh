# Prunes hestia's manifest versions (`m3#<index>` cache entries) before `hestia gc` runs.
#
# hestia v3.1.0 only removes superseded versions after a successful gc, and removes them by key in
# every ref at once (Mic92/hestia#162). Two things follow:
#   - A pull request writes its own versions, continuing the default branch's numbering. A version
#     there that is higher than, or keyed like, the default branch's newest makes gc delete that
#     newest version, and every job after it starts from an empty cache.
#   - While gc fails, versions pile up. gc downloads and decodes each one, so it then times out
#     and never reaches its own cleanup (Mic92/hestia#192).
# So this deletes, by cache ID: every version outside the default branch, and every version on it
# except the newest. Like hestia, it keeps what is younger than an hour for jobs still reading it.
# A pull request without its own version reads the default branch's again.
#
# Expects GH_TOKEN (actions: write) and DEFAULT_REF. DRY_RUN=true only lists. Writes `head=true`
# to GITHUB_OUTPUT when the default branch has a version.
set -euo pipefail

min_age=3600
now=$(date +%s)

# id, ref, cache version, key, created: newest first. The key filter is a prefix match.
entries=$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/caches?per_page=100&key=m3%23" \
  --jq '.actions_caches[] | select(.key | test("^m3#[0-9]+$"))
    | [.id, .ref, .version, .key, (.created_at | sub("\\.[0-9]+"; "") | fromdate)] | @tsv' |
  sort -t $'\t' -k5,5nr)

declare -A kept=()
head=false
deleted=0
while IFS=$'\t' read -r id ref version key created; do
  [[ -n $id ]] || continue
  if [[ $ref == "$DEFAULT_REF" && -z ${kept[$version]-} ]]; then
    # The newest version of each cache version namespace is the one jobs load.
    kept[$version]=$key
    head=true
    echo "keep    $key on $ref"
    continue
  fi
  if ((now - created <= min_age)); then
    echo "recent  $key on $ref"
    continue
  fi
  if [[ ${DRY_RUN-} == true ]]; then
    echo "would delete $key on $ref"
  else
    gh api --method DELETE "repos/$GITHUB_REPOSITORY/actions/caches/$id" >/dev/null
    echo "deleted $key on $ref"
  fi
  deleted=$((deleted + 1))
done <<<"$entries"

if [[ ${DRY_RUN-} == true ]]; then
  echo "Dry run: $deleted manifest version(s) would be deleted."
else
  echo "Deleted $deleted manifest version(s)."
fi
if [[ $head == true ]]; then
  echo "head=true" >>"$GITHUB_OUTPUT"
fi
