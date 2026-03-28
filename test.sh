#!/usr/bin/env bats
# test.sh — bats tests for hat
# Run: bats test.sh

load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-assert/load'

setup_file() {
  export HAT="$BATS_TEST_DIRNAME/hat"
  export TEST_ASSETS="$BATS_TEST_DIRNAME/test-assets"

  # Source testable bash functions
  eval "$(sed -n '/^sanitize_name/,/^}/p' "$HAT")"
  eval "$(sed -n '/^is_binary/,/^}/p' "$HAT")"
  eval "$(sed -n '/^is_image/,/^}/p' "$HAT")"
  eval "$(sed -n '/^is_audio/,/^}/p' "$HAT")"
  eval "$(sed -n '/^collect_metadata/,/^}/p' "$HAT")"
  export -f sanitize_name is_binary is_image is_audio collect_metadata

  # Start mock LLM server that handles multi-turn conversations
  export MOCK_PORT=18950
  export MOCK_DIR=$(mktemp -d)
  python3 - "$MOCK_PORT" "$MOCK_DIR" <<'MOCKSERVER' &
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, os

MOCK_DIR = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        msgs = body['messages']
        last_msg = msgs[-1]
        content = last_msg['content'] if isinstance(last_msg['content'], str) else last_msg['content'][-1]['text']

        # Save last prompt for inspection
        with open(os.path.join(MOCK_DIR, 'last_prompt.txt'), 'w') as f:
            f.write(content)
        with open(os.path.join(MOCK_DIR, 'last_request.json'), 'w') as f:
            json.dump(body, f, indent=2)

        # Determine response based on request type
        if 'already' in content and ('YES' in content or 'NO' in content):
            # Check call: read override file if present, otherwise default NO
            override = os.path.join(MOCK_DIR, 'check_response')
            if os.path.exists(override):
                answer = open(override).read().strip()
            else:
                answer = 'NO'
        else:
            # Naming call
            answer = 'suggested-name'

        resp = json.dumps({'choices': [{'message': {'content': answer}}]})
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass

HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
MOCKSERVER
  export MOCK_PID=$!
  sleep 0.5
}

teardown_file() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$MOCK_DIR"
}

# ── Sanitize name ───────────────────────────────────────────────────

@test "sanitize: preserves same extension" {
  run sanitize_name "sunset-view.jpg" "true" "jpg"
  assert_output "sunset-view.jpg"
}

@test "sanitize: strips wrong ext, appends original" {
  run sanitize_name "sunset-view.png" "true" "jpg"
  assert_output "sunset-view.jpg"
}

@test "sanitize: appends ext to bare stem" {
  run sanitize_name "sunset-view" "true" "jpg"
  assert_output "sunset-view.jpg"
}

@test "sanitize: cleans special characters" {
  run sanitize_name "Sunset View!" "true" "png"
  assert_output "Sunset-View.png"
}

@test "sanitize: no-ext mode keeps model extension" {
  run sanitize_name "cool-photo.webp" "false" ""
  assert_output "cool-photo.webp"
}

@test "sanitize: strips backticks" {
  run sanitize_name '```sunset-view```' "true" "jpg"
  assert_output "sunset-view.jpg"
}

@test "sanitize: strips think tags" {
  run sanitize_name "<think>reasoning</think>sunset-view" "true" "pdf"
  assert_output "sunset-view.pdf"
}

# ── Sanitize name: additional edge cases ───────────────────────────

@test "sanitize: collapses multiple spaces/hyphens to single hyphen" {
  run sanitize_name "my  report  doc" "true" "pdf"
  assert_output "my-report-doc.pdf"
}

@test "sanitize: strips surrounding quotes" {
  run sanitize_name '"quoted-name"' "true" "txt"
  assert_output "quoted-name.txt"
}

@test "sanitize: multiline input uses last non-empty line" {
  run sanitize_name $'first-line\nsecond-name' "true" "txt"
  assert_output "second-name.txt"
}

# ── Binary detection ─────────────────────────────────────────────────

@test "binary: text file is not binary" {
  run is_binary "$TEST_ASSETS/sample.txt"
  assert_failure
}

@test "binary: random .bin is binary" {
  run is_binary "$TEST_ASSETS/sample.bin"
  assert_success
}

@test "binary: jpg is binary" {
  run is_binary "$TEST_ASSETS/sample.jpg"
  assert_success
}

@test "binary: html is not binary" {
  run is_binary "$TEST_ASSETS/sample.html"
  assert_failure
}

# ── Image detection ─────────────────────────────────────────────────

@test "image: jpg is detected as image" {
  run is_image "$TEST_ASSETS/sample.jpg"
  assert_success
}

