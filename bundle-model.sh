#!/bin/bash
# Download and bundle the small.en WhisperKit CoreML model into the project.
# Run this once before building to include the model in the app bundle.
# Usage: ./bundle-model.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="$SCRIPT_DIR/Sources/HushType/Resources/Models"
MODEL_NAME="openai_whisper-small.en"

echo "=== Bundling WhisperKit model: small.en ==="

# Check if the model is already bundled
if [ -d "$MODEL_DIR/$MODEL_NAME" ] && [ "$(ls -A "$MODEL_DIR/$MODEL_NAME" 2>/dev/null)" ]; then
    echo "Model already bundled at: $MODEL_DIR/$MODEL_NAME"
    echo "To re-download, delete that folder first."
    du -sh "$MODEL_DIR/$MODEL_NAME"
    exit 0
fi

# Search known locations where WhisperKit / HuggingFace store downloaded models
SEARCH_DIRS=(
    "$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml"
    "$HOME/.cache/huggingface/hub/models--argmaxinc--whisperkit-coreml"
    "$HOME/huggingface/models/argmaxinc/whisperkit-coreml"
)

CACHED_MODEL=""
for SEARCH_DIR in "${SEARCH_DIRS[@]}"; do
    if [ -d "$SEARCH_DIR" ]; then
        echo "Searching: $SEARCH_DIR"
        FOUND=$(find "$SEARCH_DIR" -type d -name "$MODEL_NAME" 2>/dev/null | head -1)
        if [ -n "$FOUND" ] && [ -d "$FOUND" ]; then
            CACHED_MODEL="$FOUND"
            break
        fi
    fi
done

if [ -n "$CACHED_MODEL" ] && [ -d "$CACHED_MODEL" ]; then
    echo "Found cached model at: $CACHED_MODEL"
    mkdir -p "$MODEL_DIR"
    echo "Copying to project…"
    cp -R "$CACHED_MODEL" "$MODEL_DIR/$MODEL_NAME"
    echo "Done!"
else
    echo "Model not found in any known cache location."
    echo ""
    echo "Searched:"
    for d in "${SEARCH_DIRS[@]}"; do echo "  $d"; done
    echo ""
    echo "Launch HushType once to download the model, then re-run this script:"
    echo "  ./bundle-model.sh"
    exit 1
fi

echo ""
echo "=== Model bundled successfully ==="
du -sh "$MODEL_DIR/$MODEL_NAME"
echo ""
echo "The model will be included in the app bundle on next build."
echo "Run ./build-app.sh to create the updated .app bundle."
