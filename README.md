# Fintimes News Public Worker v2

Privacy-safe cloud rendering and YouTube publishing support for Fintimes News.

The permanent editorial schedule, source selection and story archive live in the private `nitutravels/fintimesnews-automation` repository. This public worker contains reusable rendering code and publication-recovery workflows. Private portraits, credentials, narration assets and unpublished source material must never be committed here.

## Production format

Every finished video contains:

1. Cinematic 3D-style Fintimes News introduction with original music
2. Animated financial-news disclaimer
3. Child-friendly main explainer covering what happened, why, the current effect, possible future impact, and pros and cons
4. Branded subscription and notification outro
5. Custom thumbnail, chapters, source attribution, tags and synthetic-media disclosure

## Publishing schedule

GitHub Actions schedules use UTC. The production timetable in India time is:

- Monday-Friday, 08:00 IST: Morning Economy Brief
- Monday-Friday, 11:30 IST: Midday Market Explainer
- Monday-Friday, 16:15 IST: Market Close Explainer
- Monday-Friday, 20:30 IST: Evening Money Explained
- Sunday, 18:00 IST: Consolidated Weekly Wrap

Manual runs can select any edition from the private automation repository's Actions tab.

## Automation stack

- GitHub Actions cloud runners
- GitHub Models for structured scripts
- Azure Speech `en-IN-NeerjaNeural` in newscast style
- Pillow and FFmpeg for graphics, animation, music and rendering
- YouTube Data API for upload, metadata, thumbnail and playlist insertion

## Editorial rules

- Use traceable attributed source material
- Avoid recently used source URLs and titles
- Explain the story in language understandable to an eight-year-old
- Separate confirmed facts from possible future effects
- Include balanced pros and cons where applicable
- No investment recommendations
- Label AI-assisted narration and explanatory graphics

## Production secrets

The private production repository requires:

- `AZURE_SPEECH_KEY`
- `AZURE_SPEECH_REGION`
- `YOUTUBE_CLIENT_ID`
- `YOUTUBE_CLIENT_SECRET`
- `YOUTUBE_REFRESH_TOKEN`

A public-worker workflow that checks out private production files also requires:

- `PRIVATE_REPO_TOKEN` — a fine-grained token restricted to `nitutravels/fintimesnews-automation`; grant only the minimum repository permissions needed by that workflow.

## Optional repository variables

- `YOUTUBE_PLAYLIST_ID`
- `YOUTUBE_MADE_FOR_KIDS`
- `YOUTUBE_NOTIFY_SUBSCRIBERS`

Workflows request public uploads. YouTube can still force API uploads to private when the API project has not completed the required compliance audit.

## Story archive

Each successfully published weekday edition is saved under `archive/YYYY-MM-DD/` in the private repository. The archive prevents duplicate stories and supplies the Sunday consolidated weekly wrap. Failed or skipped uploads are not added to publication history.

## Privacy rules

Never commit any of the following to this public repository:

- portrait or avatar images;
- narration audio or rendered videos;
- encoded private assets;
- OAuth client credentials or refresh tokens;
- Azure keys;
- personal access tokens.

Temporary private files must be deleted from the GitHub runner after every job, including failed jobs.
