#!/usr/bin/env bats
# test.sh — bats tests for hat
# Run: bats test.sh

load '/usr/lib/bats/bats-support/load'
load '/usr/lib/bats/bats-assert/load'

setup_file() {
  export HAT="$BATS_TEST_DIRNAME/hat"
  export TEST_ASSETS="$BATS_TEST_DIRNAME/test-assets"

  # Source testable bash functions
  eval "$(sed -n '/^filename_needs_renaming/,/^}/p' "$HAT")"
  eval "$(sed -n '/^sanitize_name/,/^}/p' "$HAT")"
  eval "$(sed -n '/^is_binary/,/^}/p' "$HAT")"
  eval "$(sed -n '/^collect_metadata/,/^}/p' "$HAT")"
  export -f filename_needs_renaming sanitize_name is_binary collect_metadata

  # Start mock LLM server
  export MOCK_PORT=18950
  export MOCK_DIR=$(mktemp -d)
  python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, os
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        msg = body['messages'][0]
        content = msg['content'] if isinstance(msg['content'], str) else msg['content'][-1]['text']
        with open('${MOCK_DIR}/last_prompt.txt', 'w') as f:
            f.write(content)
        resp = json.dumps({'choices': [{'message': {'content': 'suggested-name'}}]})
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(resp.encode())
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', ${MOCK_PORT}), Handler).serve_forever()
" &
  export MOCK_PID=$!
  sleep 0.5
}

teardown_file() {
  kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$MOCK_DIR"
}

# ── Guard clause ─────────────────────────────────────────────────────

@test "guard: IMG_1234.jpg needs renaming" {
  run filename_needs_renaming "IMG_1234.jpg"
  assert_success
}

@test "guard: DSC_0001.png needs renaming" {
  run filename_needs_renaming "DSC_0001.png"
  assert_success
}

@test "guard: PXL_20240301.jpg needs renaming" {
  run filename_needs_renaming "PXL_20240301.jpg"
  assert_success
}

@test "guard: Screenshot_2024-01-01.png needs renaming" {
  run filename_needs_renaming "Screenshot_2024-01-01.png"
  assert_success
}

@test "guard: 20240301_143022.jpg needs renaming" {
  run filename_needs_renaming "20240301_143022.jpg"
  assert_success
}

@test "guard: hex string needs renaming" {
  run filename_needs_renaming "abcdef1234abcd.txt"
  assert_success
}

@test "guard: WhatsApp file needs renaming" {
  run filename_needs_renaming "IMG-20240301-WA0001.jpg"
  assert_success
}

@test "guard: descriptive name is kept" {
  run filename_needs_renaming "quarterly-finance-report.pdf"
  assert_failure
}

@test "guard: hello-world.py is kept" {
  run filename_needs_renaming "hello-world.py"
  assert_failure
}

@test "guard: project-proposal.txt is kept" {
  run filename_needs_renaming "project-proposal.txt"
  assert_failure
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

# ── Integration: mock LLM ───────────────────────────────────────────

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

@test "integration: batch guard skips good names" {
  run bash "$HAT" --quiet --dry-run --batch "$TEST_ASSETS/"
  assert_output --partial "looks good, skipping"
}

@test "integration: --force overrides guard" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:$MOCK_PORT bash '$HAT' --quiet --dry-run --force --batch '$TEST_ASSETS/' 2>&1"
  refute_output --partial "looks good, skipping"
}

@test "integration: connection error shows clear message" {
  run bash -c "LLM_BASE_URL=http://127.0.0.1:19999 bash '$HAT' --quiet --dry-run --force '$TEST_ASSETS/sample.txt' 2>&1"
  assert_output --partial "could not reach LLM"
  refute_output --partial "Traceback"
}
