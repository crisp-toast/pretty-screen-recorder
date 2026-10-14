"""Local stand-in for the ElevenLabs, OpenAI (speech + Sora), Gemini (Veo) and fal APIs — tests only.
TTS returns a tone as long as the text would take to say, with character timestamps, so
narration timing, captions and mixing can be verified offline:
    PRETTY_ELEVENLABS_BASE=http://127.0.0.1:8765 ELEVENLABS_API_KEY=test-key pretty ...
usage: python3 -I scripts/mock-voice-server.py [port]
"""
import base64, json, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
CPS = 15.0  # characters per second


def clip():
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=720x1280:r=30:d=4",
                           "-pix_fmt", "yuv420p", "-movflags", "frag_keyframe+empty_moov", "-f", "mp4", "-"], capture_output=True, check=True).stdout


def tone(seconds, fmt):
    args = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=frequency=220:duration={seconds:.3f}",
            "-ar", "44100" if fmt == "mp3" else "24000", "-ac", "1"]
    args += ["-b:a", "128k", "-f", "mp3", "-"] if fmt == "mp3" else ["-f", "wav", "-"]
    return subprocess.run(args, capture_output=True, check=True).stdout


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def ok(self):
        return (self.headers.get("xi-api-key") == "test-key" or self.headers.get("Authorization") in ("Bearer test-key", "Key test-key")
                or self.headers.get("x-goog-api-key") == "test-key" or self.path.startswith("/files/"))

    def do_GET(self):
        if not self.ok():
            return self.send(401, {"detail": {"message": "invalid api key"}})
        if self.path.startswith("/v2/voices"):
            return self.send(200, {"has_more": False, "voices": [
                {"voice_id": "mockvoice0000000000a", "name": "Mock Narrator", "category": "premade",
                 "labels": {"accent": "american", "use_case": "narration"}, "description": "test tone", "preview_url": None}]})
        if self.path.startswith("/files/"):
            return self.send(200, clip(), "video/mp4")
        if self.path.startswith("/v1beta/models"):
            return self.send(200, {"models": [{"name": "models/veo-3.1-generate-preview"}]})
        if self.path.startswith("/v1beta/operations/"):
            return self.send(200, {"done": True, "response": {"generateVideoResponse": {"generatedSamples": [{"video": {"uri": f"http://127.0.0.1:{PORT}/files/veo.mp4"}}]}}})
        if self.path.startswith("/v1/videos/") and self.path.endswith("/content"):
            return self.send(200, clip(), "video/mp4")
        if self.path.startswith("/v1/videos/"):
            return self.send(200, {"id": "vid1", "status": "completed"})
        if self.path.startswith("/fal/status"):
            return self.send(200, {"status": "COMPLETED"})
        if self.path.startswith("/fal/response"):
            return self.send(200, {"video": {"url": f"http://127.0.0.1:{PORT}/files/fal.mp4"}})
        if self.path.startswith("/v1/models/"):
            return self.send(200, {"id": "gpt-4o-mini-tts"})
        if self.path.startswith("/v1/models"):
            return self.send(200, [{"model_id": "eleven_v4", "can_do_text_to_speech": True}])
        self.send(404, {"detail": "not found"})

    def do_POST(self):
        if not self.ok():
            return self.send(401, {"detail": {"message": "invalid api key"}})
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if "/with-timestamps" in self.path:
            text = json.loads(body)["text"]
            chars = list(text)
            starts, t = [], 0.05
            for c in chars:
                starts.append(round(t, 3))
                t += 0 if c in "[]" else 1 / CPS
            audio = tone(t + 0.25, "mp3")
            return self.send(200, {"audio_base64": base64.b64encode(audio).decode(),
                                   "alignment": {"characters": chars, "character_start_times_seconds": starts,
                                                 "character_end_times_seconds": [s + 1 / CPS for s in starts]}})
        if self.path.startswith("/v1/audio/speech"):
            text = json.loads(body)["input"]
            return self.send(200, tone(len(text) / CPS + 0.3, "wav"), "audio/wav")
        if ":predictLongRunning" in self.path:
            return self.send(200, {"name": "operations/op1"})
        if self.path.startswith("/v1/videos"):
            return self.send(200, {"id": "vid1", "status": "queued"})
        if self.path.startswith("/fal-ai/"):
            return self.send(200, {"request_id": "r1", "status_url": f"http://127.0.0.1:{PORT}/fal/status", "response_url": f"http://127.0.0.1:{PORT}/fal/response"})
        if self.path.startswith("/v1/music"):
            return self.send(402, {"detail": {"status": "payment_required", "message": "Music API is not available for free users."}})
        if self.path.startswith("/v1/sound-generation"):
            return self.send(200, tone(0.8, "mp3"), "audio/mpeg")
        if self.path.startswith("/v1/audio/transcriptions"):
            return self.send(200, {"text": "", "words": []})
        self.send(404, {"detail": "not found"})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
