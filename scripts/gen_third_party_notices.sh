#!/usr/bin/env bash
# Regenerates Support/ThirdPartyNotices.txt from the licence files of the code
# that is compiled into Susurro.app. `make app` copies the result into
# Contents/Resources, and About Susurro → "Licenses…" opens it.
# Run after bumping whisper.cpp or FluidAudio: scripts/gen_third_party_notices.sh
set -euo pipefail
cd "$(dirname "$0")/.."
FA=.build/checkouts/FluidAudio
[ -f "$FA/LICENSE" ] || { echo "✗ $FA missing — run 'swift build' first" >&2; exit 1; }
FA_VER=$(sed -n '/"identity" : "fluidaudio"/,/version/p' Package.resolved | sed -n 's/.*"version" : "\(.*\)".*/\1/p')
WC_VER=$(git -C vendor/whisper.cpp describe --tags --always 2>/dev/null || echo unknown)
out=Support/ThirdPartyNotices.txt
section() { printf '\n\n==============================================================================\n%s\n==============================================================================\n\n' "$1"; }
{
cat <<'EOF'
Susurro — third-party notices

Susurro includes, or links statically against, the software listed below.
Each component is used under its licence, reproduced in full in this file.

Speech models are not bundled. They are downloaded from Hugging Face only
when you choose them:
  • OpenAI Whisper models (ggml conversions by the whisper.cpp project): MIT.
  • NVIDIA Parakeet TDT 0.6B v2 © NVIDIA, licensed under CC-BY-4.0
    (https://creativecommons.org/licenses/by/4.0/). Core ML conversion by
    FluidInference (huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml).
    No changes were made to the model weights.
EOF
section "whisper.cpp and ggml ($WC_VER) — MIT License — https://github.com/ggerganov/whisper.cpp"
cat vendor/whisper.cpp/LICENSE
section "FluidAudio ($FA_VER) — Apache License 2.0 — https://github.com/FluidInference/FluidAudio"
cat "$FA/LICENSE"
section "fastcluster (compiled into FluidAudio) — BSD 2-Clause License"
cat "$FA/ThirdPartyLicenses/fastcluster-LICENSE.md"
section "VBx (portions used by FluidAudio) — Apache License 2.0"
cat "$FA/ThirdPartyLicenses/vbx-LICENSE.md"
} > "$out"
echo "✓ $out ($(wc -l < "$out" | tr -d ' ') lines)"
