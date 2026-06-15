#!/usr/bin/env python3
"""Throw a WAV at the resident whisper-server and inspect what it returns.

Unlike process_wav.sh (which spawns a one-off whisper-cli and prints only the
plain text), this hits the SAME running server the app uses, with
response_format=verbose_json, so you can see the diagnostics whisper exposes
per segment: no_speech_prob, avg_logprob, timestamps, temperature. Handy for:
  - confirming a "Thank you" misfire is flagged as high no_speech_prob
  - calibrating the no-speech energy gate against real clips
  - general "what did whisper actually think of this audio" debugging

Usage:
    python3 tools/whisper_probe.py [--raw] [--port N] file.wav [more.wav ...]

    --raw   dump the full JSON response instead of the summary
    --port  override the server port (default: config.yaml's, else 8178)
"""
import sys
import os
import re
import json
import uuid
import urllib.request


def server_port():
    for path in ("config.yaml",
                 os.path.expanduser("~/Library/Application Support/Speak/config.yaml")):
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*server_port:\s*(\d+)", line)
                    if m:
                        return int(m.group(1))
        except FileNotFoundError:
            pass
    return 8178


def inference(path, port, fmt="verbose_json"):
    boundary = "probe-" + uuid.uuid4().hex
    with open(path, "rb") as f:
        wav = f.read()
    pre = ('--%s\r\nContent-Disposition: form-data; name="file"; '
           'filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n' % boundary).encode()
    body = pre + wav + b"\r\n"
    for name, value in (("response_format", fmt), ("temperature", "0.0")):
        body += ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'
                 % (boundary, name, value)).encode()
    body += ("--%s--\r\n" % boundary).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:%d/inference" % port, data=body,
        headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    return urllib.request.urlopen(req, timeout=120).read().decode("utf-8", "replace")


def main():
    args = sys.argv[1:]
    raw = False
    port = server_port()
    files = []
    i = 0
    while i < len(args):
        if args[i] == "--raw":
            raw = True
        elif args[i] == "--port":
            i += 1
            port = int(args[i])
        else:
            files.append(args[i])
        i += 1
    if not files:
        print(__doc__)
        sys.exit(2)

    for path in files:
        print("=== %s  (port %d) ===" % (path, port))
        try:
            resp = inference(path, port, "verbose_json")
        except Exception as e:
            print("  ERROR: %s" % e)
            continue
        if raw:
            try:
                print(json.dumps(json.loads(resp), indent=2))
            except json.JSONDecodeError:
                print(resp)
            continue
        try:
            d = json.loads(resp)
        except json.JSONDecodeError:
            print("  non-JSON response: %r" % resp[:200])
            continue
        print("  text: %r" % d.get("text", "").strip())
        print("  duration: %ss  language: %s" % (d.get("duration"), d.get("language")))
        for s in d.get("segments", []):
            print("  seg[%s] no_speech_prob=%.4f avg_logprob=%.3f t=[%s..%s] %r" % (
                s.get("id"), s.get("no_speech_prob", -1), s.get("avg_logprob", 0),
                s.get("start"), s.get("end"), s.get("text")))


if __name__ == "__main__":
    main()
