#!/usr/bin/env python3
"""
Semantic Concept Animation Bot - Render Free Tier edition (512 MB RAM)

Flow:  Telegram voice -> ffmpeg/pydub silence trim -> Groq whisper-large-v3 (word timestamps)
       -> Groq LLM (3-5 scenes) -> Pollinations (styled icons) -> MoviePy (single make_frame render)
       -> Telegram MP4.   Send an image/video captioned "style" to teach the bot a visual style.

requirements.txt
    python-telegram-bot>=20.7
    aiohttp
    httpx
    pydub
    audioop-lts; python_version >= "3.13"
    moviepy==1.0.3
    imageio-ffmpeg
    numpy<2
    pillow
    arabic-reshaper
    python-bidi

Render settings
    Build command : pip install -r requirements.txt
    Start command : python render_style_bot.py
    Env vars      : GROQ_API_KEY (required)
                    PYTHON_VERSION=3.11.9 (recommended)
                    optional: TELEGRAM_BOT_TOKEN (overrides the hardcoded one), GROQ_VISION_MODEL,
                    GROQ_TEXT_MODEL, RENDER_W, RENDER_H, FPS, MAX_AUDIO_SEC
ffmpeg comes from the `imageio-ffmpeg` wheel (static binary), so no apt packages are needed.
"""
from __future__ import annotations

import asyncio
import base64
import bisect
import gc
import io
import json
import logging
import math
import os
import random
import re
import shutil
import signal
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote

import arabic_reshaper
import httpx
import imageio_ffmpeg
import numpy as np
from aiohttp import web
from bidi.algorithm import get_display
from moviepy.audio.io.AudioFileClip import AudioFileClip
from moviepy.video.VideoClip import VideoClip
from PIL import Image, ImageDraw, ImageFont, ImageOps
from pydub import AudioSegment
from pydub.silence import detect_nonsilent
from telegram import Update
from telegram.ext import (ApplicationBuilder, CommandHandler, ContextTypes,
                          MessageHandler, filters)

# ============================================================================ config
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN") or "8696031949:AAE9Apa2AUylcOjwOQWS-1xk6cwuEQNairc"
ALLOWED_USER_IDS = [1856348842]

GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_BASE = "https://api.groq.com/openai/v1"
GROQ_TEXT_MODEL = os.environ.get("GROQ_TEXT_MODEL", "llama-3.3-70b-versatile")
GROQ_VISION_MODEL = os.environ.get("GROQ_VISION_MODEL", "meta-llama/llama-4-scout-17b-16e-instruct")
GROQ_STT_MODEL = "whisper-large-v3"
POLLINATIONS_URL = os.environ.get("POLLINATIONS_URL", "https://image.pollinations.ai/prompt")

PORT = int(os.environ.get("PORT", 10000))

# Memory/CPU-friendly render settings (720x1280 is still true 9:16 vertical)
W = int(os.environ.get("RENDER_W", 720))
H = int(os.environ.get("RENDER_H", 1280))
FPS = int(os.environ.get("FPS", 24))
MAX_AUDIO_SEC = int(os.environ.get("MAX_AUDIO_SEC", 90))

ICON_SIZE = int(W * 0.72)
ICON_CY = int(H * 0.41)
CAPTION_CY = int(H * 0.76)
CAPTION_FONT_SIZE = int(W * 0.072)
CAPTION_MAX_W = int(W * 0.87)

SILENCE_MIN_MS, SILENCE_KEEP_MS, SPEECH_PAD_MS = 700, 220, 120

FONT_PATH = Path("fonts/Amiri-Bold.ttf")
FONT_URLS = [
    "https://github.com/google/fonts/raw/main/ofl/amiri/Amiri-Bold.ttf",
    "https://raw.githubusercontent.com/google/fonts/main/ofl/amiri/Amiri-Bold.ttf",
]

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
WORK_ROOT = Path(tempfile.gettempdir()) / "style_bot"
WORK_ROOT.mkdir(exist_ok=True)
JOB_LOCK = asyncio.Lock()  # one heavy job at a time (512 MB!)

logging.basicConfig(format="%(asctime)s %(levelname)s %(name)s: %(message)s", level=logging.INFO)
log = logging.getLogger("style-bot")
logging.getLogger("httpx").setLevel(logging.WARNING)


