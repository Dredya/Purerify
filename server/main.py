import os
import re
import json
import uuid
import shutil
import base64
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from urllib.request import Request, urlopen
from urllib.error import HTTPError

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import yt_dlp

STORAGE_DIR = Path(__file__).resolve().parent / "storage"
STORAGE_DIR.mkdir(parents=True, exist_ok=True)

ALLOWED_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "www.youtube-nocookie.com",
    "youtube-nocookie.com",
}

app = FastAPI(title="Purerify Conversion Server")
app.mount("/files", StaticFiles(directory=str(STORAGE_DIR)), name="files")


SPOTIFY_CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID", "").strip()
SPOTIFY_CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET", "").strip()


class ConvertRequest(BaseModel):
    url: str


class SpotifyPlaylistRequest(BaseModel):
    url: str


class YouTubeSearchRequest(BaseModel):
    query: str


def _spotify_token() -> str:
    if not SPOTIFY_CLIENT_ID or not SPOTIFY_CLIENT_SECRET:
        raise HTTPException(status_code=500, detail="Spotify credentials are not configured on the server.")
    creds = base64.b64encode(f"{SPOTIFY_CLIENT_ID}:{SPOTIFY_CLIENT_SECRET}".encode()).decode()
    data = "grant_type=client_credentials".encode()
    req = Request("https://accounts.spotify.com/api/token", data=data, method="POST")
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read().decode())
    except HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Spotify auth failed: {exc.code}")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Spotify auth failed: {exc}")
    token = payload.get("access_token")
    if not token:
        raise HTTPException(status_code=502, detail="Spotify auth returned no token.")
    return token


def _spotify_playlist_id(raw: str) -> str:
    raw = (raw or "").strip()
    if raw.startswith("spotify:playlist:"):
        return raw.split(":")[-1]
    parsed = urlparse(raw)
    # path like /playlist/{id}
    parts = [p for p in parsed.path.split("/") if p]
    if len(parts) >= 2 and parts[0] == "playlist":
        return parts[1].split("?")[0]
    # maybe query param
    qs = parse_qs(parsed.query)
    if "playlist" in qs:
        return qs["playlist"][0]
    raise HTTPException(status_code=400, detail="Invalid Spotify playlist URL.")


def is_youtube_url(raw: str) -> bool:
    try:
        parsed = urlparse(raw.strip())
    except Exception:
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    host = (parsed.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host in {h.replace("www.", "") for h in ALLOWED_HOSTS}


def cleanup_old_files(max_age_hours: int = 24) -> None:
    cutoff = datetime.now(timezone.utc) - timedelta(hours=max_age_hours)
    for path in STORAGE_DIR.iterdir():
        if not path.is_file():
            continue
        try:
            mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
            if mtime < cutoff:
                path.unlink(missing_ok=True)
        except Exception:
            pass


def fetch_spotify_playlist(raw_url: str) -> dict:
    playlist_id = _spotify_playlist_id(raw_url)
    token = _spotify_token()
    url = f"https://api.spotify.com/v1/playlists/{playlist_id}?fields=name,tracks.items(track(name,artists(name),album(name),duration_ms)),tracks.next,tracks.total"
    tracks = []
    name = "Spotify Playlist"
    next_url = url
    while next_url:
        req = Request(next_url)
        req.add_header("Authorization", f"Bearer {token}")
        try:
            with urlopen(req, timeout=30) as resp:
                payload = json.loads(resp.read().decode())
        except HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Spotify playlist fetch failed: {exc.code}")
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Spotify playlist fetch failed: {exc}")
        if "name" in payload and name == "Spotify Playlist":
            name = payload.get("name") or name
        for item in (payload.get("tracks", {}) or {}).get("items", []) or []:
            track = item.get("track") or {}
            if not track:
                continue
            artists = ", ".join(a.get("name", "") for a in (track.get("artists") or []) if a.get("name"))
            tracks.append({
                "title": track.get("name") or "",
                "artist": artists,
                "album": (track.get("album") or {}).get("name") or "",
                "durationMs": track.get("duration_ms") or 0,
            })
        next_url = (payload.get("tracks") or {}).get("next")
    return {"name": name, "tracks": tracks}


def search_youtube(query: str) -> dict:
    q = (query or "").strip()
    if not q:
        raise HTTPException(status_code=400, detail="Missing query")
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "js_runtimes": {"node": {}},
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"ytsearch1:{q}", download=False)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"YouTube search failed: {exc}")
    entries = info.get("entries") or []
    if not entries:
        raise HTTPException(status_code=404, detail="No YouTube results found.")
    first = entries[0]
    video_id = first.get("id") or ""
    return {
        "id": video_id,
        "title": first.get("title") or "",
        "author": first.get("uploader") or first.get("channel") or "",
        "url": first.get("webpage_url") or (f"https://www.youtube.com/watch?v={video_id}" if video_id else ""),
    }


def extract_info(url: str) -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "js_runtimes": {"node": {}},
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(url, download=False)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/convert")
def convert(req: ConvertRequest, request: Request):
    url = (req.url or "").strip()
    if not url:
        raise HTTPException(status_code=400, detail="Missing url")
    if not is_youtube_url(url):
        raise HTTPException(status_code=400, detail="Only YouTube URLs are supported")

    cleanup_old_files()

    try:
        info = extract_info(url)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Could not read video: {exc}")

    video_id = info.get("id") or ""
    title = info.get("title") or "YouTube audio"
    author = info.get("uploader") or info.get("channel") or ""

    base_name = f"{video_id}_{uuid.uuid4().hex}" if video_id else uuid.uuid4().hex
    outtmpl = str(STORAGE_DIR / f"{base_name}.%(ext)s")

    opts = {
        "format": "bestaudio/best",
        "outtmpl": outtmpl,
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}],
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "js_runtimes": {"node": {}},
    }

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            downloaded = ydl.extract_info(url, download=True)
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Download failed: {exc}")

    requested = (downloaded.get("requested_downloads") or [{}])[0]
    filepath = requested.get("filepath")
    if not filepath or not Path(filepath).is_file():
        # fall back: find produced file
        matches = sorted(STORAGE_DIR.glob(f"{base_name}.*"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not matches:
            raise HTTPException(status_code=500, detail="Server did not produce an audio file")
        filepath = str(matches[0])

    filename = Path(filepath).name
    size = Path(filepath).stat().st_size

    base_url = str(request.base_url).rstrip("/")
    audio_url = f"{base_url}/files/{filename}"

    return JSONResponse(
        {
            "id": video_id,
            "title": title,
            "author": author,
            "audioUrl": audio_url,
            "contentLength": size,
            "userAgent": "",
            "clientName": "server",
        }
    )


@app.post("/spotify/playlist")
def spotify_playlist(req: SpotifyPlaylistRequest):
    return JSONResponse(fetch_spotify_playlist(req.url))


@app.post("/search/youtube")
def youtube_search(req: YouTubeSearchRequest):
    return JSONResponse(search_youtube(req.query))