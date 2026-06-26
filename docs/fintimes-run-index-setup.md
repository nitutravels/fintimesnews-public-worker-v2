# Fintimes Run Index Setup

`scripts/fintimes_run_index.js` generates `docs/fintimes-run-index.json` and `docs/fintimes-run-index.md` by calling the GitHub Actions REST API from inside GitHub Actions.

The ChatGPT GitHub connector can fetch repository files, so these generated index files solve the limitation where the connector cannot directly list latest workflow runs.

Activation: run the script from an existing scheduled workflow with Actions read permission and Contents write permission, then commit the two generated files when they change.

The generated JSON contains edition, scheduled time, repository, workflow name, run URL, production stage, failed step, produced assets, YouTube status, video ID, watch URL, privacy, thumbnail result, playlist result and visual-check evidence fields.