# ============================================================================ in-memory style state
@dataclass
class StyleState:
    style_prompt: str = "minimalist black line art vector icon, bold clean outline, flat, no shading"
    bg: tuple[int, int, int] = (255, 255, 255)
    fg: tuple[int, int, int] = (0, 0, 0)


STATE = StyleState()          # CURRENT_STYLE_PROMPT lives here (memory only, resets on restart)


class UserError(Exception):
    """Message is safe to show to the user."""


@dataclass
class Word:
    text: str
    start: float
    end: float


@dataclass
class Scene:
    start_word: int
    concept: str
    t0: float = 0.0
    t1: float = 0.0


# ============================================================================ ffmpeg helpers (async)
async def run_ffmpeg(*args: str, timeout: int = 120) -> None:
    proc = await asyncio.create_subprocess_exec(
        FFMPEG, "-y", "-loglevel", "error", *args,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
    try:
        _, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise UserError("ffmpeg timed out.")
    if proc.returncode != 0:
        raise UserError(f"ffmpeg failed: {err.decode(errors='ignore')[:200]}")


# ============================================================================ Groq helpers
async def groq_post(client: httpx.AsyncClient, path: str, *, json_body=None, data=None,
                    files=None, timeout: float = 120) -> dict:
    for attempt in range(4):
        r = await client.post(f"{GROQ_BASE}{path}", headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
                              json=json_body, data=data, files=files, timeout=timeout)
        if r.status_code == 429 or r.status_code >= 500:
            wait = float(r.headers.get("retry-after", 2 * (attempt + 1)) or 2)
            log.warning("Groq %s -> %s, retrying in %.0fs", path, r.status_code, wait)
            await asyncio.sleep(min(wait, 30))
            continue
        if r.status_code >= 400:
            raise RuntimeError(f"Groq {r.status_code}: {r.text[:300]}")
        return r.json()
    raise UserError("Groq API is rate-limited or unavailable, try again in a minute.")


def extract_json(text: str) -> dict:
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError("no JSON in model output")
    return json.loads(m.group(0))


# ============================================================================ 1. style reference (vision)
def derive_palette(img: Image.Image) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """Background colour = median of the image border; text colour = best contrast."""
    small = np.asarray(img.convert("RGB").resize((96, 96), Image.BILINEAR)).astype(np.int16)
    border = np.concatenate([small[0], small[-1], small[:, 0], small[:, -1]])
    bg = tuple(int(v) for v in np.median(border, axis=0))
    lum = 0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]
    fg = (20, 20, 20) if lum > 140 else (245, 245, 245)
    return bg, fg


def describe_color(rgb: tuple[int, int, int]) -> str:
    lum = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
    sat = max(rgb) - min(rgb)
    if sat < 25 and lum > 225:
        return "white"
    if sat < 25 and lum < 45:
        return "black"
    return "flat solid color #%02x%02x%02x" % rgb


VISION_PROMPT = (
    "Analyze the ARTISTIC STYLE of this reference image so other objects can be drawn in the same style. "
    "Describe medium, line weight, color palette, texture, shading and level of detail as ONE comma-separated "
    "English phrase (max 35 words) usable as an image-generation style suffix. Do NOT mention the subject matter, "
    "people, text, paper, grid or background. "
    'Return ONLY JSON: {"style_prompt": "..."}')


