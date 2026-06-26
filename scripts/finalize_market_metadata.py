from __future__ import annotations

import argparse
import json
from pathlib import Path


def compact(value: str) -> str:
    return " ".join(str(value).split())


def write_outputs(metadata_path: Path, metadata: dict) -> None:
    metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding="utf-8")
    Path("output/youtube_metadata.txt").write_text(
        "TITLE\n"
        + metadata["title"]
        + "\n\nDESCRIPTION\n"
        + metadata["description"]
        + "\n\nTAGS\n"
        + ", ".join(metadata.get("tags", []))
        + "\n",
        encoding="utf-8",
    )


def finalize_dynamic(metadata: dict, story: dict, edition_label: str) -> None:
    base_title = compact(story.get("title", "Midday Market Explainer"))
    suffix = f" | {edition_label} | Fintimes News"
    if len(base_title) + len(suffix) <= 100:
        title = base_title + suffix
    else:
        title = base_title[: 100 - len(" | Fintimes News")].rstrip(" -|:") + " | Fintimes News"

    description = str(metadata.get("description", "")).strip()
    description += (
        "\n\nFORMAT\nProfessional split-screen Fintimes newsroom with an AI-assisted presenter, "
        "neural narration and explanatory graphics."
    )
    metadata["title"] = title[:100]
    metadata["description"] = description[:5000]


def finalize_static_market_close(metadata: dict, story: dict) -> None:
    old_description = metadata.get("description", "")
    chapters = "00:00 Fintimes News Intro"
    if "CHAPTERS\n" in old_description:
        chapters = old_description.split("CHAPTERS\n", 1)[1].split("\n\nSOURCE", 1)[0].strip()

    lines = [
        "Why did Sensex, Nifty 50 and the Indian rupee rise when crude oil fell? This simple Fintimes News explainer covers the 25 June 2026 market close.",
        "",
        "KEY FACTS",
        "Nifty 50 closed at 24,056, up 0.14%.",
        "Sensex closed at 77,100.47, up 0.14%.",
        "The rupee gained about 0.3% to 94.3950 per US dollar.",
        "Brent crude fell to roughly 72 to 73 US dollars per barrel.",
        "",
        "CHAPTERS",
        chapters,
        "",
        "SOURCES",
        story["source_line"],
        story["source_url"],
        story.get("secondary_source_url", ""),
        "",
        "This video uses an AI-assisted presenter, neural narration and explanatory graphics.",
        story["disclaimer"],
        "",
        "#Sensex #Nifty50 #CrudeOil #IndianRupee #IndiaStockMarket #FintimesNews",
    ]

    metadata["title"] = "Oil Falls, Sensex & Nifty Rise: India Market Close Explained | Fintimes News"
    metadata["description"] = "\n".join(lines)[:5000]
    metadata["tags"] = [
        "India stock market news",
        "Sensex news",
        "Nifty 50 news",
        "crude oil price India",
        "Indian rupee news",
        "India market close",
        "Sensex today explained",
        "Nifty today explained",
        "stock market for beginners",
        "India economy news",
        "financial news India",
        "Fintimes News",
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--story", required=True)
    parser.add_argument("--video", required=True)
    parser.add_argument("--thumbnail", required=True)
    parser.add_argument("--edition-label", default="")
    args = parser.parse_args()

    metadata_path = Path(args.metadata)
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    story = json.loads(Path(args.story).read_text(encoding="utf-8"))

    if args.edition_label:
        finalize_dynamic(metadata, story, args.edition_label)
    else:
        finalize_static_market_close(metadata, story)

    metadata["categoryId"] = "25"
    metadata["defaultLanguage"] = "en"
    metadata["containsSyntheticMedia"] = True
    metadata["thumbnail"] = args.thumbnail
    metadata["video"] = args.video
    write_outputs(metadata_path, metadata)


if __name__ == "__main__":
    main()
