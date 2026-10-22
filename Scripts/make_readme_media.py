#!/usr/bin/env python3
"""Builds the README images from Murmur's UI snapshots.

- docs/demo.gif: dictating a prompt into Claude Code in a terminal. The recording indicator
  frames are Murmur's own SwiftUI views (UISnapshotTests.testRenderDemoHUDFrames); this
  script draws the terminal scene around them and encodes the GIF with ffmpeg and gifsicle.
- docs/settings-*.png: Settings windows (UISnapshotTests.testRenderSettingsWindows) with
  rounded corners and a window shadow, in light and dark appearance.

    TEST_RUNNER_MURMUR_SNAPSHOT_DIR=/tmp/snaps xcodebuild test -project Murmur.xcodeproj \\
        -scheme Murmur -only-testing:MurmurTests/UISnapshotTests
    python3 Scripts/make_readme_media.py /tmp/snaps docs
"""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SCALE = 2                     # scene is drawn at 2x, like the Retina HUD frames
W, H = 880 * SCALE, 480 * SCALE
OUTPUT_WIDTH = 1320             # 1.5x: sharp on Retina screens, still small
FRAME_MS = 80                 # one HUD level sample per frame

TERMINAL_FONTS = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts"
MONO = ImageFont.truetype(f"{TERMINAL_FONTS}/SF-Mono-Regular.otf", 13 * SCALE)
MONO_BOLD = ImageFont.truetype(f"{TERMINAL_FONTS}/SF-Mono-Bold.otf", 13 * SCALE)
SANS = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15 * SCALE)
SANS_SMALL = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 11 * SCALE)
MENLO = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 14 * SCALE)  # has ✻

SENTENCE = "The quick brown fox jumps over the lazy dog."
ORANGE = (215, 119, 87)
TEXT = (230, 230, 230)
DIM = (140, 140, 140)

WINDOW = (36 * SCALE, 22 * SCALE, W - 36 * SCALE, 346 * SCALE)
TITLE_BAR = 28 * SCALE
LINE = 20 * SCALE


def background() -> Image.Image:
    top, bottom = (58, 66, 92), (104, 82, 116)
    gradient = Image.linear_gradient("L").resize((W, H))
    return Image.composite(Image.new("RGB", (W, H), bottom), Image.new("RGB", (W, H), top), gradient)


def terminal(prompt: str, cursor: bool) -> Image.Image:
    left, top, right, bottom = WINDOW
    scene = background()

    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((left, top + 8 * SCALE, right, bottom + 8 * SCALE), 12 * SCALE, fill=120)
    scene.paste((0, 0, 0), (0, 0), shadow.filter(ImageFilter.GaussianBlur(14 * SCALE)))

    draw = ImageDraw.Draw(scene)
    draw.rounded_rectangle(WINDOW, 11 * SCALE, fill=(28, 28, 30), outline=(70, 70, 74), width=1)
    draw.rounded_rectangle((left, top, right, top + TITLE_BAR), 11 * SCALE, fill=(44, 44, 46))
    draw.rectangle((left, top + TITLE_BAR - 12 * SCALE, right, top + TITLE_BAR), fill=(44, 44, 46))
    draw.line((left, top + TITLE_BAR, right, top + TITLE_BAR), fill=(20, 20, 20), width=SCALE)
    for index, color in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx, cy = left + (14 + 20 * index) * SCALE, top + TITLE_BAR // 2
        draw.ellipse((cx - 6 * SCALE, cy - 6 * SCALE, cx + 6 * SCALE, cy + 6 * SCALE), fill=color)
    draw.text(((left + right) / 2, top + TITLE_BAR / 2), "demo — claude", font=SANS_SMALL, fill=(170, 170, 170), anchor="mm")

    x, y = left + 18 * SCALE, top + TITLE_BAR + 16 * SCALE
    draw.text((x, y), "~/code/demo %", font=MONO, fill=(126, 200, 120))
    draw.text((x + draw.textlength("~/code/demo % ", font=MONO), y), "claude", font=MONO, fill=TEXT)

    # Welcome box
    y += LINE * 2
    box_right = x + 330 * SCALE
    draw.rounded_rectangle((x, y, box_right, y + LINE * 3 + 6 * SCALE), 6 * SCALE, outline=ORANGE, width=SCALE)
    draw.text((x + 12 * SCALE, y + 9 * SCALE), "✻", font=MENLO, fill=ORANGE)
    draw.text((x + 32 * SCALE, y + 10 * SCALE), "Welcome to Claude Code!", font=MONO_BOLD, fill=TEXT)
    draw.text((x + 32 * SCALE, y + 10 * SCALE + LINE * 1.5), "cwd: ~/code/demo", font=MONO, fill=DIM)

    # Prompt box
    y += LINE * 5
    draw.rounded_rectangle((x, y, right - 18 * SCALE, y + LINE + 18 * SCALE), 6 * SCALE, outline=(110, 110, 114), width=SCALE)
    text_y = y + 9 * SCALE
    draw.text((x + 12 * SCALE, text_y), ">", font=MONO, fill=TEXT)
    text_x = x + 12 * SCALE + draw.textlength("> ", font=MONO)
    draw.text((text_x, text_y), prompt, font=MONO, fill=TEXT)
    if cursor:
        cursor_x = text_x + draw.textlength(prompt, font=MONO)
        draw.rectangle((cursor_x, text_y - 1 * SCALE, cursor_x + 8 * SCALE, text_y + 17 * SCALE), fill=(200, 200, 200))
    draw.text((x + 12 * SCALE, y + LINE + 26 * SCALE), "? for shortcuts", font=MONO, fill=DIM)
    return scene


