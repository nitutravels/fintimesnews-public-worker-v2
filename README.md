# Fintimes Public Worker v2

This public repository contains code only. Personal portraits, narration files, OAuth credentials, API keys and private source files remain in the private `nitutravels/fintimesnews-automation` repository or in encrypted GitHub Actions secrets.

## Current status

Only the private-repository connection test is enabled. It verifies that the public worker can read the required private source files without publishing, rendering or uploading a video.

Production scheduling will remain disabled until the connection test succeeds and the remaining encrypted secrets are configured.

## Required repository secret

Under **Settings → Secrets and variables → Actions**, add:

- `PRIVATE_REPO_TOKEN` — a fine-grained token limited to `nitutravels/fintimesnews-automation` with **Contents: Read-only**.

## Privacy rules

Never commit any of the following to this public repository:

- portrait or avatar images;
- narration audio or rendered videos;
- encoded private assets;
- OAuth client credentials or refresh tokens;
- Azure keys;
- personal access tokens.

The connection test decodes the private anchor only inside the temporary GitHub runner and deletes it before the job ends. It creates no downloadable artifact.
