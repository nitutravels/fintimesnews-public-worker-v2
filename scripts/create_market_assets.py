from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1280, 720


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.exists():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def fit_text(draw: ImageDraw.ImageDraw, text: str, max_width: int, start_size: int, minimum: int = 18) -> ImageFont.FreeTypeFont:
    for size in range(start_size, minimum - 1, -1):
        candidate = load_font(size, True)
        box = draw.textbbox((0, 0), text, font=candidate)
        if box[2] - box[0] <= max_width:
            return candidate
    return load_font(minimum, True)


def gradient_background() -> Image.Image:
    base = Image.new("RGB", (W, H))
    pixels = base.load()
    for y in range(H):
        for x in range(W):
            mix = 0.64 * x / W + 0.36 * y / H
            pixels[x, y] = (int(3 + 10 * mix), int(17 + 30 * mix), int(38 + 52 * mix))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for i in range(8):
        left = 45 + i * 170
        gd.rectangle((left, 75, left + 78, 650), fill=(15, 190, 225, 16))
    return Image.alpha_composite(base.convert("RGBA"), glow.filter(ImageFilter.GaussianBlur(24)))


def rounded(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def create_studio(story: dict, output: Path) -> None:
    image = gradient_background()
    draw = ImageDraw.Draw(image)
    now_ist = datetime.now(ZoneInfo("Asia/Kolkata"))
    published = now_ist.strftime("Published %d %b %Y | %I:%M %p IST")

    draw.rectangle((0, 0, W, 94), fill=(1, 16, 34, 242))
    rounded(draw, (25, 20, 132, 70), 13, (180, 37, 37, 255))
    draw.ellipse((40, 34, 52, 46), fill=(255, 255, 255, 255))
    draw.text((61, 27), "NEWS", font=load_font(24, True), fill=(255, 255, 255, 255))
    draw.text((157, 19), "FINTIMES NEWS", font=load_font(40, True), fill=(246, 250, 255, 255))
    draw.text((750, 31), published, font=load_font(18, True), fill=(72, 220, 232, 255))

    rounded(draw, (30, 112, 660, 625), 22, (3, 26, 54, 225), outline=(42, 192, 222, 255), width=3)
    draw.text((54, 131), "AI NEWS PRESENTER", font=load_font(22, True), fill=(71, 222, 234, 255))
    draw.text((54, 162), "FINTIMES MARKET EXPLAINER", font=load_font(17), fill=(192, 210, 230, 255))

    rounded(draw, (685, 112, 1250, 625), 22, (3, 24, 49, 230), outline=(42, 192, 222, 255), width=3)
    draw.text((715, 136), "MARKET CLOSE • 25 JUNE 2026", font=load_font(20, True), fill=(69, 220, 232, 255))
    headline = "OIL FALLS. INDIA'S MARKETS RISE."
    headline_font = fit_text(draw, headline, 500, 34, 24)
    draw.text((715, 174), headline, font=headline_font, fill=(250, 252, 255, 255))

    cards = [
        ("NIFTY 50", "24,056", "+0.14%"),
        ("SENSEX", "77,100.47", "+0.14%"),
        ("RUPEE", "94.3950 / US$", "+0.3%"),
        ("BRENT CRUDE", "$72–73", "LOWER"),
    ]
    y = 238
    for label, value, change in cards:
        rounded(draw, (714, y, 1220, y + 70), 13, (8, 42, 77, 235), outline=(34, 116, 158, 255), width=2)
        draw.text((735, y + 11), label, font=load_font(17, True), fill=(176, 199, 222, 255))
        draw.text((892, y + 9), value, font=load_font(23, True), fill=(250, 252, 255, 255))
        change_fill = (75, 225, 154, 255) if change != "LOWER" else (80, 221, 232, 255)
        draw.text((1103, y + 13), change, font=load_font(17, True), fill=change_fill, anchor="ma")
        y += 82

    draw.rectangle((0, 625, W, 687), fill=(2, 22, 44, 247))
    draw.rectangle((0, 625, 12, 687), fill=(39, 204, 224, 255))
    draw.text((34, 637), "TOP STORY  |  WHY CHEAPER OIL HELPED INDIA", font=load_font(25, True), fill=(248, 251, 254, 255))
    draw.rectangle((0, 687, W, H), fill=(1, 13, 27, 255))
    draw.text((25, 693), "25 JUNE CLOSE  •  OIL ↓  •  SENSEX ↑  •  NIFTY ↑  •  RUPEE ↑  •  NEWS, NOT ADVICE",
              font=load_font(17, True), fill=(88, 220, 178, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=96)


def create_thumbnail(story: dict, output: Path) -> None:
    image = gradient_background()
    draw = ImageDraw.Draw(image)

    draw.rectangle((0, 0, W, H), fill=(0, 12, 28, 105))
    draw.text((55, 44), "FINTIMES NEWS", font=load_font(42, True), fill=(255, 255, 255, 255))
    rounded(draw, (52, 112, 1228, 609), 30, (1, 20, 43, 226), outline=(46, 208, 228, 255), width=4)

    draw.text((90, 152), "OIL", font=load_font(92, True), fill=(246, 249, 253, 255))
    draw.text((290, 152), "DOWN", font=load_font(92, True), fill=(70, 220, 231, 255))
    draw.polygon([(655, 176), (750, 176), (702, 266)], fill=(72, 223, 155, 255))

    draw.text((90, 290), "INDIA", font=load_font(92, True), fill=(246, 249, 253, 255))
    draw.text((390, 290), "UP?", font=load_font(92, True), fill=(72, 223, 155, 255))
    draw.polygon([(655, 385), (750, 385), (702, 295)], fill=(72, 223, 155, 255))

    draw.text((90, 444), "SENSEX • NIFTY • RUPEE", font=load_font(37, True), fill=(196, 216, 237, 255))
    rounded(draw, (90, 515, 455, 572), 14, (181, 37, 37, 255))
    draw.text((112, 528), "25 JUNE MARKET CLOSE", font=load_font(22, True), fill=(255, 255, 255, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=94)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--story", required=True)
    parser.add_argument("--studio", required=True)
    parser.add_argument("--thumbnail", required=True)
    args = parser.parse_args()

    story = json.loads(Path(args.story).read_text(encoding="utf-8"))
    create_studio(story, Path(args.studio))
    create_thumbnail(story, Path(args.thumbnail))


if __name__ == "__main__":
    main()
