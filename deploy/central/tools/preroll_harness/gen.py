"""Generate test audio with the running Silero TTS: English wake phrase + Russian command, 16 kHz mono int16."""
import io, json, sys, urllib.request, wave
import numpy as np
from scipy.signal import resample_poly

def tts(text, language, model_id, voice):
    body = json.dumps({"text": text, "language": language, "model_id": model_id, "voice": voice, "sample_rate": 48000}).encode()
    r = urllib.request.Request("http://127.0.0.1:8014/tts", body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=120) as resp:
        data = resp.read()
    with wave.open(io.BytesIO(data)) as w:
        sr, ch = w.getframerate(), w.getnchannels()
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    if ch > 1: pcm = pcm.reshape(-1, ch).mean(axis=1)
    out = resample_poly(pcm, 16000, sr)
    return np.clip(out, -32768, 32767).astype(np.int16)

def trim(x, thresh=300):
    idx = np.where(np.abs(x) > thresh)[0]
    return x[idx[0]:idx[-1] + 1] if len(idx) else x

if __name__ == "__main__":
    phrase, lang, model, voice, out = sys.argv[1:6]
    a = trim(tts(phrase, lang, model, voice))
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(a.tobytes())
    print(f"{out}: {len(a)/16000:.2f}s  peak={np.abs(a).max()}")