def keycap(scene: Image.Image, pressed: bool) -> None:
    """A keystroke overlay in the bottom-left corner: the fn key, held or not."""
    draw = ImageDraw.Draw(scene)
    x, y, size = 36 * SCALE, H - 64 * SCALE, 46 * SCALE  # centred on the HUD
    offset = 3 * SCALE if pressed else 0
    if not pressed:
        draw.rounded_rectangle((x, y + 4 * SCALE, x + size, y + size + 4 * SCALE), 9 * SCALE, fill=(30, 30, 34))
    face = (96, 140, 255) if pressed else (236, 236, 240)
    draw.rounded_rectangle((x, y + offset, x + size, y + size + offset), 9 * SCALE, fill=face)
    draw.text((x + size / 2, y + size / 2 + offset), "fn", font=SANS, fill=(255, 255, 255) if pressed else (40, 40, 44), anchor="mm")
    label = "holding fn" if pressed else "hold fn to talk"
    draw.text((x + size + 12 * SCALE, y + size / 2 + 2 * SCALE), label, font=SANS_SMALL, fill=(235, 235, 240), anchor="lm")


def caption(scene: Image.Image, words: str) -> None:
    """What the speaker is saying, like a video subtitle (the GIF has no sound)."""
    if not words:
        return
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    text = f"“{words}”"
    width = draw.textlength(text, font=SANS)
    cx, cy = W / 2, 378 * SCALE
    draw.rounded_rectangle((cx - width / 2 - 14 * SCALE, cy - 15 * SCALE, cx + width / 2 + 14 * SCALE, cy + 15 * SCALE), 15 * SCALE, fill=(0, 0, 0, 120))
    draw.text((cx, cy), text, font=SANS, fill=(255, 255, 255, 255), anchor="mm")
    scene.paste(overlay, (0, 0), overlay)


def hud(scene: Image.Image, frame: Image.Image) -> None:
    # The HUD sits at the bottom centre of the screen, 14 pt above the edge.
    padding = 24 * SCALE
    capsule_bottom = H - 14 * SCALE
    x = (W - frame.width) // 2
    y = capsule_bottom - frame.height + padding
    scene.paste(frame, (x, y), frame)


