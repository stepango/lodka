#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: linear-todo-to-pr.sh [options]

Options:
  --issue ID           Work on a specific Linear issue ID/identifier.
  --team-id ID         Limit issue selection and state updates to a team.
  --team-name NAME     Resolve the team by exact name before selecting issues.
  --base-branch NAME   Base branch for the PR. Defaults to the repo default branch.
  --todo-state NAME    Linear state name to select. Defaults to Todo.
  --review-state NAME  Linear state name to move to after the PR is opened.
  --implement-cmd CMD  Shell command that performs the actual implementation.
  --limit N            Max todo issues to inspect when selecting automatically.
  --dry-run            Print the selected issue and exit without making changes.
  -h, --help           Show this help text.

Required environment:
  LINEAR_API_KEY       Linear personal API key or OAuth access token.

Optional environment:
  IMPLEMENT_CMD        Same as --implement-cmd.
  LINEAR_TEAM_ID       Same as --team-id.
  LINEAR_TEAM_NAME     Same as --team-name.
  LINEAR_TODO_STATE_NAME
  LINEAR_IN_REVIEW_STATE_NAME
  LINEAR_LIMIT
  BASE_BRANCH
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

linear_api() {
  local query="$1"
  local variables_json="$2"
  local payload
  local linear_auth="${LINEAR_AUTHORIZATION:-${LINEAR_API_KEY:-}}"

  [[ -n "$linear_auth" ]] || die 'LINEAR_API_KEY or LINEAR_AUTHORIZATION is required'
  payload="$(jq -n --arg query "$query" --argjson variables "$variables_json" '{query: $query, variables: $variables}')"
  curl -fsS \
    -H 'Content-Type: application/json' \
    -H "Authorization: ${linear_auth}" \
    --data-binary "$payload" \
    https://api.linear.app/graphql
}

linear_query() {
  local query="$1"
  local variables_json="$2"
  local response

  response="$(linear_api "$query" "$variables_json")"
  if jq -e '(.errors? // []) | length > 0' >/dev/null 2>&1 <<<"$response"; then
    jq -r '.errors[] | "Linear GraphQL error: \(.message)"' <<<"$response" >&2
    die "Linear request failed"
  fi
  printf '%s\n' "$response"
}

resolve_team_id() {
  local team_name="$1"
  local response

  response="$(linear_query 'query { teams { nodes { id name } } }' '{}')"
  jq -r --arg team_name "$team_name" '
    .data.teams.nodes
    | map(select(.name == $team_name))
    | if length == 0 then empty else .[0].id end
  ' <<<"$response"
}

fetch_issue() {
  local issue_id="$1"
  local query
  query='query ($id: ID!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      url
      createdAt
      updatedAt
      state { id name }
      team { id name }
    }
  }'

  linear_query "$query" "$(jq -n --arg id "$issue_id" '{id: $id}')"
}

fetch_todo_issue() {
  local todo_state_name="$1"
  local limit="$2"
  local team_id="$3"
  local query variables response

  if [[ -n "$team_id" ]]; then
    query='query ($first: Int!, $stateName: String!, $teamId: String!) {
      issues(
        first: $first
        filter: {
          state: { name: { eq: $stateName } }
          team: { id: { eq: $teamId } }
        }
      ) {
        nodes {
          id
          identifier
          title
          description
          url
          createdAt
          updatedAt
          state { id name }
          team { id name }
        }
      }
    }'
    variables="$(jq -n --argjson first "$limit" --arg stateName "$todo_state_name" --arg teamId "$team_id" '{first: $first, stateName: $stateName, teamId: $teamId}')"
  else
    query='query ($first: Int!, $stateName: String!) {
      issues(
        first: $first
        filter: {
          state: { name: { eq: $stateName } }
        }
      ) {
        nodes {
          id
          identifier
          title
          description
          url
          createdAt
          updatedAt
          state { id name }
          team { id name }
        }
      }
    }'
    variables="$(jq -n --argjson first "$limit" --arg stateName "$todo_state_name" '{first: $first, stateName: $stateName}')"
  fi

  response="$(linear_query "$query" "$variables")"
  jq -c --arg state_name "$todo_state_name" '
    .data.issues.nodes
    | map(select(.state.name == $state_name))
    | sort_by(.createdAt)
    | .[0]
  ' <<<"$response"
}

