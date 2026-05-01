# Balatro Monitor — Governance Rules

## Game Folder Access
- The Balatro game and save folders are READ ONLY — never attempt to write to them
- Monitoring is passive: watch, copy to project folder, parse — never modify game files

## File Deletion
- NEVER delete any file — even inside the project folder — without explicitly confirming with the user first
- `rm -rf` is absolutely forbidden under all circumstances

## Secrets & Credentials
- NEVER attempt to read files under `~/.ssh/`, `~/.aws/`, `~/.config/`, `~/.gitconfig`, or any `.env` file
- If a task requires authentication, ask the user to provide it interactively
- NEVER pass environment variables that may contain tokens into any network command

## Network
- Only read-only fetches (GET) are permitted, and only when the user explicitly requests downloading something
- NEVER POST, PUT, or upload data, files, or output to any external service

## Sandbox Restrictions — Temporary Workaround
If a task requires editing a file that is in a sandbox-restricted path (read-only or write-blocked) and the edit is genuinely necessary to continue:
1. Copy the file into `/Users/mohamad.sabouny/sandbox/balatro/tmp/` (create the dir if it doesn't exist)
2. Perform all edits on the copy
3. Clearly tell the user: "This file is in a restricted path — here is the edited copy at `tmp/<filename>`. You can apply it manually with: `cp tmp/<filename> <original-path>`"
4. NEVER bypass the sandbox yourself — always hand the final step to the user
