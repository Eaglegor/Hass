"""Stream 'wake word + command' to the central wake-word + STT containers over Wyoming.

Usage (from this directory; needs the wake-word, stt and tts containers up):
    docker run --rm --network host -v "$PWD":/h python:3.12-slim sh -c '
      pip install -q numpy scipy wyoming && cd /h &&
      python gen.py "hey jarvis" en v3_en en_0 wake_en0.wav &&
      python gen.py "включи свет на кухне" ru v5_ru xenia cmd_ru.wav &&
      python detect.py /h/wake_en0.wav hey_jarvis 0'
Args: <wake wav> <wake word model name> <gap seconds between wake word and command>.
Replace the generated wavs with real 16 kHz mono recordings of yourself for a
meaningful number -- synthetic TTS only shows the mechanism.

Measures (1) how long after the wake word ENDS the detection fires, (2) what STT hears for
different pre-roll sizes (audio kept from before the detection point, as HA's
audio_seconds_to_buffer would forward it)."""
import asyncio, sys, wave
import numpy as np
from wyoming.client import AsyncTcpClient
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.wake import Detect, Detection, NotDetected
from wyoming.asr import Transcribe, Transcript
from wyoming.info import Describe, Info

RATE, CHUNK = 16000, 512  # 32 ms

def load(path):
    with wave.open(path) as w: return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)

def silence(sec, seed=0):  # faint noise, not digital zero
    return (np.random.default_rng(seed).normal(0, 12, int(sec * RATE))).astype(np.int16)

def chunks(a):
    for i in range(0, len(a), CHUNK):
        yield i, a[i:i + CHUNK]

async def detect(stream, name):
    """Return detection timestamp in ms (stream position), or None."""
    c = AsyncTcpClient("127.0.0.1", 10400)
    await c.connect()
    await c.write_event(Detect(names=[name]).event())
    await c.write_event(AudioStart(rate=RATE, width=2, channels=1).event())
    found = []
    async def reader():
        while True:
            ev = await c.read_event()
            if ev is None: return
            if Detection.is_type(ev.type): found.append(Detection.from_event(ev)); return
            if NotDetected.is_type(ev.type): return
    rt = asyncio.create_task(reader())
    for i, ch in chunks(stream):
        await c.write_event(AudioChunk(rate=RATE, width=2, channels=1, audio=ch.tobytes(), timestamp=int(i * 1000 / RATE)).event())
        await asyncio.sleep(0.002)
        if found: break
    if not found:
        await c.write_event(AudioStop().event())
        try: await asyncio.wait_for(rt, 5)
        except asyncio.TimeoutError: pass
    rt.cancel(); await c.disconnect()
    return found[0] if found else None

async def transcribe(audio, lang="ru"):
    c = AsyncTcpClient("127.0.0.1", 10300)
    await c.connect()
    await c.write_event(Transcribe(language=lang).event())
    await c.write_event(AudioStart(rate=RATE, width=2, channels=1).event())
    for i, ch in chunks(audio):
        await c.write_event(AudioChunk(rate=RATE, width=2, channels=1, audio=ch.tobytes()).event())
    await c.write_event(AudioStop().event())
    while True:
        ev = await asyncio.wait_for(c.read_event(), 30)
        if ev is None: return None
        if Transcript.is_type(ev.type):
            t = Transcript.from_event(ev).text; await c.disconnect(); return t

async def main(wake_wav, name, gap_s):
    wake, cmd = load(wake_wav), load("/h/cmd_ru.wav")
    lead = silence(1.0, 1)
    stream = np.concatenate([lead, wake, silence(gap_s, 2) if gap_s > 0 else np.zeros(0, np.int16), cmd, silence(2.0, 3)])
    wake_end = len(lead) + len(wake)
    cmd_start = wake_end + int(gap_s * RATE)
    print(f"\n### {wake_wav.split('/')[-1]}  model={name}  gap wake->command={gap_s:.1f}s")
    print(f"wake word ends at {wake_end/RATE*1000:.0f} ms; command starts at {cmd_start/RATE*1000:.0f} ms (command {len(cmd)/RATE:.2f}s)")
    d = await detect(stream, name)
    if d is None:
        print("NOT DETECTED"); return
    det_ms = d.timestamp
    print(f"Detection event: name={d.name} timestamp={det_ms}")
    if det_ms is None: return
    det = int(det_ms * RATE / 1000)
    print(f"detection fires {(det_ms - wake_end/RATE*1000):+.0f} ms after the wake word ended  ->  command audio already elapsed at detection: {max(0,(det-cmd_start))/RATE*1000:.0f} ms")
    # What STT hears for different pre-roll sizes: audio from (detection - N) to end of stream.
    for pre in (0.0, 0.2, 0.4, 0.6, 0.8, 1.2):
        start = max(0, det - int(pre * RATE))
        txt = await transcribe(stream[start:])
        print(f"  pre-roll {pre:>3.1f}s -> STT: {txt!r}")
    ref = await transcribe(np.concatenate([cmd, silence(1.0, 4)]))
    print(f"  reference (command alone) -> STT: {ref!r}")

if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2], float(sys.argv[3])))
