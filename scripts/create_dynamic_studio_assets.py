from __future__ import annotations

import argparse
import json
import textwrap
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1280, 720


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size=size)
    return ImageFont.load_default()


def rounded(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def gradient() -> Image.Image:
    image = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(image)
    for y in range(H):
        p = y / max(H - 1, 1)
        draw.line(
            (0, y, W, y),
            fill=(int(2 + 5 * p), int(9 + 26 * p), int(24 + 42 * p)),
        )
    return image.convert("RGBA")


def add_glow(image: Image.Image, box, colour, blur: int) -> Image.Image:
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(box, fill=colour)
    return Image.alpha_composite(image, layer.filter(ImageFilter.GaussianBlur(blur)))


def fit_lines(draw: ImageDraw.ImageDraw, text: str, max_width: int, start_size: int, max_lines: int = 3):
    clean = " ".join(text.split())
    for size in range(start_size, 19, -1):
        chosen = font(size, True)
        approx = max(12, int(max_width / max(size * 0.58, 1)))
        lines = textwrap.wrap(clean, width=approx)
        if len(lines) <= max_lines and all(draw.textbbox((0, 0), line, font=chosen)[2] <= max_width for line in lines):
            return chosen, lines
    return font(20, True), textwrap.wrap(clean, width=34)[:max_lines]


def scene_labels(story: dict) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for scene in story.get("scenes", [])[:4]:
        heading = str(scene.get("heading", "Key point")).strip()
        badge = str(scene.get("badge", "EXPLAINED")).strip()
        result.append((heading, badge))
    while len(result) < 4:
        result.append(("What this means", "EXPLAINED"))
    return result


def create_studio(story: dict, output: Path, edition_label: str) -> None:
    image = gradient()
    image = add_glow(image, (-180, -120, 620, 520), (17, 183, 222, 78), 100)
    image = add_glow(image, (760, -100, 1450, 500), (40, 93, 232, 58), 115)
    draw = ImageDraw.Draw(image)

    # Curved ceiling and architectural light ribs.
    for offset, alpha in ((0, 200), (20, 115), (40, 65)):
        draw.arc((55 - offset, -170 - offset, 1225 + offset, 235 + offset), 7, 173, fill=(74, 222, 238, alpha), width=4)
    for x in (95, 310, 525, 740, 955, 1170):
        draw.polygon([(x - 64, 0), (x + 42, 0), (x + 6, 160), (x - 32, 160)], fill=(38, 135, 176, 35))
        draw.line((x - 12, 6, x - 27, 140), fill=(111, 236, 244, 145), width=3)

    # Rear studio wall and perspective floor.
    for x in range(0, W, 155):
        draw.rectangle((x, 90, x + 10, 480), fill=(18, 94, 139, 105))
        draw.rectangle((x + 14, 90, x + 18, 480), fill=(72, 216, 235, 58))
    horizon = 474
    draw.rectangle((0, horizon, W, H), fill=(3, 16, 33, 248))
    for x in range(-240, W + 260, 110):
        draw.line((W // 2, horizon, x, H), fill=(31, 96, 132, 118), width=2)
    for y in (500, 530, 567, 612, 665):
        draw.line((0, y, W, y), fill=(23, 84, 116, 110), width=2)
    draw.ellipse((60, 510, 620, 730), fill=(27, 195, 225, 28))
    draw.ellipse((625, 505, 1270, 730), fill=(41, 93, 235, 22))

    # Header.
    rounded(draw, (28, 20, 1252, 80), 20, (1, 15, 34, 230), outline=(51, 193, 220, 185), width=2)
    rounded(draw, (46, 31, 151, 69), 11, (188, 39, 49, 255))
    draw.ellipse((61, 44, 72, 55), fill=(255, 255, 255, 255))
    draw.text((83, 35), "LIVE", font=font(20, True), fill=(255, 255, 255, 255))
    draw.text((174, 27), "FINTIMES NEWS", font=font(34, True), fill=(248, 252, 255, 255))
    draw.text((174, 58), edition_label.upper(), font=font(14, True), fill=(74, 222, 235, 255))
    now = datetime.now(ZoneInfo("Asia/Kolkata"))
    draw.text((1210, 41), now.strftime("%d %b %Y  •  %I:%M %p IST"), font=font(16, True), fill=(184, 207, 230, 255), anchor="ra")

    # Spacious presenter stage.
    rounded(draw, (42, 102, 600, 596), 28, (2, 19, 41, 188), outline=(47, 196, 221, 210), width=3)
    draw.rectangle((66, 130, 575, 143), fill=(25, 105, 145, 135))
    draw.text((72, 158), "FINTIMES STUDIO", font=font(20, True), fill=(84, 227, 238, 255))
    draw.text((72, 188), "AI-ASSISTED PRESENTER", font=font(14, True), fill=(179, 203, 226, 255))
    draw.arc((95, 210, 547, 620), 196, 344, fill=(58, 220, 236, 115), width=4)
    draw.arc((122, 238, 520, 590), 198, 342, fill=(42, 108, 218, 95), width=3)

    # Curved LED wall with verified story content.
    rounded(draw, (630, 101, 1248, 596), 30, (2, 16, 39, 240), outline=(48, 204, 229, 225), width=3)
    rounded(draw, (651, 121, 1227, 575), 24, (5, 31, 63, 247), outline=(40, 112, 168, 195), width=2)
    draw.text((680, 142), edition_label.upper(), font=font(18, True), fill=(78, 226, 238, 255))

    title_font, title_lines = fit_lines(draw, story.get("title", "Midday market update"), 500, 34, 3)
    ty = 176
    for line in title_lines:
        draw.text((680, ty), line, font=title_font, fill=(250, 252, 255, 255))
        ty += title_font.size + 4

    rounded(draw, (676, 275, 1200, 365), 16, (2, 20, 45, 238), outline=(30, 90, 136, 185), width=2)
    subtitle_font, subtitle_lines = fit_lines(draw, story.get("subtitle", "What happened, why it matters and what may happen next."), 470, 22, 3)
    sy = 293
    for line in subtitle_lines:
        draw.text((700, sy), line, font=subtitle_font, fill=(191, 215, 236, 255))
        sy += subtitle_font.size + 3

    labels = scene_labels(story)
    positions = [(676, 390), (941, 390), (676, 478), (941, 478)]
    for (heading, badge), (x, y) in zip(labels, positions):
        rounded(draw, (x, y, x + 244, y + 72), 14, (6, 38, 72, 247), outline=(32, 116, 162, 215), width=2)
        short = " ".join(heading.split())
        short_font, short_lines = fit_lines(draw, short, 205, 17, 2)
        ly = y + 10
        for line in short_lines:
            draw.text((x + 15, ly), line, font=short_font, fill=(249, 252, 255, 255))
            ly += short_font.size + 1
        draw.text((x + 225, y + 57), badge[:18].upper(), font=font(11, True), fill=(77, 226, 160, 255), anchor="ra")

    # News strap and source ticker.
    draw.rectangle((0, 624, W, 684), fill=(1, 17, 36, 250))
    draw.rectangle((0, 624, 15, 684), fill=(54, 221, 237, 255))
    draw.text((35, 637), "TOP STORY", font=font(18, True), fill=(76, 226, 238, 255))
    strap_font, strap_lines = fit_lines(draw, story.get("thumbnail_text", story.get("title", "MIDDAY UPDATE")), 850, 25, 1)
    draw.text((172, 634), strap_lines[0], font=strap_font, fill=(249, 252, 255, 255))
    draw.rectangle((0, 684, W, H), fill=(1, 11, 24, 255))
    source = str(story.get("source_line", "Verified official source"))
    draw.text((28, 692), (source + "   •   NEWS, NOT INVESTMENT ADVICE")[:150], font=font(14, True), fill=(101, 227, 184, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=96)


def create_foreground(output: Path) -> None:
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((70, 500, 615, 720), fill=(0, 0, 0, 150))
    image = Image.alpha_composite(image, shadow.filter(ImageFilter.GaussianBlur(20)))
    draw = ImageDraw.Draw(image)

    draw.polygon([(88, 488), (575, 488), (630, 610), (38, 610)], fill=(6, 22, 44, 247), outline=(69, 220, 238, 235))
    draw.polygon([(108, 505), (555, 505), (580, 561), (83, 561)], fill=(15, 66, 97, 228))
    draw.line((103, 505, 559, 505), fill=(145, 245, 250, 245), width=4)
    draw.line((79, 563, 585, 563), fill=(44, 159, 190, 225), width=3)
    rounded(draw, (210, 526, 455, 583), 16, (2, 18, 37, 247), outline=(65, 217, 235, 235), width=2)
    draw.text((332, 554), "FINTIMES NEWS", font=font(23, True), fill=(248, 252, 255, 255), anchor="mm")
    draw.rectangle((65, 592, 605, 613), fill=(2, 11, 24, 252))
    draw.text((92, 594), "AI NEWS PRESENTER", font=font(14, True), fill=(78, 226, 238, 255))
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)


def create_thumbnail(story: dict, output: Path, edition_label: str) -> None:
    image = gradient()
    image = add_glow(image, (-140, 60, 670, 790), (28, 195, 224, 78), 100)
    draw = ImageDraw.Draw(image)
    rounded(draw, (44, 38, 1236, 682), 34, (1, 17, 38, 228), outline=(50, 212, 232, 235), width=4)
    draw.text((76, 65), "FINTIMES NEWS", font=font(38, True), fill=(255, 255, 255, 255))
    rounded(draw, (930, 58, 1190, 106), 14, (185, 39, 48, 255))
    draw.text((1060, 82), edition_label.upper(), font=font(17, True), fill=(255, 255, 255, 255), anchor="mm")

    headline = story.get("thumbnail_text") or story.get("title", "MIDDAY MARKET UPDATE")
    title_font, lines = fit_lines(draw, headline.upper(), 770, 74, 4)
    y = 175
    for index, line in enumerate(lines):
        colour = (248, 252, 255, 255) if index % 2 == 0 else (78, 226, 238, 255)
        draw.text((82, y), line, font=title_font, fill=colour)
        y += title_font.size + 8

    rounded(draw, (860, 160, 1185, 525), 24, (5, 31, 63, 238), outline=(39, 149, 190, 225), width=3)
    points = [(890, 455), (934, 417), (980, 428), (1025, 365), (1070, 382), (1115, 302), (1155, 320)]
    draw.line(points, fill=(78, 228, 162, 255), width=7)
    for x, py in points:
        draw.ellipse((x - 6, py - 6, x + 6, py + 6), fill=(243, 255, 249, 255))
    draw.text((1022, 195), "WHY IT", font=font(26, True), fill=(188, 212, 236, 255), anchor="ma")
    draw.text((1022, 232), "MATTERS", font=font(30, True), fill=(80, 226, 239, 255), anchor="ma")

    subtitle_font, subtitle_lines = fit_lines(draw, story.get("subtitle", "Explained simply"), 740, 25, 2)
    sy = 540
    for line in subtitle_lines:
        draw.text((82, sy), line, font=subtitle_font, fill=(201, 220, 239, 255))
        sy += subtitle_font.size + 4

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=95)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--story", required=True)
    parser.add_argument("--studio", required=True)
    parser.add_argument("--foreground", required=True)
    parser.add_argument("--thumbnail", required=True)
    parser.add_argument("--edition-label", default="Midday Market Explainer")
    args = parser.parse_args()

    story = json.loads(Path(args.story).read_text(encoding="utf-8"))
    create_studio(story, Path(args.studio), args.edition_label)
    create_foreground(Path(args.foreground))
    create_thumbnail(story, Path(args.thumbnail), args.edition_label)


if __name__ == "__main__":
    main()