async def analyze_style(client: httpx.AsyncClient, image_path: Path) -> tuple[str, Image.Image]:
    img = Image.open(image_path).convert("RGB")
    img = ImageOps.contain(img, (768, 768), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    b64 = base64.b64encode(buf.getvalue()).decode()
    j = await groq_post(client, "/chat/completions", json_body={
        "model": GROQ_VISION_MODEL, "temperature": 0.2, "max_tokens": 200,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": VISION_PROMPT},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}}]}]})
    style = str(extract_json(j["choices"][0]["message"]["content"]).get("style_prompt", "")).strip()
    if len(style) < 8:
        raise UserError("The vision model returned no usable style description.")
    return style[:400], img


# ============================================================================ 2. audio
async def prepare_audio(src: Path, work: Path) -> tuple[Path, float]:
    """Any input -> 16 kHz mono wav (ffmpeg from imageio-ffmpeg; no ffprobe needed) -> trim silences."""
    raw, clean = work / "raw.wav", work / "clean.wav"
    await run_ffmpeg("-i", str(src), "-vn", "-ac", "1", "-ar", "16000", str(raw))
    dur = await asyncio.to_thread(trim_silence, raw, clean)
    raw.unlink(missing_ok=True)
    return clean, dur


def trim_silence(src: Path, dst: Path) -> float:
    audio = AudioSegment.from_wav(str(src))
    spans = detect_nonsilent(audio, min_silence_len=SILENCE_MIN_MS,
                             silence_thresh=audio.dBFS - 16, seek_step=10)
    if not spans:
        raise UserError("لم أجد كلاماً في المقطع. / No speech detected.")
    gap = AudioSegment.silent(SILENCE_KEEP_MS, frame_rate=audio.frame_rate)
    out = AudioSegment.empty()
    for i, (s, e) in enumerate(spans):
        out += audio[max(0, s - SPEECH_PAD_MS): min(len(audio), e + SPEECH_PAD_MS)]
        if i < len(spans) - 1:
            out += gap
    out.export(str(dst), format="wav")
    return len(out) / 1000.0


# ============================================================================ 3. Groq Whisper
async def groq_transcribe(client: httpx.AsyncClient, wav: Path) -> list[Word]:
    j = await groq_post(client, "/audio/transcriptions",
                        data={"model": GROQ_STT_MODEL, "language": "ar", "temperature": "0",
                              "response_format": "verbose_json", "timestamp_granularities[]": "word"},
                        files={"file": ("audio.wav", wav.read_bytes(), "audio/wav")}, timeout=180)
    words = [Word(w["word"].strip(), float(w["start"]), max(float(w["end"]), float(w["start"]) + 0.05))
             for w in j.get("words", []) if w.get("word", "").strip()]
    if not words:  # fallback: spread segment words evenly
        for seg in j.get("segments", []):
            toks = seg.get("text", "").split()
            if toks:
                step = (seg["end"] - seg["start"]) / len(toks)
                words += [Word(t, seg["start"] + i * step, seg["start"] + (i + 1) * step)
                          for i, t in enumerate(toks)]
    return words


# ============================================================================ 4. scene planning
SCENE_SYSTEM = """You are a visual director for short Arabic Islamic reminder videos.
You receive a transcript as numbered words: [0]word [1]word ...
Split it into 3 to 5 CONSECUTIVE scenes. For each scene give:
 - "start_word": index of the scene's first word (first scene = 0, strictly increasing)
 - "concept": ONE concrete drawable object in English, 1-2 words (e.g. Prison, Crown, Heart, Scale, Door, Book).
   Never a person, prophet, angel or any living being.
Return ONLY JSON: {"scenes": [{"start_word": 0, "concept": "Prison"}, ...]}"""

FALLBACK_CONCEPTS = ["Heart", "Light", "Book", "Crown", "Star"]


def normalize_scenes(data: dict, n: int) -> list[Scene]:
    out, last = [], -1
    for s in data.get("scenes") or []:
        try:
            sw = int(s["start_word"])
        except (KeyError, TypeError, ValueError):
            continue
        concept = re.sub(r"[^A-Za-z0-9 \-]", "", str(s.get("concept", ""))).strip()[:40]
        sw = max(0, min(sw, n - 1))
        if concept and sw > last:
            out.append(Scene(sw, concept))
            last = sw
    out = out[:5]
    if out:
        out[0].start_word = 0
    return out


async def plan_scenes(client: httpx.AsyncClient, words: list[Word]) -> list[Scene]:
    numbered = " ".join(f"[{i}]{w.text}" for i, w in enumerate(words))
    scenes: list[Scene] = []
    try:
        j = await groq_post(client, "/chat/completions", json_body={
            "model": GROQ_TEXT_MODEL, "temperature": 0.4, "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": SCENE_SYSTEM}, {"role": "user", "content": numbered}]},
            timeout=60)
        scenes = normalize_scenes(json.loads(j["choices"][0]["message"]["content"]), len(words))
    except Exception as exc:
        log.warning("Scene planning failed (%s) - fallback scenes", exc)
    if not scenes:
        k = max(1, min(4, len(words) // 4))
        scenes = [Scene(i * len(words) // k, FALLBACK_CONCEPTS[i % 5]) for i in range(k)]
    return scenes


def assign_scene_times(scenes: list[Scene], words: list[Word], total: float) -> None:
    for i, sc in enumerate(scenes):
        sc.t0 = 0.0 if i == 0 else max(0.0, words[sc.start_word].start - 0.10)
    for i, sc in enumerate(scenes):
        sc.t1 = scenes[i + 1].t0 if i + 1 < len(scenes) else total


# ============================================================================ 5. styled asset generation
async def fetch_image(client: httpx.AsyncClient, prompt: str) -> Image.Image | None:
    for attempt in range(4):
        try:
            r = await client.get(f"{POLLINATIONS_URL}/{quote(prompt, safe='')}", timeout=120,
                                 params={"width": 768, "height": 768, "nologo": "true",
                                         "model": "flux", "seed": random.randint(1, 10**6)},
                                 follow_redirects=True)
            if r.status_code == 200 and r.headers.get("content-type", "").startswith("image"):
                return Image.open(io.BytesIO(r.content)).convert("RGB")
            log.warning("Pollinations HTTP %s", r.status_code)
        except (httpx.HTTPError, OSError) as exc:
            log.warning("Pollinations error: %s", exc)
        await asyncio.sleep(3 * (attempt + 1))
    return None


def key_out_background(img: Image.Image) -> Image.Image:
    """Remove the generator's flat background (colour sampled from the border) and un-premultiply
    edge pixels, so the icon composites cleanly onto ANY video background colour."""
    arr = np.asarray(img).astype(np.float32)
    border = np.concatenate([arr[0], arr[-1], arr[:, 0], arr[:, -1]])
    bgc = np.median(border, axis=0)
    dist = np.abs(arr - bgc).max(axis=2)
    a = np.clip((dist - 22.0) / 50.0, 0.0, 1.0)
    safe = np.maximum(a, 1e-3)[..., None]
    color = np.clip((arr - bgc * (1.0 - a[..., None])) / safe, 0, 255)
    rgba = np.dstack([color, a * 255.0]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    bbox = out.getchannel("A").point(lambda p: 255 if p > 12 else 0).getbbox()
    if bbox:
        out = out.crop(bbox)
    return ImageOps.contain(out, (ICON_SIZE, ICON_SIZE), Image.LANCZOS)


def fallback_icon(fg: tuple[int, int, int]) -> Image.Image:
    s = ICON_SIZE // 2
    img = Image.new("RGBA", (s, s), fg + (0,))
    d = ImageDraw.Draw(img)
    d.ellipse((6, 6, s - 6, s - 6), outline=fg + (255,), width=max(4, s // 25))
    return img


async def generate_icons(client: httpx.AsyncClient, scenes: list[Scene], style: StyleState) -> list[Image.Image]:
    bgdesc = describe_color(style.bg)
    icons = []
    for sc in scenes:   # sequential: gentle on Pollinations' free tier and on RAM
        prompt = (f"a single {sc.concept}, {style.style_prompt}, centered, isolated on a plain "
                  f"{bgdesc} background, no text, no watermark, no border")
        img = await fetch_image(client, prompt)
        icons.append(await asyncio.to_thread(key_out_background, img) if img else fallback_icon(style.fg))
        del img
    return icons


# ============================================================================ 6. Arabic typography
_font_cache: dict[int, ImageFont.FreeTypeFont] = {}


def get_font(size: int) -> ImageFont.FreeTypeFont:
    if size not in _font_cache:
        _font_cache[size] = ImageFont.truetype(str(FONT_PATH), size)
    return _font_cache[size]


def render_arabic(text: str, color: tuple[int, int, int]) -> Image.Image:
    """reshape -> wrap in logical order -> bidi per line -> draw (PIL, no ImageMagick)."""
    font = get_font(CAPTION_FONT_SIZE)
    lines: list[list[str]] = []
    cur: list[str] = []
    for w in arabic_reshaper.reshape(text).split():
        if cur and font.getlength(get_display(" ".join(cur + [w]))) > CAPTION_MAX_W:
            lines.append(cur)
            cur = [w]
        else:
            cur.append(w)
    if cur:
        lines.append(cur)
    lh, pad = int(CAPTION_FONT_SIZE * 1.5), 12
    img = Image.new("RGBA", (W, lh * len(lines) + 2 * pad), color + (0,))
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(lines):
        d.text((W / 2, pad + i * lh), get_display(" ".join(ln)), font=font, fill=color + (255,), anchor="ma")
    return img


@dataclass
class Chunk:
    text: str
    start: float
    end: float = 0.0
    last_end: float = 0.0


def build_caption_chunks(words: list[Word], scenes: list[Scene], total: float,
                         max_words: int = 4, max_gap: float = 0.6) -> list[Chunk]:
    starts = {s.start_word for s in scenes}
    groups: list[list[Word]] = []
    cur: list[Word] = []
    for i, w in enumerate(words):
        if cur and (len(cur) >= max_words or i in starts or w.start - cur[-1].end > max_gap):
            groups.append(cur)
            cur = []
        cur.append(w)
    if cur:
        groups.append(cur)
    chunks = [Chunk(" ".join(w.text for w in g), g[0].start, last_end=g[-1].end) for g in groups]
    for i, c in enumerate(chunks):
        nxt = chunks[i + 1].start if i + 1 < len(chunks) else None
        c.end = nxt if (nxt is not None and nxt - c.last_end < 0.4) else min(c.last_end + 0.35, nxt or total)
        c.end = max(c.end, c.start + 0.2)
    return chunks


# ============================================================================ 5b. animation + render
def ease_out_back(x: float) -> float:
    c1, c3 = 1.70158, 2.70158
    x = min(max(x, 0.0), 1.0)
    return 1 + c3 * (x - 1) ** 3 + c1 * (x - 1) ** 2


def icon_scale(t: float, d: float, pop: float = 0.5, out: float = 0.25) -> float:
    """Pop-in (overshoot) -> hold at exactly 1.0 (cheap: no resize) -> smooth shrink-out."""
    if t < pop:
        s = ease_out_back(t / pop)
    elif t > d - out:
        x = max(0.0, (d - t) / out)
        s = x * x * (3 - 2 * x)
    else:
        s = 1.0
    return max(s, 0.02)


def icon_bob(t: float) -> float:
    return 14.0 * (W / 1080.0) * math.sin(2 * math.pi * t / 2.6)   # floating, translate only


def render_video(voice: Path, words: list[Word], scenes: list[Scene], icons: list[Image.Image],
                 bg: tuple[int, int, int], fg: tuple[int, int, int], out: Path) -> None:
    """One VideoClip + one make_frame(t): PIL composites the active icon + caption on a flat canvas.
    No per-layer clips -> constant memory regardless of video length."""
    audio = AudioFileClip(str(voice))
    total = audio.duration + 0.5
    assign_scene_times(scenes, words, total)
    chunks = build_caption_chunks(words, scenes, total)
    scene_t0 = [s.t0 for s in scenes]
    chunk_t0 = [c.start for c in chunks]
    cap_cache: dict[str, object] = {"i": -1, "img": None}

     
    def make_frame(t: float) -> np.ndarray:
        canvas = Image.new("RGB", (W, H), bg)

        si = bisect.bisect_right(scene_t0, t) - 1
        if si >= 0:
            sc = scenes[si]
            local, d = t - sc.t0, sc.t1 - sc.t0
            if local < d:
                s = icon_scale(local, d)
                icon = icons[si]
                im = icon if abs(s - 1.0) < 0.004 else icon.resize(
                    (max(1, int(icon.width * s)), max(1, int(icon.height * s))), Image.BILINEAR)
                canvas.paste(im, (int(W / 2 - im.width / 2),
                                  int(ICON_CY - im.height / 2 + icon_bob(local))), im)

        ci = bisect.bisect_right(chunk_t0, t) - 1
        if ci >= 0 and t < chunks[ci].end:
            if cap_cache["i"] != ci:
                cap_cache["i"], cap_cache["img"] = ci, render_arabic(chunks[ci].text, fg)
            cap = cap_cache["img"]
            rise = 1.0 - min((t - chunks[ci].start) / 0.15, 1.0)   # caption slides up for 0.15 s
            canvas.paste(cap, (0, int(CAPTION_CY - cap.height / 2 + rise * H * 0.015)), cap)
        return np.asarray(canvas)

    clip = VideoClip(make_frame, duration=total).set_audio(audio)
    try:
        clip.write_videofile(
            str(out), fps=FPS, codec="libx264", audio_codec="aac", audio_bitrate="96k",
            preset="ultrafast", threads=2, logger=None,
            temp_audiofile=str(out.with_suffix(".m4a")), remove_temp=True,
            ffmpeg_params=["-crf", "27", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    finally:
        clip.close()
        audio.close()


# ============================================================================ telegram handlers
def pick_media(msg):
    """-> (kind, file_obj). kind in {'audio', 'image', 'video', None}."""
    if msg.voice:
        return "audio", msg.voice
    if msg.audio:
        return "audio", msg.audio
    if msg.photo:
        return "image", msg.photo[-1]
    if msg.video:
        return "video", msg.video
    if msg.animation:
        return "video", msg.animation
    if msg.video_note:
        return "video", msg.video_note
    if msg.document:
        mime = (msg.document.mime_type or "").lower()
        for prefix, kind in (("audio/", "audio"), ("image/", "image"), ("video/", "video")):
            if mime.startswith(prefix):
                return kind, msg.document
    return None, None


async def handle_media(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    msg = update.effective_message
    kind, obj = pick_media(msg)
    if kind is None:
        return
    is_style = (msg.caption or "").strip().lower().startswith("style")

    if kind in ("image", "video") and not is_style:
        await msg.reply_text("لتعليمي النمط أرسل الصورة/الفيديو مع التعليق: style\n"
                             "To teach me a style, send it with the caption: style")
        return

    status = await msg.reply_text("⏳ في قائمة الانتظار…" if JOB_LOCK.locked() else "⏳ استلمت الملف…")

    async def say(text: str) -> None:
        try:
            await status.edit_text(text)
        except Exception:
            pass

    async with JOB_LOCK:
        work = Path(tempfile.mkdtemp(dir=WORK_ROOT))
        try:
            src = work / "input"
            try:
                await (await obj.get_file()).download_to_drive(src)   # Bot API limit: 20 MB
            except Exception as exc:
                raise UserError(f"تعذّر تنزيل الملف (الحد 20MB). / Download failed: {exc}")

            if kind == "audio":
                await process_audio_job(msg, src, work, say)
            else:
                await process_style_job(src, work, kind, say)
        except UserError as exc:
            await say(f"❌ {exc}")
        except Exception as exc:
            log.exception("Job failed")
            await say(f"❌ خطأ غير متوقع / Unexpected error: {exc}")
        finally:
            shutil.rmtree(work, ignore_errors=True)
            gc.collect()


async def process_style_job(src: Path, work: Path, kind: str, say) -> None:
    await say("👁️ تحليل النمط البصري…")
    frame = src
    if kind == "video":
        frame = work / "frame.jpg"
        try:
            await run_ffmpeg("-ss", "1", "-i", str(src), "-frames:v", "1", "-vf", "scale=768:-2", str(frame))
        except UserError:
            await run_ffmpeg("-i", str(src), "-frames:v", "1", "-vf", "scale=768:-2", str(frame))
    async with httpx.AsyncClient() as client:
        try:
            style, img = await analyze_style(client, frame)
        except (RuntimeError, ValueError, KeyError) as exc:
            raise UserError(f"Vision analysis failed: {exc}")
    STATE.style_prompt = style
    STATE.bg, STATE.fg = derive_palette(img)
    await say(f"✅ تم حفظ النمط / Style saved:\n{style}\n\nBackground: #%02x%02x%02x" % STATE.bg)


async def process_audio_job(msg, src: Path, work: Path, say) -> None:
    style = StyleState(STATE.style_prompt, STATE.bg, STATE.fg)   # snapshot for this job

    await say("✂️ تنظيف الصوت…")
    clean, dur = await prepare_audio(src, work)
    if dur > MAX_AUDIO_SEC:
        raise UserError(f"المقطع طويل ({dur:.0f}s) - الحد {MAX_AUDIO_SEC}s على الخطة المجانية.")

    async with httpx.AsyncClient() as client:
        await say("📝 التفريغ النصي (Groq Whisper)…")
        words = await groq_transcribe(client, clean)
        if len(words) < 3:
            raise UserError("لم أستطع التعرف على كلام كافٍ. / Not enough speech recognised.")

        await say("🧠 تحليل المشاهد…")
        scenes = await plan_scenes(client, words)

        await say(f"🎨 توليد الأيقونات بالنمط المحفوظ ({', '.join(s.concept for s in scenes)})…")
        icons = await generate_icons(client, scenes, style)

    await say("🎬 تركيب الفيديو… (الخطة المجانية بطيئة، انتظر قليلاً)")
    out = work / "short.mp4"
    await asyncio.to_thread(render_video, clean, words, scenes, icons, style.bg, style.fg, out)
    del icons
    gc.collect()

    size_mb = out.stat().st_size / 1024 / 1024
    if size_mb > 49:
        raise UserError(f"الفيديو كبير ({size_mb:.0f}MB) تجاوز حد تيليجرام. جرّب مقطعاً أقصر.")
    with open(out, "rb") as fh:
        await msg.reply_video(fh, width=W, height=H, supports_streaming=True,
                              caption="🎬 " + " • ".join(s.concept for s in scenes),
                              read_timeout=300, write_timeout=300)
    await say("✅ تم / Done")


async def cmd_start(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(
        "• أرسل ملاحظة صوتية لإنشاء الفيديو.\n"
        "• أرسل صورة/فيديو بتعليق «style» لتعليمي نمط الرسم.\n"
        "• /style لعرض النمط الحالي، /resetstyle للعودة للافتراضي.\n\n"
        "Send a voice note to make a video; send an image/video captioned 'style' to set the look.")


async def cmd_style(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(f"CURRENT_STYLE_PROMPT:\n{STATE.style_prompt}\n\nBG: #%02x%02x%02x" % STATE.bg)


async def cmd_reset(update: Update, _: ContextTypes.DEFAULT_TYPE) -> None:
    global STATE
    STATE = StyleState()
    await update.message.reply_text("تمت إعادة النمط الافتراضي. / Style reset.")


# ============================================================================ web server + lifecycle
async def health(_: web.Request) -> web.Response:
    return web.Response(text="OK")


async def keepalive() -> None:
    """Render free services sleep after ~15 min without inbound HTTP; ping our own public URL."""
    url = os.environ.get("RENDER_EXTERNAL_URL")
    if not url:
        return
    async with httpx.AsyncClient() as c:
        while True:
            await asyncio.sleep(600)
            try:
                await c.get(url, timeout=20)
            except Exception:
                pass


async def ensure_font() -> None:
    if FONT_PATH.exists():
        return
    FONT_PATH.parent.mkdir(parents=True, exist_ok=True)
    async with httpx.AsyncClient(follow_redirects=True) as c:
        for url in FONT_URLS:
            try:
                r = await c.get(url, timeout=60)
                if r.status_code == 200 and len(r.content) > 50_000:
                    FONT_PATH.write_bytes(r.content)
                    log.info("Downloaded Arabic font.")
                    return
            except httpx.HTTPError as exc:
                log.warning("Font download failed: %s", exc)
    sys.exit(f"Arabic font missing: place a TTF at {FONT_PATH}")


async def amain() -> None:
    # 1) bind the port first so Render's health check passes immediately
    web_app = web.Application()
    web_app.router.add_get("/", health)
    web_app.router.add_get("/healthz", health)
    runner = web.AppRunner(web_app)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", PORT).start()
    log.info("Health server on :%s", PORT)

    if not GROQ_API_KEY:
        sys.exit("GROQ_API_KEY env var is required.")
    await ensure_font()

    user_filter = filters.User(user_id=ALLOWED_USER_IDS)
    app = (ApplicationBuilder().token(TELEGRAM_BOT_TOKEN).concurrent_updates(True)
           .connect_timeout(30).read_timeout(60).write_timeout(300).pool_timeout(30).build())
    app.add_handler(CommandHandler("start", cmd_start, filters=user_filter))
    app.add_handler(CommandHandler("style", cmd_style, filters=user_filter))
    app.add_handler(CommandHandler("resetstyle", cmd_reset, filters=user_filter))
    app.add_handler(MessageHandler(
        user_filter & (filters.VOICE | filters.AUDIO | filters.PHOTO | filters.VIDEO |
                       filters.ANIMATION | filters.VIDEO_NOTE | filters.Document.ALL), handle_media))

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass

    await app.initialize()
    await app.start()
    await app.updater.start_polling(drop_pending_updates=True)
    ka = asyncio.create_task(keepalive())
    log.info("Bot polling.")
    try:
        await stop.wait()
    finally:
        ka.cancel()
        await app.updater.stop()
        await app.stop()
        await app.shutdown()
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(amain())
  
