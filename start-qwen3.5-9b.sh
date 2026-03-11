#!/bin/bash
set -e

MODEL_DIR="${MODEL_DIR:-/Volumes/Sandisk_1TB/Models/mlx-community/Qwen3.5-9B-MLX-4bit}"

exec ./zig-out/bin/mlx-serve \
    --model "$MODEL_DIR" \
    --serve \
    --log-level info \
    "$@"
