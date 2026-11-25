# Web version and Docker

Diapason builds for the browser with Flutter web, and the repository ships a Docker image that serves that build with
nginx, in the spirit of Feishin's web image. One image can be preset for any server through environment variables.

## What works in the browser

- Jellyfin, Subsonic / Navidrome (and other OpenSubsonic servers) and Plex sources.
- Browsing, search, queue, lyrics, scrobbling, playback through the browser's `<audio>` element (just_audio web),
  media session controls (lock screen / media keys) where the browser supports them.
- Settings, the queue and the logged-in sources are kept in the browser's IndexedDB (Hive). Clearing the site data
  logs you out.

Not available, because a browser can't do it (those screens show "Not available in the web version"):

- Downloads and offline mode, the streamed-track cache, storage management, backups.
- Local folders and MPD sources (no file system, no raw TCP sockets).
- Server discovery on the local network, Diapason Connect, casting, "send to / import from mobile".
- yt-dlp / YouTube, Discord Rich Presence, global shortcuts, automix audio analysis.

## Build it yourself

```sh
flutter gen-l10n
flutter build web --release
# serve build/web with any static web server, for example:
cd build/web && python3 -m http.server 8080
```

`build/web/diapason-config.js` holds the server preset (empty by default, see below); edit it to preset a server
without Docker.

## Docker

```sh
docker build -t diapason-web .
docker run -d -p 8080:8080 \
  -e SERVER_NAME="Home" -e SERVER_TYPE=jellyfin -e SERVER_URL=https://jellyfin.example.com \
  diapason-web
```

or with Compose (see `docker-compose.yaml` at the root of the repository):

```sh
docker compose up -d
```

The app is then on `http://localhost:8080`. The image is built in two stages: a Flutter SDK image
(`ghcr.io/cirruslabs/flutter`, version set by the `FLUTTER_VERSION` build argument) compiles the web app, then
`nginxinc/nginx-unprivileged` serves it on port 8080 as a non-root user. nginx falls back to `index.html` for unknown
paths, gzips text assets and tells browsers to revalidate `index.html` and the bootstrap scripts, so a new image is
picked up on reload.

### Server preset

| Variable      | Values                                          | Effect                                                                                                   |
|---------------|-------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| `SERVER_TYPE` | `jellyfin`, `subsonic`, `navidrome`, `plex` (case insensitive) | Login skips "Where's your music?" and opens that server's form.                            |
| `SERVER_URL`  | `http(s)://host:port`                           | Pre-filled server address. It must be reachable **from the browser**, not from the container.            |
| `SERVER_NAME` | any text                                        | Name given to the source (Subsonic / Plex).                                                              |
| `SERVER_LOCK` | `true` / `false` (default)                      | `true`: the address is read-only and Settings > Sources only offers that type of server.                 |

`SERVER_TYPE` and `SERVER_URL` must both be set for the preset to apply; otherwise the normal login flow is shown.

At container start, nginx's template step writes these values into `/diapason-config.js` (served with
`Cache-Control: no-store`), which `index.html` loads before the app starts. Changing the variables only needs a
container restart, not a rebuild. Only the `SERVER_*` variables are substituted.

`SERVER_LOCK` is a convenience, not a security boundary: anyone can still talk to any server from their own browser.

## CORS: what your server must allow

The web app runs on its own origin (say `https://music.example.com`) and talks to your media server directly from the
browser, so the media server must answer cross-origin requests. Audio is fetched in CORS mode too (the `<audio>`
element uses `crossorigin="anonymous"`), so streams need the same headers as the API.

The simplest setup avoids CORS entirely: serve Diapason and the media server under the same origin through a reverse
proxy (for example `https://music.example.com/` for Diapason and `https://music.example.com/jellyfin/` for Jellyfin, with
Jellyfin's base URL set accordingly).

Otherwise, per server type:

- **Jellyfin**: sends `Access-Control-Allow-Origin: *` on its API and streaming endpoints out of the box. If a reverse
  proxy sits in front of it, make sure it passes these headers through and answers `OPTIONS` preflight requests (the
  app sends an `Authorization` header, which triggers a preflight).
- **Navidrome**: allows any origin on `/rest` (Subsonic API) out of the box. Nothing to do unless a proxy strips the
  headers.
- **Other Subsonic servers** (Airsonic, Gonic, Ampache...): check that `/rest/*` answers with
  `Access-Control-Allow-Origin` (your Diapason origin or `*`). Diapason uses token authentication in the query string,
  so these are simple GET requests without preflight.
- **Plex**: Diapason passes the token as an `X-Plex-Token` query parameter with only an `Accept` header, so API calls
  are simple GETs without preflight. Plex Media Server's CORS answers vary between versions and setups (Plex's own web
  app is usually served from the server itself); this path has not been tested from another origin yet. If requests
  are blocked, put a reverse proxy in front that adds `Access-Control-Allow-Origin`, or serve both under one origin.

Mixed content: a Diapason page served over HTTPS can't call an `http://` server (the browser blocks it). Serve both
over HTTPS, or both over HTTP on a trusted network.

If something fails, the browser's developer console (Network tab) shows the blocked request and the missing header;
Diapason's logs go to the console too (raise the log level in Settings > Storage & diagnostics for more than errors).

Example nginx snippet for a proxy in front of a server that lacks CORS headers:

```nginx
location / {
  if ($request_method = OPTIONS) {
    add_header Access-Control-Allow-Origin "https://music.example.com";
    add_header Access-Control-Allow-Headers "*";
    add_header Access-Control-Allow-Methods "GET, POST, DELETE, OPTIONS";
    add_header Access-Control-Max-Age 86400;
    return 204;
  }
  add_header Access-Control-Allow-Origin "https://music.example.com" always;
  add_header Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges" always;
  proxy_pass http://media-server:port;
}
```
