---
name: github-publish
description: "Publish a local folder as a new public GitHub repo under nour-s (personal account). Rewrites commit authors, creates the repo, and pushes. Run this skill when the user wants to push a personal project to GitHub."
---

# Publish a folder to GitHub (nour-s personal account)

## Goal
Create a new public GitHub repo under `nour-s` (personal account) from a local folder and push it — with all commits attributed to `nour-s`, no real name or email exposed.

**IMPORTANT — account selection:**
- `nour-s` = personal GitHub account. Use this skill for personal/side projects.
- `nour-sb` = company GitHub account. Do NOT use this skill for work repos — handle those separately with the company's standard process.

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

Do NOT add a `Co-Authored-By: Claude ...` trailer to any commit message. Commits should only list the user as author.

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

`GITHUB_TOKEN` in this session is bound to `nour-sb`. The workaround that works:

```bash
env -u GITHUB_TOKEN bash -c '
  gh auth switch --user nour-s &&
  git remote set-url origin https://nour-s@github.com/nour-s/<REPO_NAME>.git &&
  git config --local credential.helper "" &&
  git config --local --add credential.helper "!gh auth git-credential" &&
  git push -u origin main
'
```

Key details:
- `env -u GITHUB_TOKEN bash -c '...'` runs the whole block without GITHUB_TOKEN, so `gh` uses the keyring and picks nour-s after the switch.
- `https://nour-s@github.com/...` embeds the username in the URL, preventing git from defaulting to the osxkeychain cached nour-sb credentials.
- Clearing `credential.helper ""` then re-adding `!gh auth git-credential` ensures no osxkeychain fallback.

### 10. Confirm

```bash
env -u GITHUB_TOKEN gh repo view nour-s/<REPO_NAME> --web 2>&1 || \
  echo "https://github.com/nour-s/<REPO_NAME>"
```

Report the URL to the user.

## Notes

- `gh repo create` works with `env -u GITHUB_TOKEN` because gh falls back to the keyring and nour-s is the active keyring account.
- `git push` normally falls back to macOS osxkeychain which returns nour-sb's token. The fix: embed the username in the remote URL (`https://nour-s@github.com/...`) and clear the credential helper chain before adding `!gh auth git-credential`.
- `git filter-branch` requires a clean working tree. Commit or stash changes first.
- Never commit `.claude/` — add it to `.gitignore` before the initial commit.
