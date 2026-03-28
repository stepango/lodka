# Linear todo to PR workflow

This repo contains a single Bash workflow script:

- `scripts/linear-todo-to-pr.sh`

It:

1. Reads the highest-priority Linear issue in `Todo` by default.
2. Switches to a feature branch.
3. Runs a configurable implementation hook.
4. Commits and pushes the result.
5. Opens a GitHub PR.
6. Moves the Linear issue to `In Review`.

## Requirements

- `LINEAR_API_KEY` for Linear GraphQL access, or `LINEAR_AUTHORIZATION` if you want to supply a full `Bearer ...` header value.
- `gh` authenticated against the target GitHub repo.
- `curl`, `git`, and `jq`.

## Usage

```bash
export LINEAR_API_KEY=...
export IMPLEMENT_CMD='your-command-that-edits-the-repo'
./scripts/linear-todo-to-pr.sh
```

Useful overrides:

```bash
./scripts/linear-todo-to-pr.sh --team-name "Platform" --limit 25
./scripts/linear-todo-to-pr.sh --issue LIN-123 --base-branch main
./scripts/linear-todo-to-pr.sh --dry-run
```

## Notes

- The script intentionally requires `IMPLEMENT_CMD` so it does not create empty PRs.
- The selected issue details are exported to the implementation hook as `LINEAR_ISSUE_*` variables and written to `LINEAR_ISSUE_FILE`.
- The Linear auth header comes from `LINEAR_AUTHORIZATION` when set, otherwise `LINEAR_API_KEY`.
- The working tree must be clean before the workflow starts.
