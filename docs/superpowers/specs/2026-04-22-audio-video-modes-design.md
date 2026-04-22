# Audio + Video Modes for Sorting Hat

**Status:** approved design, ready for implementation plan
**Date:** 2026-04-22

## Goal

Extend Sorting Hat so that `hat song.mp3` and `hat clip.mp4` produce sensible filename suggestions via a multimodal LLM, reusing the existing guard-clause → naming flow. Today the tool has only `text` and `image` modes. We add `audio` and `video`.

The immediate trigger is that we now have a local multimodal endpoint (Gemma 4 E4B at `http://192.168.8.158:30184/`) that accepts `input_audio` alongside `image_url` parts in a single chat completion. Video-with-sound works by sending K image frames + one audio track in the same message.

## Non-goals

- Long-form video (> ~1 min). No streaming, no chunked processing.
- Frame deduplication, shot detection, VAD, speaker diarization.
- Auto model-swapping based on file type.
- New output formats or API shapes — the renamer flow is unchanged.

## User-visible behavior

- `hat song.mp3` → detects audio, sends audio to LLM, suggests a name.
- `hat clip.mp4` → detects video, extracts frames + audio, suggests a name.
- `hat *` in a mixed directory continues to Just Work (auto-detection, matching the existing image flow).
- New flags `--audio` / `-a` and `--video` / `-v` force mode, mirroring `--image` / `-i`.
- If `ffmpeg` / `ffprobe` is missing and an audio/video file is encountered, the file is skipped with a clear one-line error (not fatal in batch mode).
- If the configured model rejects multimodal content, the user sees the LLM's 400 as they do today for images against a text-only model. No extra guardrail.

## Detection

Extend the magic-byte approach from `is_image`. Mode selection in `process_file` runs in this order:

1. `is_image` (unchanged)
2. `is_audio` (new)
3. `is_video` (new)
4. text (unchanged)
5. binary-skip (unchanged)

Explicit `--image`/`--audio`/`--video` short-circuits detection.

### `is_audio` magic bytes

