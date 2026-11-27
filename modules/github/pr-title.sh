# Lints the pull request's title with check_title, defined above. PR_TITLE is the title in the event.
# REPORT=true also posts the result as the `PR title lint` commit status on HEAD_SHA, and lints the
# title the pull request has now: the event's title is stale in a re-run, and when the title was
# edited after the push. It needs GH_TOKEN and PR_NUMBER. ENFORCE=true fails on an invalid title.
# Expects minor_types and non_shipped_paths (arrays) in addition to what check_title expects.
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

if [[ $state == success ]]; then
  header=${title%%: *}
  if [[ $header =~ ^([^()!]*)(\(([^()]*)\))?(!)?$ ]]; then
    type=${BASH_REMATCH[1]}
    breaking=${BASH_REMATCH[4]}

    # The first changed file that matches no non-shipped pattern; empty when all of them match.
    first_shipped=
    file_count=0
    if ((${#non_shipped_paths[@]} > 0)); then
      if files_out=$(gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" --jq '.[].filename'); then
        mapfile -t files <<<"$files_out"
        for f in "${files[@]}"; do
          [[ -n $f ]] || continue
          file_count=$((file_count + 1))
          matched=false
          for pat in "${non_shipped_paths[@]}"; do
            # shellcheck disable=SC2053
            if [[ $f == $pat ]]; then
              matched=true
              break
            fi
          done
          if ! $matched; then
            first_shipped=$f
            break
          fi
        done
      fi
    fi

    if [[ " ${changelog_types[*]} " == *" $type "* ]] && ((file_count > 0)) && [[ -z $first_shipped ]]; then
      problem="\"$title\": \"$type\" adds a changelog entry and bumps the version, but every changed file matches ci.commits.nonShippedPaths. Use the type without a changelog entry that fits: $other_types_help."
      printf '::error title=Non-shipped PR using changelog type::%s\n' "$problem"
      state=failure
      description=$problem
    fi

    if [[ $state == success ]]; then
      if [[ -n $breaking ]]; then
        msg="This PR title (\"$title\") marks a breaking change and will trigger a **major** version bump on release."
        printf '::notice title=Major version bump::%s\n' "$msg"
        if [[ -n ${GITHUB_STEP_SUMMARY-} ]]; then
          printf '### Version bump\n\n%s\n' "$msg" >>"$GITHUB_STEP_SUMMARY"
        fi
      elif [[ " ${minor_types[*]} " == *" $type "* ]]; then
        msg="This PR title (\"$title\") uses \`$type\` and will trigger a **minor** version bump on release. Confirm this is a new user-facing capability (use \`improvement\` for patch-level tweaks, notices, or refinements)."
        printf '::notice title=Minor version bump::%s\n' "$msg"
        if [[ -n ${GITHUB_STEP_SUMMARY-} ]]; then
          printf '### Version bump\n\n%s\n' "$msg" >>"$GITHUB_STEP_SUMMARY"
        fi
      elif [[ " ${other_types[*]} " == *" $type "* && -n $first_shipped ]]; then
        msg="This PR title (\"$title\") uses \`$type\`, which adds no changelog entry and no version bump, but the PR changes files that ship, such as \`$first_shipped\`. If it alters what ships, use a changelog type (${changelog_types[*]})."
        printf '::notice title=No changelog entry::%s\n' "$msg"
        if [[ -n ${GITHUB_STEP_SUMMARY-} ]]; then
          printf '### No changelog entry\n\n%s\n' "$msg" >>"$GITHUB_STEP_SUMMARY"
        fi
      fi
    fi
  fi
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
