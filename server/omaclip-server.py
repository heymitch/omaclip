#!/usr/bin/env python3
"""omaclip server: receives recordings and publishes each one as a shareable page.

Caddy (or any web server) serves OMACLIP_DIR as static files. This process only
handles the API, behind the same web server or a Tailscale-only address:

  PUT    /api/upload        mp4 body, Authorization: Bearer <token>  -> {"id", "url", ...}
  DELETE /api/clips/<id>    Authorization: Bearer <token>            -> {"deleted": "<id>"}
  GET    /api/ping          Authorization: Bearer <token>            -> {"ok": true}

Each upload becomes OMACLIP_DIR/<id>/ with video.mp4 (re-packed so playback starts
before the whole file arrives), thumb.jpg, index.html (with link-preview tags) and
oembed.json. Configuration comes from the environment (see omaclip.env.example).
"""

import hmac
import html
import json
import os
import secrets
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CLIP_DIR = Path(os.environ.get("OMACLIP_DIR", "/srv/omaclip"))
PUBLIC_URL = os.environ.get("OMACLIP_URL", "").rstrip("/")
TOKEN = os.environ.get("OMACLIP_TOKEN", "")
BIND = os.environ.get("OMACLIP_BIND", "127.0.0.1")
PORT = int(os.environ.get("OMACLIP_PORT", "8798"))
MAX_BYTES = int(os.environ.get("OMACLIP_MAX_MB", "4096")) * 1024 * 1024

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{title}</title>
<meta property="og:type" content="video.other">
<meta property="og:title" content="{title}">
<meta property="og:url" content="{page}">
<meta property="og:image" content="{thumb}">
<meta property="og:image:width" content="{tw}">
<meta property="og:image:height" content="{th}">
<meta property="og:video" content="{video}">
<meta property="og:video:secure_url" content="{video}">
<meta property="og:video:type" content="video/mp4">
<meta property="og:video:width" content="{w}">
<meta property="og:video:height" content="{h}">
<meta name="twitter:card" content="player">
<meta name="twitter:title" content="{title}">
<meta name="twitter:image" content="{thumb}">
<meta name="twitter:player" content="{page}">
<meta name="twitter:player:width" content="{w}">
<meta name="twitter:player:height" content="{h}">
<link rel="alternate" type="application/json+oembed" href="{page}oembed.json" title="{title}">
<style>
  html, body {{ margin: 0; height: 100%; background: #0e0e10; color: #c3ccd6; font: 13px/1.4 system-ui, sans-serif; }}
  body {{ display: grid; grid-template-rows: 1fr auto; }}
  main {{ display: grid; place-items: center; min-height: 0; }}
  video {{ max-width: 100vw; max-height: calc(100vh - 32px); width: 100%; background: #000; }}
  footer {{ display: flex; justify-content: space-between; padding: 8px 14px; opacity: .7; }}
  a {{ color: inherit; }}
</style></head>
<body>
<main><video src="video.mp4" poster="thumb.jpg" controls playsinline preload="metadata"></video></main>
<footer><span>{title} · {length}</span><a href="video.mp4" download>Download</a></footer>
</body></html>
"""


def probe(path):
    """Width, height and duration of a video, or sensible defaults if ffprobe can't tell."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height:format=duration", "-of", "json", str(path)],
            capture_output=True, text=True, timeout=60).stdout
        data = json.loads(out)
        stream = data["streams"][0]
        return int(stream["width"]), int(stream["height"]), float(data["format"]["duration"])
    except Exception:
        return 1920, 1080, 0.0


def finish_clip(raw, folder, title):
    """Turn an uploaded file into a published clip folder. Returns the response body."""
    video = folder / "video.mp4"
    # Move the index to the front so browsers and embeds can start playing immediately.
    remux = subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-c", "copy", "-movflags", "+faststart", str(video)],
        capture_output=True, timeout=600)
    if remux.returncode != 0 or not video.exists():
        shutil.move(str(raw), video)

    width, height, duration = probe(video)
    thumb = folder / "thumb.jpg"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-ss", str(min(1.0, duration / 2)), "-i", str(video),
         "-frames:v", "1", "-vf", "scale=1280:-2", str(thumb)],
        capture_output=True, timeout=120)
    thumb_w, thumb_h = 1280, round(1280 * height / width / 2) * 2

    page = f"{PUBLIC_URL}/{folder.name}/"
    minutes, seconds = divmod(round(duration), 60)
    length = f"{minutes}:{seconds:02d}"
    safe = html.escape(title, quote=True)
    (folder / "index.html").write_text(PAGE.format(
        title=safe, page=page, video=page + "video.mp4", thumb=page + "thumb.jpg",
        w=width, h=height, tw=thumb_w, th=thumb_h, length=length))

    embed_w, embed_h = 960, round(960 * height / width)
    oembed = {
        "version": "1.0", "type": "video", "provider_name": "omaclip", "title": title,
        "width": embed_w, "height": embed_h,
        "thumbnail_url": page + "thumb.jpg", "thumbnail_width": thumb_w, "thumbnail_height": thumb_h,
        "html": f'<iframe src="{page}" width="{embed_w}" height="{embed_h}" frameborder="0" '
                f'allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe>',
    }
    (folder / "oembed.json").write_text(json.dumps(oembed, indent=2))
    folder.chmod(0o755)
    for f in folder.iterdir():
        f.chmod(0o644)
    return {"id": folder.name, "url": page, "video": page + "video.mp4",
            "thumbnail": page + "thumb.jpg", "duration": round(duration, 1)}