@test "image: jpeg is detected as image" {
  run is_image "$TEST_ASSETS/sample.jpeg"
  assert_success
}

@test "image: png is detected as image" {
  run is_image "$TEST_ASSETS/sample.png"
  assert_success
}

@test "image: gif is detected as image" {
  run is_image "$TEST_ASSETS/sample.gif"
  assert_success
}

@test "image: bmp is detected as image" {
  run is_image "$TEST_ASSETS/sample.bmp"
  assert_success
}

@test "image: tiff is detected as image" {
  run is_image "$TEST_ASSETS/sample.tiff"
  assert_success
}

@test "image: svg is detected as image (extension fallback)" {
  run is_image "$TEST_ASSETS/sample.svg"
  assert_success
}

@test "image: webp is detected as image" {
  run is_image "$TEST_ASSETS/sample.webp"
  assert_success
}

@test "image: text file is not an image" {
  run is_image "$TEST_ASSETS/sample.txt"
  assert_failure
}

@test "image: html file is not an image" {
  run is_image "$TEST_ASSETS/sample.html"
  assert_failure
}

@test "image: binary .bin is not an image" {
  run is_image "$TEST_ASSETS/sample.bin"
  assert_failure
}

# ── Image integration ─────────────────────────────────────────────────

@test "image: jpg is processed as image (not skipped as binary)" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.jpg' 2>/dev/null"
  assert_output "suggested-name.jpg"
}

@test "image: png is processed as image (not skipped as binary)" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.png' 2>/dev/null"
  assert_output "suggested-name.png"
}

# ── Metadata collection ─────────────────────────────────────────────

@test "metadata: text file has size and modified" {
  run collect_metadata "$TEST_ASSETS/sample.txt" "text"
  assert_output --partial "size_bytes"
  assert_output --partial "modified"
}

@test "metadata: text file has no exif" {
  run collect_metadata "$TEST_ASSETS/sample.txt" "text"
  refute_output --partial "exif"
}

# ── Help output ──────────────────────────────────────────────────────

@test "help: shows all flags" {
  run bash "$HAT" --help
  assert_output --partial "--context"
  assert_output --partial "--no-metadata"
  assert_output --partial "--force"
  assert_output --partial "--nothink"
  assert_output --partial "--quiet"
  assert_output --partial "--batch"
}

# ── Integration: naming with --force (single turn) ──────────────────

@test "integration: basic naming returns sanitized result" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt' 2>/dev/null"
  assert_output "suggested-name.txt"
}

@test "integration: --context reaches prompt" {
  bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force -c 'marketing Q3' '$TEST_ASSETS/sample.txt'" >/dev/null 2>&1
  run cat "$MOCK_DIR/last_prompt.txt"
  assert_output --partial "Additional context: marketing Q3"
}

@test "integration: metadata in prompt by default" {
  bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt'" >/dev/null 2>&1
  run cat "$MOCK_DIR/last_prompt.txt"
  assert_output --partial "File metadata:"
}

@test "integration: --no-metadata excludes metadata" {
  bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --no-metadata '$TEST_ASSETS/sample.txt'" >/dev/null 2>&1
  run cat "$MOCK_DIR/last_prompt.txt"
  refute_output --partial "File metadata:"
}

@test "integration: extension isolation in prompt" {
  bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt'" >/dev/null 2>&1
  run cat "$MOCK_DIR/last_prompt.txt"
  assert_output --partial "Do NOT include any file extension"
}

@test "integration: binary files are skipped" {
  run bash "$HAT" --quiet --dry-run --force "$TEST_ASSETS/sample.bin"
  assert_output --partial "skipping"
}

# ── Integration: LLM-based guard clause (two-turn) ──────────────────

@test "guard: LLM check says NO → proceeds to rename" {
  echo "NO" > "$MOCK_DIR/check_response"
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run '$TEST_ASSETS/sample.txt' 2>/dev/null"
  assert_output "suggested-name.txt"
}

@test "guard: LLM check says YES → skips file" {
  echo "YES" > "$MOCK_DIR/check_response"
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run '$TEST_ASSETS/sample.txt' 2>&1"
  assert_output --partial "already good, skipping"
}

@test "guard: --force skips LLM check entirely" {
  echo "YES" > "$MOCK_DIR/check_response"
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt' 2>/dev/null"
  assert_output "suggested-name.txt"
}

@test "guard: two-turn naming has 3 messages (check context)" {
  echo "NO" > "$MOCK_DIR/check_response"
  bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run '$TEST_ASSETS/sample.txt'" >/dev/null 2>&1
  run python3 -c "import json; d=json.load(open('$MOCK_DIR/last_request.json')); print(len(d['messages']))"
  assert_output "3"
}