def build_frames(snapshots: str) -> list[tuple[Image.Image, int]]:
    hud_frames = sorted(name for name in os.listdir(snapshots) if name.startswith("demo-hud-") and name[9:11].isdigit())
    recording = [Image.open(os.path.join(snapshots, name)).convert("RGBA") for name in hud_frames]
    processing = Image.open(os.path.join(snapshots, "demo-hud-processing.png")).convert("RGBA")
    words = SENTENCE.split()

    frames = []

    def add(image: Image.Image, ms: int) -> None:
        frames.append((image, ms))

    # Idle, cursor blinking.
    for cursor in (True, False):
        scene = terminal("", cursor)
        keycap(scene, pressed=False)
        add(scene, 600)

    # fn held: recording starts at once, the indicator appears after 0.25 s.
    scene = terminal("", True)
    keycap(scene, pressed=True)
    add(scene, 250)

    for index, hud_frame in enumerate(recording):
        spoken = min(len(words), max(0, (index - 1) * len(words) // (len(recording) - 6)))
        scene = terminal("", True)
        keycap(scene, pressed=True)
        caption(scene, " ".join(words[:spoken]))
        hud(scene, hud_frame)
        add(scene, FRAME_MS)

    # Released: transcribing.
    scene = terminal("", True)
    keycap(scene, pressed=False)
    hud(scene, processing)
    add(scene, 900)

    # Pasted into the prompt.
    for cursor in (True, False, True, False, True):
        scene = terminal(SENTENCE, cursor)
        keycap(scene, pressed=False)
        add(scene, 600)
    return frames


def encode(frames: list[tuple[Image.Image, int]], output: str) -> None:
    with tempfile.TemporaryDirectory() as work:
        listing = []
        for index, (image, ms) in enumerate(frames):
            path = os.path.join(work, f"{index:03d}.png")
            image.resize((OUTPUT_WIDTH, OUTPUT_WIDTH * H // W), Image.LANCZOS).save(path)
            listing.append(f"file '{path}'\nduration {ms / 1000}")
        listing.append(f"file '{os.path.join(work, f'{len(frames) - 1:03d}.png')}'")
        with open(os.path.join(work, "frames.txt"), "w") as handle:
            handle.write("\n".join(listing) + "\n")

        subprocess.run([
            "ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", os.path.join(work, "frames.txt"),
            "-vf", "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
            "-loop", "0", os.path.join(work, "raw.gif"),
        ], check=True)
        if shutil.which("gifsicle"):
            subprocess.run(["gifsicle", "-O3", "--lossy=30", os.path.join(work, "raw.gif"), "-o", output], check=True)
        else:
            shutil.copy(os.path.join(work, "raw.gif"), output)


def frame_window(source: str, output: str, dark: bool) -> None:
    """Rounds the window corners and adds a hairline edge and a soft shadow, like ⌘⇧4 Space."""
    shot = Image.open(source).convert("RGBA")
    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), 10 * SCALE, fill=255)
    shot.putalpha(mask)
    edge = (255, 255, 255, 40) if dark else (0, 0, 0, 40)
    ImageDraw.Draw(shot).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), 10 * SCALE, outline=edge, width=1)

    pad = 28 * SCALE
    canvas = Image.new("RGBA", (shot.width + 2 * pad, shot.height + 2 * pad), (0, 0, 0, 0))
    shadow_mask = Image.new("L", canvas.size, 0)
    shadow_mask.paste(mask.point(lambda v: int(v * 0.45)), (pad, pad + 8 * SCALE))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(12 * SCALE)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(shot, (pad, pad))
    canvas.save(output, optimize=True)


def main() -> None:
    snapshots, docs = sys.argv[1], sys.argv[2]
    os.makedirs(docs, exist_ok=True)

    gif = os.path.join(docs, "demo.gif")
    encode(build_frames(snapshots), gif)
    print(f"wrote {gif} ({os.path.getsize(gif) // 1024} KB)")

    for tab in ("general", "modes", "openAI"):
        for appearance in ("light", "dark"):
            output = os.path.join(docs, f"settings-{tab.lower()}-{appearance}.png")
            frame_window(os.path.join(snapshots, f"window-{tab}-{appearance}.png"), output, appearance == "dark")
            print(f"wrote {output} ({os.path.getsize(output) // 1024} KB)")


if __name__ == "__main__":
    main()
