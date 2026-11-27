# check_title TITLE [--squash-merged]
# Expects changelog_types, other_types, changelog_scopes, other_scopes,
# feat_disallowed_verbs (arrays), other_types_help and max_length.
check_title() {
  local title=$1 squash_merged=${2-}
  local all_types=("${changelog_types[@]}" "${other_types[@]}")
  local all_scopes=("${changelog_scopes[@]}" "${other_scopes[@]}")
  # GitHub appends " (#<PR number>)" when it squash-merges; the PR-title check never saw it.
  if [[ -n "$squash_merged" && "$title" =~ ^(.*)\ \(#[0-9]+\)$ ]]; then
    title=${BASH_REMATCH[1]}
  fi

  local header=${title%%: *}
  local description=${title#*: }
  if [[ "$header" == "$title" ]]; then
    printf '"%s": missing ": " after the type. Write "type: description" or "type(scope): description", e.g. "fix: handle an empty list".\n' "$title" >&2
    return 1
  fi
  if [[ ! "$header" =~ ^([^()!]*)(\(([^()]*)\))?(!)?$ ]]; then
    printf '"%s": "%s" is not "type", "type(scope)", "type!" or "type(scope)!".\n' "$title" "$header" >&2
    return 1
  fi
  local type=${BASH_REMATCH[1]} parens=${BASH_REMATCH[2]} scope=${BASH_REMATCH[3]}

  if [[ " ${all_types[*]} " != *" $type "* ]]; then
    printf '"%s": unknown type "%s". Changelog types: %s. Other types: %s.\n' \
      "$title" "$type" "${changelog_types[*]}" "${other_types[*]}" >&2
    return 1
  fi
  if [[ -n "$parens" && -z "$scope" ]]; then
    printf '"%s": empty scope "()". Drop the parentheses or name a scope.\n' "$title" >&2
    return 1
  fi
  if [[ -n "$scope" && ${#all_scopes[@]} -gt 0 ]]; then
    if [[ " ${all_scopes[*]} " != *" $scope "* ]]; then
      printf '"%s": unknown scope "%s". Allowed scopes: %s, or no scope.\n' "$title" "$scope" "${all_scopes[*]}" >&2
      return 1
    fi
    if [[ " ${changelog_types[*]} " == *" $type "* && " ${changelog_scopes[*]} " != *" $scope "* ]]; then
      printf '"%s": "%s" adds a changelog entry, but "%s" changes ship nothing. Changelog types take %s, or no scope. If nothing shipped changed, use the type without a changelog entry that fits: %s.\n' \
        "$title" "$type" "$scope" "${changelog_scopes[*]}" "$other_types_help" >&2
      return 1
    fi
  fi

  if [[ -z "${description// /}" ]]; then
    printf '"%s": the description after ": " is empty.\n' "$title" >&2
    return 1
  fi
  if [[ "$type" == "feat" && ${#feat_disallowed_verbs[@]} -gt 0 ]]; then
    local desc_lower=${description,,} verb verb_lower
    for verb in "${feat_disallowed_verbs[@]}"; do
      verb_lower=${verb,,}
      if [[ "$desc_lower" == "$verb_lower" || "$desc_lower" == "$verb_lower "* ]]; then
        if [[ -n "$squash_merged" ]]; then
          printf 'warning: "%s": description starts with "%s"; prefer "improvement" (patch bump) over "feat" (minor bump).\n' \
            "$title" "$verb" >&2
        else
          printf '"%s": descriptions starting with "%s" belong under "improvement" (patch bump), not "feat" (minor bump). Use "improvement%s: %s" or reword if this is genuinely a new user-facing capability.\n' \
            "$title" "$verb" "$parens" "$description" >&2
          return 1
        fi
        break
      fi
    done
  fi
  local length
  length=$(
    LC_ALL=C
    stripped=${description//[$'\x80'-$'\xbf']/}
    printf '%d' "${#stripped}"
  )
  if ((length > max_length)); then
    # A pushed commit cannot be reworded, so on main the length is only reported.
    if [[ -n "$squash_merged" ]]; then
      printf 'warning: "%s": description is %d characters, the limit is %d.\n' "$title" "$length" "$max_length" >&2
    else
      printf '"%s": description is %d characters, the limit is %d. Shorten it by %d.\n' \
        "$title" "$length" "$max_length" "$((length - max_length))" >&2
      return 1
    fi
  fi
}