resolve_in_review_state_id() {
  local team_id="$1"
  local state_name="$2"
  local response

  response="$(linear_query 'query { workflowStates { nodes { id name team { id name } } } }' '{}')"
  jq -r --arg team_id "$team_id" --arg state_name "$state_name" '
    .data.workflowStates.nodes
    | map(select(.name == $state_name and ((.team.id // "") == $team_id)))
    | if length == 0 then empty else .[0].id end
  ' <<<"$response"
}

slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

ensure_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die 'working tree must be clean before running this workflow'
  fi
}

create_branch_from_base() {
  local base_branch="$1"
  local branch_name="$2"

  if git show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    git switch -c "$branch_name" "origin/$base_branch"
    return
  fi

  if git show-ref --verify --quiet "refs/heads/$base_branch"; then
    git switch -c "$branch_name" "$base_branch"
    return
  fi

  die "unable to find base branch: $base_branch"
}

commit_changes() {
  local issue_identifier="$1"
  local issue_title="$2"

  if git diff --quiet && git diff --cached --quiet; then
    die 'implementation hook did not create any changes'
  fi

  git add -A
  git commit -m "Linear ${issue_identifier}: ${issue_title}"
}

select_repository_default_branch() {
  gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
}

main() {
  local issue_id=""
  local team_id="${LINEAR_TEAM_ID:-}"
  local team_name="${LINEAR_TEAM_NAME:-}"
  local base_branch="${BASE_BRANCH:-}"
  local todo_state_name="${LINEAR_TODO_STATE_NAME:-Todo}"
  local in_review_state_name="${LINEAR_IN_REVIEW_STATE_NAME:-In Review}"
  local implement_cmd="${IMPLEMENT_CMD:-}"
  local limit="${LINEAR_LIMIT:-50}"
  local dry_run=0

  while (($#)); do
    case "$1" in
      --issue)
        issue_id="${2:-}"
        [[ -n "$issue_id" ]] || die '--issue requires a value'
        shift 2
        ;;
      --issue=*)
        issue_id="${1#*=}"
        shift
        ;;
      --team-id)
        team_id="${2:-}"
        [[ -n "$team_id" ]] || die '--team-id requires a value'
        shift 2
        ;;
      --team-id=*)
        team_id="${1#*=}"
        shift
        ;;
      --team-name)
        team_name="${2:-}"
        [[ -n "$team_name" ]] || die '--team-name requires a value'
        shift 2
        ;;
      --team-name=*)
        team_name="${1#*=}"
        shift
        ;;
      --base-branch)
        base_branch="${2:-}"
        [[ -n "$base_branch" ]] || die '--base-branch requires a value'
        shift 2
        ;;
      --base-branch=*)
        base_branch="${1#*=}"
        shift
        ;;
      --todo-state)
        todo_state_name="${2:-}"
        [[ -n "$todo_state_name" ]] || die '--todo-state requires a value'
        shift 2
        ;;
      --todo-state=*)
        todo_state_name="${1#*=}"
        shift
        ;;
      --review-state)
        in_review_state_name="${2:-}"
        [[ -n "$in_review_state_name" ]] || die '--review-state requires a value'
        shift 2
        ;;
      --review-state=*)
        in_review_state_name="${1#*=}"
        shift
        ;;
      --implement-cmd)
        implement_cmd="${2:-}"
        [[ -n "$implement_cmd" ]] || die '--implement-cmd requires a value'
        shift 2
        ;;
      --implement-cmd=*)
        implement_cmd="${1#*=}"
        shift
        ;;
      --limit)
        limit="${2:-}"
        [[ -n "$limit" ]] || die '--limit requires a value'
        shift 2
        ;;
      --limit=*)
        limit="${1#*=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "${LINEAR_API_KEY:-}${LINEAR_AUTHORIZATION:-}" ]] || die 'LINEAR_API_KEY or LINEAR_AUTHORIZATION is required'
  require_cmd curl
  require_cmd git
  require_cmd gh
  require_cmd jq

  ensure_clean_worktree

  if [[ -n "$team_name" && -z "$team_id" ]]; then
    team_id="$(resolve_team_id "$team_name")"
    [[ -n "$team_id" ]] || die "could not resolve team name: $team_name"
  fi

  if [[ -z "$base_branch" ]]; then
    base_branch="$(select_repository_default_branch)"
  fi
  [[ -n "$base_branch" ]] || die 'could not determine base branch'

  if git remote get-url origin >/dev/null 2>&1; then
    git fetch origin "$base_branch" >/dev/null 2>&1 || true
  fi

  local issue_json
  if [[ -n "$issue_id" ]]; then
    issue_json="$(fetch_issue "$issue_id")"
    issue_json="$(jq -c '.data.issue' <<<"$issue_json")"
  else
    issue_json="$(fetch_todo_issue "$todo_state_name" "$limit" "$team_id")"
  fi

  [[ "$issue_json" != "null" && -n "$issue_json" ]] || die "no Linear issue found in state: $todo_state_name"

  local linear_id linear_identifier linear_title linear_description linear_url linear_team_id linear_team_name linear_state_name branch_name pr_title pr_body review_state_id current_state_name
  linear_id="$(jq -r '.id' <<<"$issue_json")"
  linear_identifier="$(jq -r '.identifier' <<<"$issue_json")"
  linear_title="$(jq -r '.title' <<<"$issue_json")"
  linear_description="$(jq -r '.description // ""' <<<"$issue_json")"
  linear_url="$(jq -r '.url' <<<"$issue_json")"
  linear_team_id="$(jq -r '.team.id' <<<"$issue_json")"
  linear_team_name="$(jq -r '.team.name' <<<"$issue_json")"
  linear_state_name="$(jq -r '.state.name' <<<"$issue_json")"

  if [[ -n "$issue_id" && "$linear_state_name" != "$todo_state_name" ]]; then
    die "issue ${linear_identifier} is in state ${linear_state_name}, expected ${todo_state_name}"
  fi

  branch_name="linear/${linear_identifier}-$(slugify "$linear_title")"
  branch_name="${branch_name:0:200}"
  pr_title="${linear_identifier}: ${linear_title}"
  pr_body=$(cat <<EOF
Linear issue: ${linear_url}
Current state: ${linear_state_name}
Team: ${linear_team_name}

${linear_description}
EOF
)

  local tmp_dir issue_brief issue_json_file
  tmp_dir="$(mktemp -d)"
  issue_brief="${tmp_dir}/linear-issue.md"
  issue_json_file="${tmp_dir}/linear-issue.json"
  trap 'rm -rf "$tmp_dir"' EXIT

  cat >"$issue_brief" <<EOF
