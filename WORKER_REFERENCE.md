# Fintimes Public Worker Reference

This repository contains public automation code only. Private portraits, OAuth credentials, Azure keys and private source files remain outside this repository.

## Current one-off publication

Story file:

`stories/2026-06-25-india-markets.json`

Target workflow:

`.github/workflows/publish-2026-06-25-market.yml`

Expected output video:

`private/output/fintimes_market_2026_06_25_ai_anchor.mp4`

Expected workflow artifact:

`fintimes-25-june-market-publication`

## Build files

- `scripts/build_market_base.sh` — prepares narration, explainer video, branding and thumbnail inputs.
- `scripts/create_safe_brand_package.py` — creates sober intro, disclaimer and outro without depending on private sample media.
- `scripts/create_market_assets.py` — creates the verified studio panel and custom thumbnail.
- `scripts/run_sadtalker_cpu.sh` — installs and runs the free CPU presenter engine.
- `scripts/render_news_presenter.sh` — renders the short talking-presenter segment.
- `scripts/compose_market_video.sh` — overlays the presenter segment onto the full explainer.
- `scripts/finalize_market_metadata.py` — writes the search-focused title, description, chapters, source links, tags and output paths.

## Required Actions secret names

- `PRIVATE_REPO_TOKEN`
- `AZURE_SPEECH_KEY`
- `AZURE_SPEECH_REGION`
- `YOUTUBE_CLIENT_ID`
- `YOUTUBE_CLIENT_SECRET`
- `YOUTUBE_REFRESH_TOKEN`

No secret values belong in source files.

## Privacy rules

The private repository is checked out only inside the temporary runner. Raw portrait, audio and presenter files must be deleted during final cleanup. Publication artifacts may contain the final public video but must not contain the source portrait or credentials.

## Publication verification

Read `youtube_result.json` from the workflow artifact. Confirm:

- upload status;
- video ID and watch URL;
- requested versus actual privacy;
- thumbnail status;
- playlist status, when configured.

Do not assume that a requested public upload is actually public until the result or watch page confirms it.
