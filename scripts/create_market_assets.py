from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFilter, ImageFont

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


def rounded(draw: ImageDraw.ImageDraw, box, radius: int, fill, outline=None, width: int = 1) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)


def vertical_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(image)
    for y in range(H):
        p = y / max(1, H - 1)
        colour = tuple(int(top[i] * (1 - p) + bottom[i] * p) for i in range(3))
        draw.line((0, y, W, y), fill=colour)
    return image


def add_glow(base: Image.Image, box, colour, blur: int) -> Image.Image:
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.ellipse(box, fill=colour)
    return Image.alpha_composite(base.convert("RGBA"), layer.filter(ImageFilter.GaussianBlur(blur)))


def create_studio(story: dict, output: Path) -> None:
    image = vertical_gradient((2, 9, 22), (6, 31, 59)).convert("RGBA")
    image = add_glow(image, (-160, -100, 620, 500), (18, 180, 220, 70), 90)
    image = add_glow(image, (770, -80, 1450, 470), (29, 98, 230, 55), 110)
    draw = ImageDraw.Draw(image)

    # Ceiling architecture and studio lighting.
    for offset, alpha in ((0, 180), (18, 105), (36, 60)):
        draw.arc((70 - offset, -155 - offset, 1210 + offset, 235 + offset), 7, 173, fill=(68, 217, 235, alpha), width=4)
    for x in (90, 305, 520, 735, 950, 1165):
        draw.polygon([(x - 60, 0), (x + 35, 0), (x + 5, 150), (x - 28, 150)], fill=(35, 121, 157, 34))
        draw.line((x - 12, 6, x - 25, 132), fill=(108, 231, 239, 140), width=3)

    # Rear wall columns.
    for x in range(0, W, 155):
        draw.rectangle((x, 92, x + 9, 485), fill=(18, 92, 135, 100))
        draw.rectangle((x + 12, 92, x + 16, 485), fill=(70, 210, 231, 55))

    # Floor with perspective and reflections.
    horizon = 470
    draw.rectangle((0, horizon, W, H), fill=(3, 16, 32, 245))
    for x in range(-200, W + 220, 105):
        draw.line((W // 2, horizon, x, H), fill=(29, 92, 126, 120), width=2)
    for y in (495, 525, 560, 603, 655):
        draw.line((0, y, W, y), fill=(21, 80, 111, 105), width=2)
    draw.ellipse((85, 508, 610, 720), fill=(25, 191, 219, 25))
    draw.ellipse((650, 505, 1270, 720), fill=(37, 86, 225, 20))

    # Header bar.
    rounded(draw, (28, 20, 1252, 78), 20, (1, 15, 34, 225), outline=(48, 187, 218, 180), width=2)
    rounded(draw, (46, 31, 149, 67), 11, (187, 39, 48, 255))
    draw.ellipse((61, 43, 71, 53), fill=(255, 255, 255, 255))
    draw.text((82, 35), "LIVE", font=load_font(20, True), fill=(255, 255, 255, 255))
    draw.text((172, 28), "FINTIMES NEWS", font=load_font(34, True), fill=(247, 251, 255, 255))
    draw.text((172, 58), "INDIA MARKET CLOSE", font=load_font(14, True), fill=(72, 220, 234, 255))
    now_ist = datetime.now(ZoneInfo("Asia/Kolkata"))
    draw.text((1210, 40), now_ist.strftime("%d %b %Y  •  %I:%M %p IST"), font=load_font(16, True), fill=(184, 207, 229, 255), anchor="ra")

    # Presenter stage: wide and intentionally spacious.
    rounded(draw, (42, 102, 600, 596), 28, (2, 19, 41, 185), outline=(44, 190, 218, 205), width=3)
    draw.rectangle((66, 130, 575, 142), fill=(24, 101, 139, 130))
    draw.text((72, 158), "FINTIMES STUDIO", font=load_font(20, True), fill=(82, 223, 235, 255))
    draw.text((72, 187), "AI-ASSISTED PRESENTER", font=load_font(14, True), fill=(176, 200, 223, 255))
    draw.arc((95, 210, 547, 620), 196, 344, fill=(55, 218, 233, 110), width=4)
    draw.arc((122, 238, 520, 590), 198, 342, fill=(40, 103, 211, 90), width=3)

    # Curved market LED wall.
    rounded(draw, (630, 101, 1248, 596), 30, (2, 16, 39, 238), outline=(46, 199, 225, 220), width=3)
    rounded(draw, (651, 121, 1227, 575), 24, (5, 31, 63, 245), outline=(39, 109, 163, 190), width=2)
    draw.text((680, 143), "MARKET CLOSE • 25 JUNE 2026", font=load_font(18, True), fill=(76, 223, 235, 255))
    headline = "OIL FALLS. INDIA'S MARKETS RISE."
    headline_font = fit_text(draw, headline, 500, 32, 22)
    draw.text((680, 178), headline, font=headline_font, fill=(250, 252, 255, 255))

    # Chart area.
    rounded(draw, (676, 231, 1200, 364), 16, (2, 20, 45, 235), outline=(29, 88, 132, 180), width=2)
    chart_points = [(700, 330), (750, 305), (805, 316), (860, 278), (925, 286), (990, 248), (1055, 263), (1125, 219), (1177, 235)]
    for gy in range(250, 351, 25):
        draw.line((694, gy, 1184, gy), fill=(33, 76, 110, 90), width=1)
    draw.line(chart_points, fill=(73, 224, 158, 255), width=5)
    for x, y in chart_points:
        draw.ellipse((x - 4, y - 4, x + 4, y + 4), fill=(232, 255, 244, 255))
    draw.text((699, 241), "INDIA MARKET MOMENTUM", font=load_font(14, True), fill=(174, 202, 226, 255))

    cards = [
        ("NIFTY 50", "24,056", "+0.14%"),
        ("SENSEX", "77,100.47", "+0.14%"),
        ("RUPEE", "94.3950 / US$", "+0.3%"),
        ("BRENT", "$72–73", "LOWER"),
    ]
    x_positions = (676, 941)
    y_positions = (389, 477)
    index = 0
    for y in y_positions:
        for x in x_positions:
            label, value, change = cards[index]
            rounded(draw, (x, y, x + 244, y + 72), 14, (6, 38, 72, 245), outline=(31, 112, 157, 210), width=2)
            draw.text((x + 16, y + 10), label, font=load_font(13, True), fill=(170, 196, 221, 255))
            draw.text((x + 16, y + 31), value, font=load_font(19, True), fill=(250, 252, 255, 255))
            change_colour = (76, 225, 155, 255) if change != "LOWER" else (76, 221, 233, 255)
            draw.text((x + 225, y + 48), change, font=load_font(13, True), fill=change_colour, anchor="ra")
            index += 1

    # Bottom news strip.
    draw.rectangle((0, 624, W, 684), fill=(1, 17, 36, 248))
    draw.rectangle((0, 624, 15, 684), fill=(52, 218, 234, 255))
    draw.text((35, 637), "TOP STORY", font=load_font(18, True), fill=(73, 223, 235, 255))
    draw.text((172, 633), "WHY CHEAPER OIL HELPED INDIA'S MARKETS", font=load_font(25, True), fill=(249, 252, 255, 255))
    draw.rectangle((0, 684, W, H), fill=(1, 11, 24, 255))
    draw.text((28, 692), "OIL ↓   •   SENSEX ↑   •   NIFTY ↑   •   RUPEE ↑   •   VERIFIED NEWS   •   NOT INVESTMENT ADVICE", font=load_font(15, True), fill=(99, 224, 181, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=96)


def create_foreground(output: Path) -> None:
    image = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Curved glass-and-metal anchor desk, placed in front of the presenter.
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((70, 500, 615, 720), fill=(0, 0, 0, 145))
    shadow = shadow.filter(ImageFilter.GaussianBlur(20))
    image = Image.alpha_composite(image, shadow)
    draw = ImageDraw.Draw(image)

    draw.polygon([(88, 488), (575, 488), (630, 610), (38, 610)], fill=(6, 22, 44, 245), outline=(66, 214, 232, 230))
    draw.polygon([(108, 505), (555, 505), (580, 561), (83, 561)], fill=(15, 66, 97, 225))
    draw.line((103, 505, 559, 505), fill=(142, 242, 248, 240), width=4)
    draw.line((79, 563, 585, 563), fill=(42, 153, 184, 220), width=3)
    rounded(draw, (210, 526, 455, 583), 16, (2, 18, 37, 245), outline=(62, 210, 229, 230), width=2)
    draw.text((332, 554), "FINTIMES NEWS", font=load_font(23, True), fill=(247, 251, 255, 255), anchor="mm")
    draw.rectangle((65, 592, 605, 613), fill=(2, 11, 24, 250))
    draw.text((92, 594), "AI NEWS PRESENTER", font=load_font(14, True), fill=(75, 223, 235, 255))

    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)


def create_thumbnail(story: dict, output: Path) -> None:
    image = vertical_gradient((2, 9, 22), (7, 34, 64)).convert("RGBA")
    image = add_glow(image, (-120, 80, 660, 780), (28, 192, 219, 75), 95)
    draw = ImageDraw.Draw(image)

    rounded(draw, (44, 38, 1236, 682), 34, (1, 17, 38, 225), outline=(48, 207, 227, 230), width=4)
    draw.text((76, 65), "FINTIMES NEWS", font=load_font(38, True), fill=(255, 255, 255, 255))
    rounded(draw, (955, 58, 1188, 105), 14, (185, 39, 48, 255))
    draw.text((1072, 82), "25 JUNE CLOSE", font=load_font(18, True), fill=(255, 255, 255, 255), anchor="mm")

    draw.text((82, 155), "OIL", font=load_font(96, True), fill=(246, 250, 255, 255))
    draw.text((295, 155), "DOWN", font=load_font(96, True), fill=(74, 222, 234, 255))
    draw.polygon([(726, 178), (819, 178), (772, 278)], fill=(77, 225, 158, 255))

    draw.text((82, 310), "INDIA", font=load_font(92, True), fill=(246, 250, 255, 255))
    draw.text((393, 310), "UP?", font=load_font(92, True), fill=(77, 225, 158, 255))
    draw.polygon([(725, 442), (818, 442), (772, 342)], fill=(77, 225, 158, 255))

    rounded(draw, (846, 150, 1187, 532), 24, (5, 31, 63, 235), outline=(38, 144, 184, 220), width=3)
    points = [(875, 455), (922, 410), (968, 427), (1015, 358), (1060, 379), (1110, 290), (1155, 315)]
    draw.line(points, fill=(76, 225, 158, 255), width=7)
    for x, y in points:
        draw.ellipse((x - 6, y - 6, x + 6, y + 6), fill=(242, 255, 248, 255))
    draw.text((1016, 184), "MARKET", font=load_font(25, True), fill=(184, 208, 232, 255), anchor="ma")
    draw.text((1016, 222), "EXPLAINED", font=load_font(28, True), fill=(77, 222, 234, 255), anchor="ma")

    draw.text((82, 505), "SENSEX • NIFTY • RUPEE", font=load_font(34, True), fill=(198, 218, 238, 255))
    rounded(draw, (82, 570, 640, 625), 14, (8, 42, 77, 245), outline=(70, 218, 233, 220), width=2)
    draw.text((361, 598), "WHY CHEAPER OIL HELPED INDIA", font=load_font(21, True), fill=(255, 255, 255, 255), anchor="mm")

    output.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(output, quality=95)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--story", required=True)
    parser.add_argument("--studio", required=True)
    parser.add_argument("--thumbnail", required=True)
    args = parser.parse_args()

    story = json.loads(Path(args.story).read_text(encoding="utf-8"))
    studio = Path(args.studio)
    create_studio(story, studio)
    create_foreground(studio.with_name("anchor_studio_foreground.png"))
    create_thumbnail(story, Path(args.thumbnail))


if __name__ == "__main__":
    main()
