#!/usr/bin/env python3
"""VAD lab — dry-run the planned client-side Silero VAD on real recordings.

This simulates the "conveyor belt" plan: run whisper.cpp's Silero VAD over a
recorded WAV, see where it finds speech, measure how much silence we could cull,
reconstitute the silence-free "kebab" waveform (speech blocks + fixed gaps), and
optionally compare what whisper transcribes for the original vs the kebab — i.e.
where (if anywhere) culling silence changes the words.

It calls the SAME Silero net we'd link into the Swift app
(`whisper-vad-speech-segments`, i.e. whisper_vad_detect_speech), so the segment
boundaries here are exactly what the live cutter would see. Everything runs on
the Metal dev build, NOT the installed ANE app — it never touches the ANE compile
cache or the resident server on :8178.

Usage:
    python3 tools/vad_lab.py [options] [file.wav ...]

    With no files, processes every *.wav in /tmp/speak/wavs.

    --gap MS           inter-block silence in the reconstituted kebab (default 500)
    --threshold N      VAD speech threshold 0..1 (default 0.5)
    --pad MS           speech padding each side of a segment (default 30)
    --min-silence MS   silence shorter than this doesn't split a segment (default 100)
    --min-speech MS    drop speech segments shorter than this (default 250)
    --reconstruct DIR  write kebab WAVs here for listening/inspection
    --transcribe       also run whisper-cli on original + kebab and diff the text
                       (SLOW: reloads the model per call; pass a few files, not all)
    --model PATH       whisper model for --transcribe (default: shared-store medium.en)

Examples:
    python3 tools/vad_lab.py                          # compression report, all clips
    python3 tools/vad_lab.py --reconstruct /tmp/kebab # + write kebab wavs to listen
    python3 tools/vad_lab.py --transcribe /tmp/speak/wavs/recording_1781548291.wav
"""
import os
import sys
import glob
import wave
import struct
import difflib
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
WHISPER = os.path.join(REPO, "whisper.cpp")
VAD_BIN = os.path.join(WHISPER, "build/bin/whisper-vad-speech-segments")
CLI_BIN = os.path.join(WHISPER, "build/bin/whisper-cli")
VAD_MODEL = os.path.join(WHISPER, "models/for-tests-silero-v6.2.0-ggml.bin")
DEFAULT_MODEL = os.path.expanduser(
    "~/Library/Application Support/Speak/models/ggml-medium.en.bin")
WAVS_DIR = "/tmp/speak/wavs"
SR = 16000  # our recordings are always 16kHz mono 16-bit


class Opts:
    gap_ms = 500
    threshold = 0.5
    pad_ms = 30
    min_silence_ms = 100
    min_speech_ms = 250
    reconstruct = None
    transcribe = False
    model = DEFAULT_MODEL


def read_pcm(path):
    """Return (samples:list[int16], duration_s). Asserts our recording format."""
    w = wave.open(path, "rb")
    assert w.getnchannels() == 1 and w.getsampwidth() == 2, "expected mono 16-bit"
    sr = w.getframerate()
    n = w.getnframes()
    raw = w.readframes(n)
    w.close()
    samples = list(struct.unpack("<%dh" % n, raw))
    return samples, sr, n / sr