# ── Integration: error handling ──────────────────────────────────────

@test "integration: connection error shows clear message" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:19999 bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt' 2>&1"
  assert_output --partial "could not reach LLM"
  refute_output --partial "Traceback"
}

# ── Audio detection ──────────────────────────────────────────────────

@test "audio: mp3 is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.mp3"
  assert_success
}

@test "audio: wav is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.wav"
  assert_success
}

@test "audio: flac is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.flac"
  assert_success
}

@test "audio: ogg is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.ogg"
  assert_success
}

@test "audio: aac is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.aac"
  assert_success
}

@test "audio: m4a is detected as audio" {
  run is_audio "$TEST_ASSETS/sample.m4a"
  assert_success
}

@test "audio: text file is not audio" {
  run is_audio "$TEST_ASSETS/sample.txt"
  assert_failure
}

@test "audio: image file is not audio" {
  run is_audio "$TEST_ASSETS/sample.jpg"
  assert_failure
}

# ── ftyp-box brand discrimination (regression: HEIC / MP4 video / MOV
# / 3GP all carry the ftyp marker. Major brand at bytes 8-11 is what
# distinguishes audio from video/image — the brand check must reject
# everything except M4A / M4B / M4P.) ─────────────────────────────────

@test "audio: MP4 isom container is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.mp4)
  # 8B box size + "ftyp" + "isom" + 4 bytes filler
  printf '\x00\x00\x00\x20ftypisom\x00\x00\x02\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: MP4 mp42 container is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.mp4)
  printf '\x00\x00\x00\x20ftypmp42\x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: QuickTime mov is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.mov)
  printf '\x00\x00\x00\x20ftypqt  \x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: HEIC iPhone photo is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.heic)
  printf '\x00\x00\x00\x20ftypheic\x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: HEIF mif1 brand is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.heif)
  printf '\x00\x00\x00\x20ftypmif1\x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: 3GP is NOT audio" {
  local tmp; tmp=$(mktemp --suffix=.3gp)
  printf '\x00\x00\x00\x20ftyp3gp4\x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_failure
}

@test "audio: synthetic M4A brand IS audio" {
  local tmp; tmp=$(mktemp --suffix=.m4a)
  printf '\x00\x00\x00\x20ftypM4A \x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_success
}

@test "audio: M4B audiobook IS audio" {
  local tmp; tmp=$(mktemp --suffix=.m4b)
  printf '\x00\x00\x00\x20ftypM4B \x00\x00\x00\x00' > "$tmp"
  run is_audio "$tmp"
  rm -f "$tmp"
  assert_success
}

# ── Audio metadata ───────────────────────────────────────────────────

@test "audio metadata: mp3 has size and modified" {
  run collect_metadata "$TEST_ASSETS/sample.mp3" "audio"
  assert_output --partial "size_bytes"
  assert_output --partial "modified"
}

@test "audio metadata: mp3 has mime_type" {
  run collect_metadata "$TEST_ASSETS/sample.mp3" "audio"
  assert_output --partial "mime_type"
}

# ── Audio integration ────────────────────────────────────────────────

@test "audio: mp3 is processed (not skipped as binary)" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.mp3' 2>/dev/null"
  assert_output "suggested-name.mp3"
}

@test "audio: flac is processed (not skipped as binary)" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.flac' 2>/dev/null"
  assert_output "suggested-name.flac"
}

@test "audio: wav is processed (not skipped as binary)" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.wav' 2>/dev/null"
  assert_output "suggested-name.wav"
}

# ── Preview flag ─────────────────────────────────────────────────────

@test "preview: --preview shows content preview on stderr for text file" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --preview '$TEST_ASSETS/sample.txt' 2>&1 >/dev/null"
  assert_output --partial "preview:"
  assert_output --partial "sample.txt"
}

@test "preview: --preview shows line count for text file" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --preview '$TEST_ASSETS/sample.txt' 2>&1 >/dev/null"
  assert_output --partial "lines total"
}

@test "preview: -p shorthand works" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force -p '$TEST_ASSETS/sample.txt' 2>&1 >/dev/null"
  assert_output --partial "preview:"
}

@test "preview: without --preview no preview header on stderr" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt' 2>&1 >/dev/null"
  refute_output --partial "preview:"
}

@test "preview: --preview still produces correct suggestion on stdout" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --preview '$TEST_ASSETS/sample.txt' 2>/dev/null"
  assert_output "suggested-name.txt"
}

@test "preview: --preview works with audio file" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --preview '$TEST_ASSETS/sample.mp3' 2>&1 >/dev/null"
  assert_output --partial "preview:"
  assert_output --partial "sample.mp3"
}