class Handler(BaseHTTPRequestHandler):
    server_version = "omaclip"

    def authorized(self):
        given = self.headers.get("Authorization", "").removeprefix("Bearer ").strip()
        return bool(TOKEN) and hmac.compare_digest(given.encode(), TOKEN.encode())

    def do_GET(self):
        if self.path != "/api/ping":
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return self.reply(401, {"error": "bad or missing token"})
        self.reply(200, {"ok": True, "url": PUBLIC_URL})

    def do_PUT(self):
        if self.path != "/api/upload":
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return self.reply(401, {"error": "bad or missing token"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return self.reply(411, {"error": "Content-Length required"})
        if length > MAX_BYTES:
            return self.reply(413, {"error": f"over the {MAX_BYTES // 1048576} MB limit"})

        title = self.headers.get("X-Omaclip-Title") or "Recording · " + datetime.now(timezone.utc).strftime("%b %-d, %Y")
        folder = CLIP_DIR / secrets.token_urlsafe(9)
        folder.mkdir(parents=True)
        with tempfile.NamedTemporaryFile(dir=folder, suffix=".upload", delete=False) as out:
            raw = Path(out.name)
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                out.write(chunk)
                remaining -= len(chunk)
        if remaining:
            shutil.rmtree(folder)
            return self.reply(400, {"error": "upload cut short"})
        try:
            body = finish_clip(raw, folder, title[:120])
        finally:
            raw.unlink(missing_ok=True)
        self.reply(200, body)

    def do_DELETE(self):
        if not self.path.startswith("/api/clips/"):
            return self.reply(404, {"error": "not found"})
        if not self.authorized():
            return self.reply(401, {"error": "bad or missing token"})
        clip_id = self.path.removeprefix("/api/clips/").strip("/")
        folder = CLIP_DIR / clip_id
        if not clip_id or "/" in clip_id or clip_id.startswith(".") or not folder.is_dir():
            return self.reply(404, {"error": "no such clip"})
        shutil.rmtree(folder)
        self.reply(200, {"deleted": clip_id})

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    if not TOKEN or not PUBLIC_URL:
        raise SystemExit("Set OMACLIP_TOKEN and OMACLIP_URL (see omaclip.env.example).")
    CLIP_DIR.mkdir(parents=True, exist_ok=True)
    index = CLIP_DIR / "index.html"
    if not index.exists():
        index.write_text('<!doctype html><meta charset="utf-8"><title>omaclip</title>\n')
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