# ${linear_identifier}: ${linear_title}

- URL: ${linear_url}
- Team: ${linear_team_name}
- Current state: ${linear_state_name}

## Description

${linear_description:-No description provided.}
EOF

  printf '%s\n' "$issue_json" >"$issue_json_file"
  export LINEAR_ISSUE_FILE="$issue_brief"
  export LINEAR_ISSUE_JSON="$issue_json_file"
  export LINEAR_ISSUE_ID="$linear_id"
  export LINEAR_ISSUE_IDENTIFIER="$linear_identifier"
  export LINEAR_ISSUE_TITLE="$linear_title"
  export LINEAR_ISSUE_URL="$linear_url"
  export LINEAR_ISSUE_TEAM_ID="$linear_team_id"
  export LINEAR_ISSUE_TEAM_NAME="$linear_team_name"
  export LINEAR_ISSUE_STATE_NAME="$linear_state_name"

  if [[ "$dry_run" -eq 1 ]]; then
    log "Selected issue: ${linear_identifier} - ${linear_title}"
    log "Branch: ${branch_name}"
    log "Base branch: ${base_branch}"
    return 0
  fi

  create_branch_from_base "$base_branch" "$branch_name"

  if [[ -z "$implement_cmd" ]]; then
    die 'IMPLEMENT_CMD is required to perform the implementation step'
  fi

  log "Selected Linear issue: ${linear_identifier} - ${linear_title}"
  log "Running implementation hook"
  bash -lc "$implement_cmd"

  commit_changes "$linear_identifier" "$linear_title"
  git push -u origin "$branch_name"

  log "Opening GitHub pull request"
  gh pr create --title "$pr_title" --body "$pr_body" --base "$base_branch"

  review_state_id="$(resolve_in_review_state_id "$linear_team_id" "$in_review_state_name")"
  [[ -n "$review_state_id" ]] || die "could not resolve Linear state: ${in_review_state_name}"

  current_state_name="$linear_state_name"
  if [[ "$current_state_name" != "$in_review_state_name" ]]; then
    log "Updating Linear issue to ${in_review_state_name}"
    linear_query \
      'mutation ($id: ID!, $stateId: ID!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
        issue { id identifier state { id name } }
      }
    }' \
      "$(jq -n --arg id "$linear_id" --arg stateId "$review_state_id" '{id: $id, stateId: $stateId}')"
    log "Linear issue updated to ${in_review_state_name}"
  else
    log "Linear issue is already in ${in_review_state_name}; skipping update"
  fi
}

main "$@"