def write_pcm(path, samples, sr=SR):
    w = wave.open(path, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(struct.pack("<%dh" % len(samples), *samples))
    w.close()


def run_vad(path, o):
    """Run Silero VAD; return list of (start_s, end_s) speech segments."""
    # NOTE: the vad-speech-segments example has a quirky arg parser — only these
    # short flags work. -vt=threshold, -vp=speech-pad-ms, -vsd=MIN-SPEECH-duration
    # (yes, -vsd is min-speech here, an upstream naming bug). min-silence can't be
    # set via this binary (stuck at its 100ms default); we get full param control
    # when we call whisper_vad_segments_from_probs directly from Swift.
    out = subprocess.run(
        [VAD_BIN, "-vm", VAD_MODEL, "-f", path, "-np",
         "-vt", str(o.threshold),
         "-vp", str(o.pad_ms),
         "-vsd", str(o.min_speech_ms)],
        capture_output=True, text=True)
    segs = []
    for line in out.stdout.splitlines():
        # "Speech segment 0: start = 90.00, end = 368.00"  (centiseconds)
        if line.startswith("Speech segment"):
            try:
                rhs = line.split(":", 1)[1]
                start_cs = float(rhs.split("start =")[1].split(",")[0])
                end_cs = float(rhs.split("end =")[1])
                segs.append((start_cs / 100.0, end_cs / 100.0))
            except (IndexError, ValueError):
                pass
    return segs


def kebab(samples, segs, gap_ms):
    """Concatenate speech segments with `gap_ms` of silence between them."""
    gap = [0] * int(gap_ms / 1000.0 * SR)
    out = []
    for i, (s, e) in enumerate(segs):
        a, b = int(s * SR), int(e * SR)
        out.extend(samples[a:b])
        if i < len(segs) - 1:
            out.extend(gap)
    return out


def transcribe(path, model):
    out = subprocess.run(
        [CLI_BIN, "-m", model, "-f", path, "-nt", "-np"],
        capture_output=True, text=True)
    return " ".join(out.stdout.split()).strip()


def windows(dur_s):
    """Whisper processes audio in 30s encoder windows — the latency-relevant unit."""
    return max(1, -(-int(dur_s * 100) // 3000))  # ceil(dur/30)


def report_one(path, o):
    samples, sr, dur = read_pcm(path)
    assert sr == SR, "expected 16kHz"
    segs = run_vad(path, o)
    speech = sum(e - s for s, e in segs)
    kdur = speech + max(0, len(segs) - 1) * (o.gap_ms / 1000.0)
    name = os.path.basename(path)

    print("=== %s ===" % name)
    print("  original:  %5.1fs   %d encoder window(s)" % (dur, windows(dur)))
    print("  speech:    %5.1fs   across %d segment(s)" % (speech, len(segs)))
    print("  kebab:     %5.1fs   %d encoder window(s)   (gap %dms)"
          % (kdur, windows(kdur), o.gap_ms))
    if dur > 0:
        print("  silence culled: %.0f%%   window reduction: %d -> %d"
              % (100 * (1 - speech / dur), windows(dur), windows(kdur)))

    kpath = None
    if o.reconstruct or o.transcribe:
        kdata = kebab(samples, segs, o.gap_ms)
        outdir = o.reconstruct or "/tmp/vad_lab"
        os.makedirs(outdir, exist_ok=True)
        kpath = os.path.join(outdir, name.replace(".wav", ".kebab.wav"))
        write_pcm(kpath, kdata)
        if o.reconstruct:
            print("  wrote kebab: %s" % kpath)

    if o.transcribe:
        orig_txt = transcribe(path, o.model)
        kebab_txt = transcribe(kpath, o.model)
        same = orig_txt == kebab_txt
        print("  transcription %s" % ("IDENTICAL" if same else "DIVERGES"))
        print("    original: %r" % orig_txt)
        print("    kebab:    %r" % kebab_txt)
        if not same:
            sm = difflib.SequenceMatcher(None, orig_txt.split(), kebab_txt.split())
            print("    word similarity: %.1f%%" % (100 * sm.ratio()))
    print()
    return dur, speech, len(segs)


def parse_args(argv):
    o = Opts()
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--gap":            i += 1; o.gap_ms = int(argv[i])
        elif a == "--threshold":    i += 1; o.threshold = float(argv[i])
        elif a == "--pad":          i += 1; o.pad_ms = int(argv[i])
        elif a == "--min-silence":  i += 1; o.min_silence_ms = int(argv[i])
        elif a == "--min-speech":   i += 1; o.min_speech_ms = int(argv[i])
        elif a == "--reconstruct":  i += 1; o.reconstruct = argv[i]
        elif a == "--transcribe":   o.transcribe = True
        elif a == "--model":        i += 1; o.model = argv[i]
        elif a in ("-h", "--help"): print(__doc__); sys.exit(0)
        else:                       files.append(a)
        i += 1
    return o, files


def main():
    for b, label in ((VAD_BIN, "whisper-vad-speech-segments"),
                     (VAD_MODEL, "Silero VAD model")):
        if not os.path.exists(b):
            sys.exit("missing %s: %s\n(build whisper.cpp first)" % (label, b))

    o, files = parse_args(sys.argv[1:])
    if not files:
        files = sorted(glob.glob(os.path.join(WAVS_DIR, "*.wav")))
    if not files:
        sys.exit("no wav files (looked in %s)" % WAVS_DIR)
    if o.transcribe and not os.path.exists(o.model):
        sys.exit("--transcribe needs a model; not found: %s" % o.model)

    tot_dur = tot_speech = tot_segs = 0
    n = 0
    for path in files:
        try:
            dur, speech, nseg = report_one(path, o)
        except (wave.Error, AssertionError) as e:
            print("=== %s ===\n  skipped: %s\n" % (os.path.basename(path), e))
            continue
        tot_dur += dur; tot_speech += speech; tot_segs += nseg; n += 1

    if n:
        print("=== SUMMARY (%d clips) ===" % n)
        print("  total audio:   %6.1fs" % tot_dur)
        print("  total speech:  %6.1fs" % tot_speech)
        print("  mean silence culled: %.0f%%" % (100 * (1 - tot_speech / tot_dur)))
        print("  mean segments/clip:  %.1f" % (tot_segs / n))
        kdur_tot = tot_speech + (tot_segs - n) * (o.gap_ms / 1000.0)
        print("  aggregate audio to encode: %.1fs -> %.1fs  (~%.0f%% less)"
              % (tot_dur, kdur_tot, 100 * (1 - kdur_tot / tot_dur)))


if __name__ == "__main__":
    main()
