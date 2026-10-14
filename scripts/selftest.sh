#!/bin/bash
# End-to-end regression check (~2 min, one heavy job at a time):
#   directed web recording with kinetic scenes → clicks land on their cues → narration where planned
#   → render with audio → a type-only composition renders.
# Narration runs against a local mock of the voice APIs (scripts/mock-voice-server.py): no keys, no cost.
# Usage: scripts/selftest.sh [path/to/pretty]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P="${1:-$ROOT/.build/release/pretty}"
[ -x "$P" ] || P="$ROOT/.build/debug/pretty"
T="$(mktemp -d)"
PORT=8799
python3 -I "$ROOT/scripts/mock-voice-server.py" $PORT &
MOCK=$!
disown $MOCK 2>/dev/null || true
trap 'kill $MOCK 2>/dev/null; rm -rf "$T"' EXIT
export PRETTY_ELEVENLABS_BASE="http://127.0.0.1:$PORT" ELEVENLABS_API_KEY=test-key
fail() { echo "SELFTEST FAIL: $*" >&2; exit 1; }
sleep 0.5

# The example, with deterministic music (generated grid) and the mock narrator.
python3 - "$ROOT/examples/lumen-ad.directed.json" "$T/sb.json" "$ROOT/examples" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["url"] = sys.argv[3] + "/" + d["url"]
d["audio"]["music"] = {"generate": {"mood": "upbeat", "bpm": 112}}
d["audio"]["voice"] = {"provider": "elevenlabs", "voice": "mockvoice0000000000a"}
json.dump(d, open(sys.argv[2], "w"))
PY

echo "→ directed recording" >&2
"$P" record web "$T/sb.json" -o "$T/d.prettystudio" --quiet > "$T/rec.json" 2>"$T/rec.log" || fail "record: $(tail -5 "$T/rec.log")"

echo "→ timing" >&2
python3 - "$T" <<'PY' || exit 1
import json, sys
T = sys.argv[1]
plan = json.load(open(f"{T}/d.prettystudio/sources/plan.json"))
ev = json.load(open(f"{T}/d.prettystudio/sources/events.json"))
proj = json.load(open(f"{T}/d.prettystudio/project.json"))
errs = []
for a in plan["actions"]:
    if a["kind"] != "click":
        continue
    hits = [c["t"] for c in ev["clicks"] if c.get("target") == a["target"]]
    if not hits:
        sys.exit(f"SELFTEST FAIL: no recorded click for {a['target']}")
    errs.append(min(abs(h - a["anchor"]) for h in hits))
beats = {m["index"]: m["t"] for m in ev["markers"] if m["type"] == "beat"}
berr = max(abs(beats[b["index"]] - b["start"]) for b in plan["beats"])
print(f"clicks: max error {max(errs)*1000:.1f} ms over {len(errs)}; beat markers: max {berr*1000:.1f} ms")
if max(errs) > 0.05 or berr > 0.05:
    sys.exit("SELFTEST FAIL: actions drifted off their cues")
scenes = proj.get("scenes", [])
if len(scenes) != 2 or scenes[-1]["style"] != "lockup" or abs(scenes[-1]["start"] + scenes[-1]["duration"] - plan["duration"]) > 0.05:
    sys.exit(f"SELFTEST FAIL: expected an opening punch and a closing lockup that holds to the end, got {scenes}")
if not all(l.get("file") for l in plan["lines"]):
    sys.exit("SELFTEST FAIL: narration wasn't synthesized")
print(f"scenes: {[s['style'] for s in scenes]}; narration lines: {len(plan['lines'])}")
PY

echo "→ render" >&2
"$P" render "$T/d.prettystudio" -p preview -o "$T/out.mp4" --quiet > "$T/render.json" || fail "render"
streams=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$T/out.mp4" | sort | tr '\n' ' ')
[ "$streams" = "audio video " ] || fail "expected audio+video, got: $streams"
lufs=$(ffmpeg -hide_banner -nostats -i "$T/out.mp4" -af ebur128=framelog=quiet -f null - 2>&1 | awk '/ I:/ {print $2; exit}')
python3 -c "import sys; v=float('$lufs'); sys.exit(0 if -16.5 < v < -11.5 else 1)" || fail "loudness $lufs LUFS"
[ -f "$T/out.credits.txt" ] || fail "no credits.txt next to the render"

echo "→ narration placement" >&2
"$P" set "$T/d.prettystudio" audio.mode=voiceover audio.normalize=false audio.sfxVolume=0 >/dev/null
"$P" render "$T/d.prettystudio" -p preview -o "$T/vo.mp4" --quiet >/dev/null || fail "voice render"
python3 - "$T" <<'PY' || exit 1
import json, re, subprocess, sys
T = sys.argv[1]
plan = json.load(open(f"{T}/d.prettystudio/sources/plan.json"))
err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", f"{T}/vo.mp4", "-af", "silencedetect=n=-40dB:d=0.2", "-f", "null", "-"],
                     capture_output=True, text=True).stderr
onsets = [float(x) for x in re.findall(r"silence_end: ([0-9.]+)", err)]
starts = [float(x) for x in re.findall(r"silence_start: ([0-9.]+)", err)]
if not starts or starts[0] > 0.05:
    onsets.insert(0, 0.0)  # sound from the first frame: no leading silence to detect
errs = [(l["start"], min(abs(o - l["start"]) for o in onsets)) for l in plan["lines"]]
# A line that starts in the first 0.25 s has no detectable silence before it; it counts as frame one.
worst = max(e if s > 0.25 else 0 for s, e in errs)
print(f"narration: worst onset error {worst*1000:.0f} ms over {len(plan['lines'])} lines")
if worst > 0.08:
    print("lines (start, error):", [(round(a, 3), round(b, 3)) for a, b in errs], "onsets:", [round(o, 3) for o in onsets][:20])
    sys.exit("SELFTEST FAIL: narration misplaced")
PY

echo "→ type-only composition" >&2
cat > "$T/teaser.json" <<'JSON'
{"name": "teaser", "preset": "tiktok",
 "brand": {"name": "Lumen", "colors": ["#5B5BF0", "#00B3A6"], "tagline": "The calm way to plan your day.", "cta": "Free on the App Store"},
 "audio": {"mode": "music", "music": {"generate": {"mood": "upbeat", "bpm": 120}}},
 "beats": [{"scene": {"style": "punch", "text": "Plan. Focus. Done."}},
           {"scene": {"style": "statement", "text": "Your whole day on one calm screen.", "accent": ["calm"], "marker": true, "background": "dark"}},
           {"scene": {"style": "lockup"}}]}
JSON
"$P" compose "$T/teaser.json" -o "$T/t.prettystudio" --quiet > "$T/compose.json" || fail "compose"
"$P" render "$T/t.prettystudio" -p preview -o "$T/t.mp4" --quiet >/dev/null || fail "compose render"
echo "SELFTEST OK ($lufs LUFS)"
