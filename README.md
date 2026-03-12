# Sorting Hat

A command-line tool that uses AI to suggest descriptive filenames based on file contents. Features an animated ASCII Hat that "thinks" while streaming the LLM's reasoning tokens, then reveals the suggested name.


```
  ┌──────────────────────────────────────────────────┐
  │ Hmm, this appears to be a sunset photograph      │
  │ taken over a mountain range...                   │
  └──┐───────────────────────────────────────────────┘
     │
     ╰─┐
       |
        /\
       /  '.
      / .-'
     | o  o |
     / ~~~~ \
  __/````````\__
    IMG_3847.jpg
```
Works with any OpenAI-compatible API: local servers (llama.cpp, Ollama, vLLM, LM Studio) or cloud providers (OpenAI, Together, etc).

### Demo  


![Visual demonstration of hat](./hat.gif)  


## Features

- Animated Sorting Hat with drop animation, blinking eyes, and streaming thought bubble
- Supports both text files and images (via vision/multimodal models)
- Auto-detects image files by extension
- Handles reasoning/thinking tokens from models like Qwen, DeepSeek, etc.
- Quiet mode for scripting (`--quiet` / `-q`)
- Disable reasoning/thinking tokens (`--nothink`) for faster inference or models that don't support them
- Batch processing for entire directories (processes files sequentially)
- Interactive rename with confirmation
- Preserves original file extension by default

## Requirements

- Bash 4+
- Python 3.6+
- An OpenAI-compatible LLM API endpoint
- For image naming: a vision-capable model (e.g., GPT-4o, LLaVA, Qwen-VL)

## Installation

```bash
# Clone the repo
git clone https://github.com/marksverdhei/sorting-hat.git
cd sorting-hat

# Option 1: Symlink to your PATH
ln -s "$(pwd)/hat" ~/.local/bin/hat

# Option 2: Copy directly
cp hat ~/.local/bin/hat

# Option 3: Add the repo to PATH
echo 'export PATH="$PATH:'"$(pwd)"'"' >> ~/.bashrc
```

## Configuration

Set these environment variables (or export them in your shell profile):

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_BASE_URL` | `http://localhost:8080` | Base URL of your OpenAI-compatible API |
| `HAT_MODEL` | `gpt-4o` | Model name to use |
| `HAT_API_KEY` | *(empty)* | API key (optional, for cloud providers) |

### Example configurations

**llama.cpp** (local, default port):
```bash
export LLM_BASE_URL=http://localhost:8080
export HAT_MODEL=Qwen/Qwen3.5-9b
```

**Ollama**:
```bash
export LLM_BASE_URL=http://localhost:11434
export HAT_MODEL=Qwen/Qwen3.5-9b
```

**vLLM**:
```bash
export LLM_BASE_URL=http://localhost:8000
export HAT_MODEL=Qwen/Qwen3.5-9b
```

**OpenAI**:
```bash
export LLM_BASE_URL=https://api.openai.com
export HAT_MODEL=gpt-4o
export HAT_API_KEY=sk-...
```

**Hugging Face Inference**:
```bash
export LLM_BASE_URL=https://router.huggingface.co/hf-inference
export HAT_MODEL=Qwen/Qwen3.5-9b
export HAT_API_KEY=hf_...
```

## Usage

```bash
# Suggest a name for a file (animated)
hat photo.jpg

# Suggest and prompt to rename
hat --rename IMG_20240301_143022.jpg

# Process all files in a directory
hat --batch ~/Downloads/

# Force image mode for a file
hat --image screenshot.png

# Quiet mode (no animation, for scripting)
hat --quiet document.pdf

# Dry run (show suggestion, don't ask to rename)
hat --dry-run report.txt

# Let the model choose the extension
hat --no-ext mystery-file

# Disable reasoning/thinking tokens
hat --nothink photo.jpg
```

### Scripting

The suggested filename is printed to stdout, while the animation goes to stderr. This means you can capture just the name:

```bash
# Capture the suggested name
new_name=$(hat --quiet photo.jpg)
echo "Suggested: $new_name"

# Rename all files in a directory
for f in ~/unsorted/*; do
  suggested=$(hat --quiet "$f")
  [ -n "$suggested" ] && mv "$f" "$(dirname "$f")/$suggested"
done
```

## How it works

1. **File analysis**: For text files, reads the first 4KB of content. For images, base64-encodes and sends via the OpenAI multimodal format.
2. **LLM query**: Sends the content to your configured LLM with a prompt asking for a descriptive kebab-case filename.
3. **Streaming display**: Shows the model's reasoning tokens in a speech bubble above the animated hat (supports both `reasoning_content` field and `<think>` tags).
4. **Name sanitization**: Cleans the response into a valid filename (lowercase, hyphens, no special characters).

## The Animation

The Sorting Hat drops onto the filename, thinks with animated eye blinks and a streaming thought bubble, then reveals the new name with a happy face:

- **Drop phase**: Hat falls from above onto the filename
- **Thinking phase**: Eyes blink, mouth animates, thought bubble streams reasoning tokens
- **Reveal phase**: Happy face, green result in bubble and below the hat

Use `--quiet` to skip the animation entirely.

## License

MIT
