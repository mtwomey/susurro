#!/usr/bin/env python3
"""Show that trailing padding changes Parakeet's normalised mel features of the speech itself (BEA-643).
Usage: uv run --with coremltools --with numpy scripts/mel_norm_probe.py <Preprocessor.mlmodelc> <clip.wav>"""
import sys, wave, numpy as np, coremltools as ct
m = ct.models.CompiledMLModel(sys.argv[1])
w = wave.open(sys.argv[2]); a = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
def mel(x):
    buf = np.zeros((1, 240000), np.float32); buf[0, :len(x)] = x
    o = m.predict({"audio_signal": buf, "audio_length": np.array([len(x)], np.int32)})
    return o["mel"][0], int(o["mel_length"][0])
base, n = mel(a)
print("speech frames", n, "mel shape", base.shape)
for ms in (0, 100, 500, 1000, 1500):
    p, k = mel(np.concatenate([a, np.zeros(ms * 16, np.float32)]))
    d = np.abs(p[:, :n - 2] - base[:, :n - 2])  # speech region only
    print(f"pad {ms:4d} ms: frames {k}, speech-region mel change mean {d.mean():.3f} max {d.max():.3f}; per-band mean shift {np.abs(p[:, :n-2].mean(1) - base[:, :n-2].mean(1)).mean():.3f}")
