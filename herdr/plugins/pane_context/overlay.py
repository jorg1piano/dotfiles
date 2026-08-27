#!/usr/bin/env python3
"""Draw a pane's current-work summary across the top of the pane.

Herdr composites pane graphics itself on every frame, so the image survives the
agent TUI repainting underneath it and stays put until it is replaced or cleared.

    overlay.py <pane_id> <text>
    overlay.py <pane_id> --clear

Exits non-zero with a one-line reason when the overlay cannot be drawn; the
caller has already stored the summary as a metadata token by then, so a failure
here costs the strip and nothing else.
"""

import base64
import io
import json
import os
import socket
import sys

FONT_CANDIDATES = [
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]
BG = (30, 30, 46, 255)       # catppuccin base
FG = (166, 173, 200, 255)    # subtext
EDGE = (69, 71, 90, 255)     # surface1
INSET_CELLS = 1              # cells of empty space before the text starts


class Herdr:
    """One request per connection.

    The server closes the socket once it has answered, so a connection kept for a
    second call fails on write with EPIPE rather than returning anything.
    """

    def __init__(self):
        self.path = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser(
            "~/.config/herdr/herdr.sock"
        )

    def call(self, method, params):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(self.path)
        try:
            sock.sendall(
                (json.dumps({"id": method, "method": method, "params": params}) + "\n").encode()
            )
            chunks = []
            while b"\n" not in b"".join(chunks):
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            sock.close()
        line = b"".join(chunks).split(b"\n", 1)[0]
        if not line:
            raise RuntimeError(f"{method}: no response")
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error'].get('message', reply['error'])}")
        return reply.get("result", {})


def find_font(size):
    from PIL import ImageFont

    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def pane_cols(layout, pane_id):
    for pane in layout.get("layout", {}).get("panes", []):
        if pane.get("pane_id") == pane_id:
            return pane.get("rect", {}).get("width")
    return None


def render(text, cell_w, cell_h, cols):
    """Return (png_bytes, width_px, height_px, cols) for a full-width strip.

    The strip spans the pane exactly, so the placement never runs past the right
    edge and gets clipped. Text is left-aligned; only its tail is ever lost.
    """
    from PIL import Image, ImageDraw

    font = find_font(max(8, int(cell_h * 0.62)))
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))

    width_px, height_px = cols * cell_w, cell_h
    budget_px = width_px - 2 * INSET_CELLS * cell_w
    while text and probe.textbbox((0, 0), text, font=font)[2] > budget_px:
        text = text[:-2] + "\u2026" if len(text) > 2 else ""
    if not text:
        raise RuntimeError("pane too narrow for a summary strip")

    image = Image.new("RGBA", (width_px, height_px), BG)
    canvas = ImageDraw.Draw(image)
    canvas.rectangle([(0, 0), (width_px - 1, height_px - 1)], outline=EDGE)
    bbox = canvas.textbbox((0, 0), text, font=font)
    canvas.text(
        (INSET_CELLS * cell_w, (height_px - bbox[3]) // 2), text, font=font, fill=FG
    )

    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue(), width_px, height_px, cols


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: overlay.py <pane_id> <text>|--clear")
    pane_id, text = sys.argv[1], sys.argv[2]

    herdr = Herdr()
    if text == "--clear":
        herdr.call("pane.graphics.clear", {"pane_id": pane_id})
        return

    info = herdr.call("pane.graphics.info", {"pane_id": pane_id})
    cell_w = info.get("cell_width_px")
    cell_h = info.get("cell_height_px")
    if not cell_w or not cell_h:
        raise RuntimeError("host cell size unavailable; re-attach the Herdr client")

    cols = pane_cols(herdr.call("pane.layout", {"pane_id": pane_id}), pane_id)
    if not cols:
        raise RuntimeError(f"no layout rect for {pane_id}")

    png, width_px, height_px, cells = render(text, cell_w, cell_h, cols)
    herdr.call(
        "pane.graphics.set",
        {
            "pane_id": pane_id,
            "format": "png",
            "image_width": width_px,
            "image_height": height_px,
            "data_base64": base64.b64encode(png).decode(),
            "placement": {
                "grid_cols": cells,
                "grid_rows": 1,
                "viewport_row": 0,
                "viewport_col": 0,
            },
        },
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # one line to the plugin log, never a traceback
        sys.exit(f"panecontext overlay: {exc}")
