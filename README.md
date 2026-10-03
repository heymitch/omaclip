# omaclip

Loom-style screen recording for [Omarchy](https://omarchy.org), shared from your own server.

Press **Super+Shift+R**. A 3-2-1 countdown shows your mic level, then omaclip records your
screen with a camera bubble in the corner you pick. Press it again to stop, and a menu asks:
**Share link**, **Keep local only** or **Delete**. Share uploads the video to your VPS and
copies a link like `https://clips.example.com/k3J9xQ2mPa8w/` that anyone can open. Links
unfurl with a thumbnail and player in Slack, iMessage, X and anything that reads Open Graph
or oEmbed.

The bar icon is a little screen with your camera bubble in its corner. During the countdown
the bubble fills in three steps; while you record it turns red and fills one lap per minute
(hover for the exact time). The icon's panel holds your recent links and every setting, and
its background matches the opacity Hyprland gives your terminals (the text stays solid).

Tip: Omarchy's own screen-recording indicator shows up too while you record. To keep the bar
tidy, untick **Screen recording** in the Indicators widget's settings, or run:
`omarchy bar set omarchy.indicators items '["Dictation","Reminder","NightLight","Dnd","StayAwake"]' --json`

- No subscription, no upload limits but your disk, no third-party tracking.
- Your videos live on your server, at your domain.
- Everything is plain files: a Bash command, a Python upload service, Caddy for HTTPS.

## What you need

- **Omarchy** with the Quickshell bar (v4 or later).
- **A VPS** running Ubuntu or Debian with a public IP address. The smallest plan anywhere
  is plenty; storage is the only thing that grows.
- **A domain** whose DNS you control. The steps below use Cloudflare, but any DNS host works.
- Optional: **Tailscale** on both machines, if you want uploads to be reachable only from
  your own devices.

## 1. Point a subdomain at your VPS (Cloudflare)

In the Cloudflare dashboard, open your domain → **DNS** → **Records** → **Add record**:

| Field        | Value                              |
|--------------|------------------------------------|
| Type         | `A`                                |
| Name         | `clips` (gives `clips.example.com`) |
| IPv4 address | your VPS's public IP               |
| Proxy status | **DNS only** (grey cloud)          |
| TTL          | Auto                               |

Leave the proxy **off**. Caddy on the VPS gets its own HTTPS certificate and serves the
video directly; Cloudflare's free proxy isn't meant for serving video files.

Check it before moving on (it can take a minute or two):

```bash
curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=clips.example.com&type=A'
```

Make sure ports **80** and **443** are open to the internet in your VPS provider's firewall
and in `ufw` if you use it (`sudo ufw allow 80,443/tcp`).

## 2. Install the server

On the VPS:

```bash
git clone https://github.com/heymitch/omaclip.git
cd omaclip
sudo ./server/install.sh clips.example.com
```

That installs Caddy and ffmpeg, creates an `omaclip` service account, stores clips in
`/srv/omaclip`, starts the upload service, and gets an HTTPS certificate. At the end it prints
three values (site, upload address and token) for the desktop side. Keep the token private:
anyone with it can upload to your server.

### Optional: uploads only over Tailscale

If both machines are on your Tailscale network, you can keep the upload API off the public
internet entirely. Clips are still public at your domain; only the upload door moves inside
your tailnet:

```bash
sudo ./server/install.sh clips.example.com --tailnet
```

The installer then blocks `/api/*` on the public site and exposes the API at
`https://<your-vps>.<tailnet>.ts.net:8446/api/upload` with `tailscale serve`. You need
Tailscale installed and logged in on the VPS (`curl -fsSL https://tailscale.com/install.sh | sh`,
then `sudo tailscale up`) and on your Omarchy machine (`omarchy install service tailscale`, or the
Tailscale widget in the bar).

If Tailscale Serve already uses port 443 on the VPS, the installer notices and binds Caddy
to the public address only, so the two don't collide.

Re-running the installer is safe: it keeps your token and your clips.

## 3. Install on Omarchy

```bash
omarchy plugin add https://github.com/heymitch/omaclip.git --enable
~/.config/omarchy/plugins/heymitch.omaclip/bin/omaclip install
```

The first command adds the bar widget. The second puts `omaclip` on your PATH, adds the
after-recording menu to the Omarchy menu, and binds **Super+Shift+R**. To use another key:
`omaclip install "SUPER + SHIFT + V"`.

Then open the widget's panel (the record icon in the bar), paste the three values the
server printed into **Server**, and press **Test connection**. Or from a terminal:

```bash
omaclip config set server https://clips.example.com
omaclip config set uploadUrl https://clips.example.com/api/upload   # or your Tailscale address
omaclip config set token <token>
omaclip test
```

## Using it

| Do this | What happens |
|---|---|
| **Super+Shift+R** | Countdown with mic meter, then recording starts |
| **Super+Shift+R** again | Stops, then the menu: Share link / Keep local only / Delete |
| Click the bar icon while recording | Stops, same as the shortcut |
| Click the bar icon otherwise | Panel: Record button, recent links, settings |
| Click a recent link | Copies it |
| Trash icon on a recent link | Takes the clip down from your server |

Recordings always land in `~/Videos` first; sharing uploads a copy.

Settings (panel or `omaclip config set <key> <value>`):

| Key | Default | Meaning |
|---|---|---|
| `camera` | `true` | Show the camera bubble |
| `cameraCorner` | `bottom-left` | `top-left`, `top-right`, `bottom-left`, `bottom-right` |
| `cameraSize` | `medium` | `small`, `medium`, `large` |
| `cameraDevice` | first webcam | e.g. `/dev/video2` |
| `cameraMirror` | `true` | Flip the bubble like a mirror (the recording is flipped too) |
| `mic` | `true` | Record your microphone |
| `systemAudio` | `true` | Record system audio (what your computer plays) |
| `countdown` | `true` | 3-2-1 with mic level before recording |
| `server` | | Your clip site, e.g. `https://clips.example.com` |
| `uploadUrl` | `<server>/api/upload` | Only set this for a Tailscale address |
| `token` | | From the server installer |

`omaclip camera` shows or hides the bubble so you can check the framing first.
`omaclip countdown` runs just the mic check.

## Embedding

Every clip page is `https://clips.example.com/<id>/` and contains:

- `video.mp4`: the video, re-packed on upload so playback starts right away.
- `thumb.jpg`: a thumbnail from the first second.
- Open Graph and Twitter player tags, so pasted links show a preview.
- `oembed.json`, linked from the page, for tools that embed by oEmbed.

To embed on your own site:

```html
<iframe src="https://clips.example.com/<id>/" width="960" height="540"
        frameborder="0" allow="fullscreen; picture-in-picture" allowfullscreen></iframe>
```

or the bare video:

```html
<video src="https://clips.example.com/<id>/video.mp4" poster="https://clips.example.com/<id>/thumb.jpg" controls></video>
```

## Privacy

Links are long random IDs and the site root lists nothing, so a clip is only found by people
you send the link to. Clip pages ask search engines not to index them. Anyone who has a link
can watch it, so take a clip down when it's no longer needed.

## Uninstall

```bash
omaclip uninstall                       # menu entries, keybinding, PATH link
omarchy plugin remove heymitch.omaclip  # the bar widget
```

On the server: `sudo systemctl disable --now omaclip`, then remove `/etc/caddy/omaclip.caddy`,
its `import` line in `/etc/caddy/Caddyfile`, and `/srv/omaclip` if you want the clips gone.

## How it fits together

```
Omarchy                                   VPS
───────                                   ───
Super+Shift+R → omaclip ─┐
  countdown + mic check  │
  camera bubble (mpv)    │
  omarchy screen recorder│
bar widget ◀─ status.json│
                         └── PUT /api/upload (Bearer token) ──▶ omaclip-server.py
                                                                  ffmpeg: fast-start + thumbnail
                                                                  writes /srv/omaclip/<id>/
anyone ◀──────────────── https://clips.example.com/<id>/ ◀────── Caddy (HTTPS, static files)
```

## Developing

The bar widget is `Panel.qml`; the command is `bin/omaclip`; the server is
`server/omaclip-server.py`. The widget is a `keepLoaded` plugin, so after editing it run
`omarchy restart shell` to see changes.

## License

MIT
