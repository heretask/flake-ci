# Lints the pull request's title with check_title, defined above. PR_TITLE is the title in the event.
# REPORT=true also posts the result as the `PR title lint` commit status on HEAD_SHA, and lints the
# title the pull request has now: the event's title is stale in a re-run, and when the title was
# edited after the push. It needs GH_TOKEN and PR_NUMBER. ENFORCE=true fails on an invalid title.
title=$PR_TITLE
if [[ ${REPORT-} == true ]]; then
  title=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq .title) || title=$PR_TITLE
fi

state=success
description="The title follows the commit convention"
if ! problem=$(check_title "$title" 2>&1); then
  printf '::error title=Invalid PR title::%s Edit the PR title; this check reruns.\n' "$problem"
  state=failure
  description=$problem
fi

if [[ ${REPORT-} == true ]]; then
  # A status description holds 140 characters; the annotation above has the whole message.
  if ! gh api --method POST "repos/$GITHUB_REPOSITORY/statuses/$HEAD_SHA" \
    -f context='PR title lint' -f state="$state" -f description="${description:0:140}" \
    -f "target_url=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" >/dev/null; then
    echo "::error title=PR title lint::Could not post the PR title lint status."
    exit 1
  fi
fi

if [[ $state == failure && ${ENFORCE-} == true ]]; then
  exit 1
fi
