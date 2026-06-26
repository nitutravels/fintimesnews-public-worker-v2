from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def font(size: int, bold: bool = True):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size)


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def card(path: Path, title: str, subtitle: str, accent: tuple[int, int, int], duration: float) -> None:
    image = Image.new("RGB", (W, H), (4, 17, 35))
    draw = ImageDraw.Draw(image)
    for y in range(H):
        p = y / H
        draw.line((0, y, W, y), fill=(4, int(17 + 24 * p), int(35 + 48 * p)))
    draw.rounded_rectangle((80, 95, 1200, 625), radius=38, fill=(5, 27, 53), outline=accent, width=4)
    draw.text((110, 120), "FINTIMES NEWS", font=font(34), fill=(245, 250, 255))
    draw.text((110, 250), title, font=font(54), fill=(245, 250, 255))
    draw.text((110, 340), subtitle, font=font(28, False), fill=(184, 204, 226))
    draw.rectangle((110, 475, 1170, 485), fill=accent)
    draw.text((110, 525), "CLEAR • VERIFIED • EXPLAINED", font=font(24), fill=accent)
    image.save(path, quality=95)


def make_clip(image: Path, output: Path, duration: float, tone: int) -> None:
    run([
        "ffmpeg", "-y",
        "-framerate", "25", "-loop", "1", "-i", str(image),
        "-f", "lavfi", "-i", f"sine=frequency={tone}:sample_rate=48000:duration={duration}",
        "-filter_complex",
        f"[0:v]scale=1280:720,fade=t=in:st=0:d=0.18,fade=t=out:st={max(0.0, duration-0.28):.2f}:d=0.28,format=yuv420p[v];"
        f"[1:a]volume=0.045,afade=t=in:st=0:d=0.18,afade=t=out:st={max(0.0, duration-0.35):.2f}:d=0.35[a]",
        "-map", "[v]", "-map", "[a]", "-t", str(duration),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", str(output),
    ])


def normalise(source: Path, output: Path) -> None:
    run([
        "ffmpeg", "-y", "-i", str(source),
        "-vf", "fps=25,scale=1280:720,format=yuv420p",
        "-af", "aresample=48000",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart", str(output),
    ])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--main-video", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    intro_png = out / "brand_intro_safe.png"
    disclaimer_png = out / "brand_disclaimer_safe.png"
    outro_png = out / "brand_outro_safe.png"
    card(intro_png, "MONEY MOVES FAST.", "We make it make sense.", (54, 222, 238), 4.2)
    card(disclaimer_png, "NEWS & EDUCATION ONLY", "Not investment advice. Markets involve risk.", (244, 193, 79), 2.8)
    card(outro_png, "STAY CURIOUS. STAY AHEAD.", "Subscribe to Fintimes News and turn on the bell.", (72, 211, 139), 5.2)

    intro = out / "brand_intro.mp4"
    disclaimer = out / "brand_disclaimer.mp4"
    outro = out / "brand_outro.mp4"
    make_clip(intro_png, intro, 4.2, 220)
    make_clip(disclaimer_png, disclaimer, 2.8, 196)
    make_clip(outro_png, outro, 5.2, 247)

    main_norm = out / "main_story_safe.mp4"
    normalise(Path(args.main_video), main_norm)

    sources = [intro, disclaimer, main_norm, outro]
    normalised: list[Path] = []
    for index, source in enumerate(sources, start=1):
        target = out / f"safe_part_{index:02d}.mp4"
        normalise(source, target)
        normalised.append(target)

    listing = out / "safe_concat.txt"
    listing.write_text("\n".join(f"file '{item.name}'" for item in normalised), encoding="utf-8")
    final = out / "fintimes_final_16x9.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listing.name,
        "-c", "copy", "-movflags", "+faststart", final.name,
    ], cwd=out, check=True)
    print(final)


if __name__ == "__main__":
    main()