| Format | Bytes | Notes |
|---|---|---|
| WAV | `RIFF … WAVE` | `52 49 46 46 _ _ _ _ 57 41 56 45` |
| MP3 | `ID3` or `FF Fx` frame sync | |
| FLAC | `fLaC` (`66 4C 61 43`) | |
| OGG | `OggS` (`4F 67 67 53`) | OGG can also carry video; we treat OGG as audio unless ext is `.ogv` |
| AAC | `FF F1` / `FF F9` ADTS sync | |
| M4A | `ftyp` box with brand `M4A ` / `mp42` / `isom` at bytes 4..11 *and* `.m4a` ext (otherwise it's video) |

### `is_video` magic bytes

| Format | Bytes |
|---|---|
| MP4 / MOV | `ftyp` box at bytes 4..7, any brand not claimed by `is_audio` |
| WebM / MKV | `1A 45 DF A3` (EBML) |
| AVI | `RIFF … AVI ` |
| OGV | `.ogv` extension fallback |

`ftyp` brand disambiguation is the trickiest piece: we must look at bytes 8..11 (`major_brand`) and treat `M4A ` as audio and everything else (`isom`, `mp42`, `qt  `, `avc1`, etc.) as video. `.m4a` extension wins when the brand is ambiguous.

## Audio mode

Extend `build_user_content` with a new `mode == "audio"` branch:

1. If the source is already WAV, base64 the bytes directly.
2. Otherwise, transcode to 16 kHz mono 16-bit PCM WAV with `ffmpeg -y -i <file> -ac 1 -ar 16000 -c:a pcm_s16le <tmp.wav>` and base64 the output. Temp file cleaned on exit.
3. Produce content parts:
   ```json
   [
     {"type":"text","text":"<audio-aware prompt>"},
     {"type":"input_audio","input_audio":{"data":"<b64>","format":"wav"}}
   ]
   ```

Audio-aware prompt differs from the text/image prompts in one line:

> "Suggest a single appropriate filename based on the spoken content or sound of this audio."

The existing rule block (kebab-case, no extension, etc.) is reused verbatim.

## Video mode

Video is handled as *frames + optional audio* in a single message — the pattern we validated.

1. Probe duration with `ffprobe -v error -show_entries format=duration -of csv=p=0 <file>`. If probe fails, fall back to 4 frames uniformly across the file.
2. Extract K frames with `ffmpeg -y -i <file> -vf fps=<K/duration> -frames:v <K> <tmp>/frame_%02d.png`. K defaults to 4, configurable via `HAT_VIDEO_FRAMES`.
3. Extract audio track to WAV if present and non-silent:
   - `ffprobe` to check for an audio stream.
   - `ffmpeg -y -i <file> -vn -ac 1 -ar 16000 -c:a pcm_s16le <tmp>/audio.wav`
   - Skip if `HAT_VIDEO_INCLUDE_AUDIO=false`.
4. Produce content parts, text first, then images in order, then audio:
   ```json
   [
     {"type":"text","text":"<video-aware prompt>"},
     {"type":"image_url","image_url":{"url":"data:image/png;base64,…"}},
     … frames 2..K …,
     {"type":"input_audio","input_audio":{"data":"<b64>","format":"wav"}}
   ]
   ```

Video-aware prompt:

> "The following are frames from a short video in order, optionally followed by its audio track. Suggest a single appropriate filename based on what is shown and said."

## Metadata

Extend `collect_metadata`:

- **audio**: `duration_sec`, `sample_rate`, `channels`, `codec`, `bitrate`
- **video**: `duration_sec`, `width`, `height`, `fps`, `video_codec`, `audio_codec`

Source: `ffprobe -v error -show_streams -show_format -of json <file>`. Parsed in Python. Already-present generic metadata (`size_bytes`, `modified`, `mime_type`) stays.

If ffprobe is missing, fall back to the generic metadata only (no hard failure).

## Dependencies

- **ffmpeg**: required for audio (non-WAV) and video. On missing: skip file with `  <name>: ffmpeg required for audio/video, skipping`. Non-fatal in batch.
- **ffprobe**: required to probe duration + audio stream presence for video. Same skip behavior.
- Python stdlib + existing PIL dependency: unchanged.

## Temp file hygiene

Everything written under a per-file `mktemp -d` that is `trap`-removed in bash. Python does not leak its own tempfiles: `build_user_content` already unlinks its temp JSON.

## Guard clause + multi-turn

Unchanged. `build_user_content` returns a JSON file containing a string (text mode) or a list (image/audio/video). `check_filename` and `stream_with_hat` both load it verbatim. The text extraction in `stream_with_hat` (where it pulls the naming prompt out of the first user message for multi-turn reuse) already handles the "list of parts" case by filtering for `type == "text"` — that logic applies unchanged.

## CLI surface

New flags, mirroring `--image`:

| Flag | Action |
|---|---|
| `--audio`, `-a` | Force audio mode |
| `--video`, `-v` | Force video mode |

Short flag collision: `-v` is currently unused. Safe.

New env vars:

| Var | Default | Purpose |
|---|---|---|
| `HAT_VIDEO_FRAMES` | `4` | Number of frames to extract per video |
| `HAT_VIDEO_INCLUDE_AUDIO` | `true` | Include audio track in video requests |

Usage text updated with audio/video examples.

## Testing

`test.sh` (bats) gets:

- `is_audio` / `is_video` detection tests against `test-assets/sample.*`.
- `ftyp`-brand disambiguation test: a minimal mp4 vs an m4a.
- `collect_metadata` test asserting the audio/video keys exist for sample files.
- Mock-server route for audio/video requests: the existing mock returns canned answers and persists `last_request.json`. New assertion: when `sample.wav` is sent, `last_request.json` contains an `input_audio` part. When `sample.mp4` is sent, it contains ≥1 `image_url` parts.
- `test-assets/` gains a tiny generated `sample.mp4` (checked in or generated in `setup_file` with ffmpeg). Prefer generate-in-setup to avoid binary churn.

Existing tests stay green.

## File layout

Still a single file (`hat`). Python heredocs grow, but each new branch is a clear, small addition inside existing Python blocks (`build_user_content`, `collect_metadata`). No refactor in this change.

## Risk & trade-offs

- **Token cost on video**: 4 frames × ~290 prompt tokens + audio. Acceptable for short clips, quadratic-ish for longer ones. Mitigated by the K=4 default and `HAT_VIDEO_FRAMES` knob.
- **ffmpeg hard dep**: new soft requirement for audio/video users. Documented in usage text. Text + image paths remain ffmpeg-free.
- **Model mismatch**: pointing `HAT_MODEL` at a text-only model and running `hat song.mp3` fails with an LLM 400. Same failure mode as images today — no new surface.
- **OGG ambiguity**: treating OGG as audio unless `.ogv` is a heuristic. If it misfires, the `-v` / `-a` override is available.

## Follow-ups (explicitly not this change)

- Auto model probing from `/v1/models`.
- Long-video chunking.
- Subtitle track ingestion.
- A `--frames N` / `--fps N` CLI flag (env var is enough for v1).
