#!/usr/bin/env python3
"""Chunk simulation — does background chunk-by-chunk decoding match whole-utterance?

The vad_lab kebab test proved silence-culling preserves quality when the WHOLE
utterance is sent as one call. This asks the next question: if we instead split
the utterance into chunks at silence gaps (the planned background-transcription
policy) and decode each chunk SEPARATELY, does the spliced result still match?

Each chunk is a separate /inference call, so (no_context=true) each decodes cold.
We test three ways and eyeball them against the whole-kebab baseline:
    A   whole-kebab          : all speech, one call          (the known-good baseline)
    B1  chunks, no context   : split at gaps, decode each cold, splice
    B2  chunks, prompt-carry : same, but feed prior text as each chunk's prompt
    O   original             : raw clip, no culling          (reference)

Cut policy: accumulate speech since the last cut; once >= --floor seconds, cut at
a silence gap. With --longest-gap, shift the cut to the longest gap in a +/-2
segment neighbourhood (the "optimal cut-point" idea).

Needs a whisper-server on --port (default 8179) and the VAD binary/model from
the whisper.cpp build. Run/teardown the server yourself; this only POSTs.

Usage:
    python3 tools/chunk_sim.py [--floor S] [--gap MS] [--longest-gap] [--port N] file.wav ...
"""
import os
import sys
import re
import uuid
import difflib
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vad_lab import read_pcm, write_pcm, run_vad, kebab, Opts, SR


def infer(samples, port, prompt=None):
    """POST raw PCM (wrapped as wav) to the server; return transcription text."""
    tmp = "/tmp/chunk_sim_post.wav"
    write_pcm(tmp, samples)
    with open(tmp, "rb") as f:
        wav = f.read()
    b = "cs-" + uuid.uuid4().hex
    body = (("--%s\r\nContent-Disposition: form-data; name=\"file\"; "
             "filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n" % b).encode()
            + wav + b"\r\n")
    fields = [("response_format", "text"), ("temperature", "0.0")]
    if prompt:
        fields.append(("prompt", prompt))
    for k, v in fields:
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                 % (b, k, v)).encode()
    body += ("--%s--\r\n" % b).encode()
    req = urllib.request.Request("http://127.0.0.1:%d/inference" % port, data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=%s" % b})
    txt = urllib.request.urlopen(req, timeout=120).read().decode("utf-8", "replace")
    return clean(txt)


def clean(t):
    """Mirror the app's cleanup enough for fair comparison."""
    t = " ".join(t.split())
    t = re.sub(r"\.{2,}", "", t)
    t = re.sub(r" {2,}", " ", t).strip()
    return t.lstrip(". ").strip()


def chunkify(segs, floor_s, longest_gap):
    """Group speech segments into chunks, cutting at silence gaps once `floor_s`
    of speech has accrued. Returns list of segment-index ranges [(i0, i1), ...]."""
    chunks = []
    start = 0
    acc = 0.0
    i = 0
    while i < len(segs):
        acc += segs[i][1] - segs[i][0]
        is_last = (i == len(segs) - 1)
        if acc >= floor_s and not is_last:
            cut = i  # default: cut after segment i (at the gap before i+1)
            if longest_gap:
                # pick the segment in [i-2, i+2] with the largest FOLLOWING gap
                best, best_gap = cut, -1
                for j in range(max(start, i - 2), min(len(segs) - 1, i + 2) + 1):
                    gap = segs[j + 1][0] - segs[j][1]
                    if gap > best_gap:
                        best, best_gap = j, gap
                cut = best
            chunks.append((start, cut))
            start = cut + 1
            i = cut + 1
            acc = 0.0
        else:
            i += 1
    if start < len(segs):
        chunks.append((start, len(segs) - 1))
    return chunks


def sim_one(path, o, floor_s, longest_gap, port):
    samples, sr, dur = read_pcm(path)
    segs = run_vad(path, o)
    speech = sum(e - s for s, e in segs)
    print("=" * 78)
    print("%s   %.1fs wall, %.1fs speech, %d segments" %
          (os.path.basename(path), dur, speech, len(segs)))

    # A: whole kebab
    whole = kebab(samples, segs, o.gap_ms)
    A = infer(whole, port)

    # split into chunks
    ranges = chunkify(segs, floor_s, longest_gap)
    chunk_specs = []
    for (i0, i1) in ranges:
        csegs = segs[i0:i1 + 1]
        cspeech = sum(e - s for s, e in csegs)
        chunk_specs.append((csegs, cspeech))
    print("policy: floor=%.0fs longest_gap=%s  ->  %d chunk(s): %s" %
          (floor_s, longest_gap, len(chunk_specs),
           ", ".join("%.1fs" % cs for _, cs in chunk_specs)))

    # B1: chunks, cold
    b1_parts = [infer(kebab(samples, cs, o.gap_ms), port) for cs, _ in chunk_specs]
    B1 = clean(" ".join(b1_parts))

    # B2: chunks, prompt = prior text (last 200 chars)
    b2_parts, carry = [], ""
    for cs, _ in chunk_specs:
        t = infer(kebab(samples, cs, o.gap_ms), port, prompt=carry[-200:] or None)
        b2_parts.append(t)
        carry = (carry + " " + t).strip()
    B2 = clean(" ".join(b2_parts))

    # O: original, no culling
    O = infer(samples, port)

    def sim(x, y):
        return 100 * difflib.SequenceMatcher(None, x.split(), y.split()).ratio()

    print("\n  [A]  whole-kebab:")
    print("       %s" % A)
    print("  [B1] chunks cold      (vs A: %.1f%% word-sim):" % sim(A, B1))
    for k, p in enumerate(b1_parts):
        print("       chunk%d: %s" % (k, p))
    print("       JOINED: %s" % B1)
    print("  [B2] chunks +prompt   (vs A: %.1f%% word-sim):" % sim(A, B2))
    print("       JOINED: %s" % B2)
    print("  [O]  original no-cull (vs A: %.1f%% word-sim):" % sim(A, O))
    print("       %s" % O)
    print()
    return sim(A, B1), sim(A, B2)


def main():
    o = Opts()
    floor_s, longest_gap, port, files = 10.0, False, 8179, []
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--floor":          i += 1; floor_s = float(args[i])
        elif a == "--gap":          i += 1; o.gap_ms = int(args[i])
        elif a == "--longest-gap":  longest_gap = True
        elif a == "--port":         i += 1; port = int(args[i])
        elif a in ("-h", "--help"): print(__doc__); sys.exit(0)
        else:                       files.append(a)
        i += 1
    if not files:
        sys.exit("pass one or more wav files")

    b1s, b2s = [], []
    for f in files:
        s1, s2 = sim_one(f, o, floor_s, longest_gap, port)
        b1s.append(s1); b2s.append(s2)
    if len(files) > 1:
        print("=" * 78)
        print("MEAN word-sim vs whole-kebab:  B1 cold = %.1f%%   B2 +prompt = %.1f%%"
              % (sum(b1s) / len(b1s), sum(b2s) / len(b2s)))


if __name__ == "__main__":
    main()
