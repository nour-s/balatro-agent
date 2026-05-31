---
name: github-publish
description: "Publish a local folder as a new public GitHub repo under nour-s. Rewrites commit authors, creates the repo, and pushes. Run this skill when the user wants to push a project to GitHub."
---

# Publish a folder to GitHub (nour-s account)

## Goal
Create a new public GitHub repo under `nour-s` from a local folder and push it — with all commits attributed to `nour-s`, no real name or email exposed.

## Steps

### 1. Confirm folder and repo name

Ask the user:
- Which folder to publish (default: current working directory)
- What to name the repo on GitHub (default: the folder's basename)

### 2. Check for secrets

Before doing anything else, scan the folder:

```bash
grep -rn --include="*.py" --include="*.js" --include="*.ts" --include="*.sh" \
  --include="*.json" --include="*.yaml" --include="*.env" \
  -E "(api_key\s*=\s*['\"][^'\"]+['\"]|secret\s*=\s*['\"][^'\"]+['\"]|password\s*=\s*['\"][^'\"]+['\"]|sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36,}|ghs_[a-zA-Z0-9]{36,})" \
  <FOLDER> --exclude-dir=.git 2>/dev/null
```

Stop and report to the user if any hardcoded secrets are found. Do NOT proceed until they are removed.

### 3. Initialize git if needed

```bash
cd <FOLDER>
git init -b main          # only if not already a git repo
git config --local user.name  "nour-s"
git config --local user.email "nour-s@users.noreply.github.com"
```

### 4. Set up .gitignore

Check that `.gitignore` exists. At minimum it should exclude:
- `__pycache__/`, `*.pyc`
- `node_modules/`
- `.env`, `*.env`
- Large binaries (`.apk`, `.exe`, binary builds)
- Any auto-generated caches or local state

### 5. Rewrite existing commit authors

If the repo already has commits with a different author identity, rewrite them all:

```bash
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch --env-filter '
  export GIT_AUTHOR_NAME="nour-s"
  export GIT_AUTHOR_EMAIL="nour-s@users.noreply.github.com"
  export GIT_COMMITTER_NAME="nour-s"
  export GIT_COMMITTER_EMAIL="nour-s@users.noreply.github.com"
' --tag-name-filter cat -- --branches --tags
```

Verify: `git log --format="%an <%ae>" | sort -u` — should show only `nour-s`.

### 6. Stage and commit everything

```bash
git add -A
git status   # review what's about to be committed — look for unexpected files
git commit -m "initial commit"
```

Skip if the repo already has commits and nothing is pending.

### 7. Create the GitHub repo

```bash
env -u GITHUB_TOKEN gh repo create nour-s/<REPO_NAME> \
  --public \
  --description "<one-line description>" 2>&1
```

If `GITHUB_TOKEN` is not set, omit the `env -u GITHUB_TOKEN` prefix.

### 8. Add the remote

```bash
git remote add origin https://github.com/nour-s/<REPO_NAME>.git
# or if it already exists:
git remote set-url origin https://github.com/nour-s/<REPO_NAME>.git
```

### 9. Push

**IMPORTANT:** The `GITHUB_TOKEN` env var in this session is bound to `nour-sb`, not `nour-s`.  
Tell the user to run this themselves from their terminal:

```bash
unset GITHUB_TOKEN && git -C <FOLDER> push -u origin main
```

When prompted:
- Username: `nour-s`
- Password: nour-s personal access token (from https://github.com/settings/tokens)

If they want Claude to push automatically in future sessions, they should:
- Remove `GITHUB_TOKEN` from their shell profile, or
- Set `GITHUB_TOKEN` to a nour-s token instead

### 10. Confirm

```bash
env -u GITHUB_TOKEN gh repo view nour-s/<REPO_NAME> --web 2>&1 || \
  echo "https://github.com/nour-s/<REPO_NAME>"
```

Report the URL to the user.

## Notes

- `gh repo create` works with `env -u GITHUB_TOKEN` because gh falls back to the keyring and nour-s is the active keyring account.
- `git push` falls back to macOS osxkeychain which returns nour-sb's token — this is why the user must push manually from their own terminal session.
- `git filter-branch` requires a clean working tree. Commit or stash changes first.
- Never commit `.claude/` — add it to `.gitignore` before the initial commit.
