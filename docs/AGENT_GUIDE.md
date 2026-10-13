# Pretty Studio: agent guide

Pretty Studio turns raw screen recordings into polished videos in the style of CleanShot X's Studio Mode: wallpaper backgrounds, padding, rounded corners and shadows, Smart Zooms that follow the action, a smooth re-drawn cursor with click ripples, keystroke pills, device and browser frames, titles, captions, music, and exports for every platform. It is **agent-first**. Everything is a CLI that prints JSON, every project is a plain JSON file, and you can check any frame as a PNG before you spend time rendering.

- Install: `/Volumes/Master Storage/Code/pretty-screen-recorder`. The launcher is `pretty` (`~/.local/bin/pretty`). It needs Master Storage mounted.
- Run `pretty doctor` once per session to check ffmpeg, Chrome, the drive, and permissions.
- Every command prints JSON on stdout and logs to stderr. Exit code 0 means ok. Errors come back as `{"ok": false, "error": ...}`.

## The loop

```
record (or import)  →  project bundle (.prettystudio)  →  inspect  →  edit  →  frame/sheet (look!)  →  render
```

1. **Record.** `pretty record web storyboard.json --project deltabinder` (or `record screen`, `record sim`, or `pretty new video.mov`).
2. **Inspect.** `pretty inspect <bundle>` shows durations, the edit map, zooms, overlays, the resolved export, and **warnings** (unknown keys, overlapping zooms, durations outside a preset's limits).
3. **Edit.** Use `pretty set <bundle> cursor.size=2 background.preset=sunset`, or edit `<bundle>/project.json` directly. Run `pretty schema` for every key.
4. **Look before rendering.** `pretty frame <bundle> --at 2.5,6 -p tiktok` writes PNGs, and `pretty sheet <bundle> -p tiktok` writes one contact-sheet JPEG of the whole timeline. Read them with your image tool. A frame takes about 0.2 s; a render takes real time.
5. **Render.** `pretty render <bundle> -p youtube` writes to `<bundle>/renders/YYYY-MM-DD_<name>_<preset>_vNN.mp4` and never overwrites. Use `-p preview` for a fast 720p phone check.

Bundles from `record` default to `/Volumes/Master Storage/Projects/<project>/video/`. Pass `--project <repo-name>`, such as `deltabinder`, or set an explicit path with `-o`.

## Recording

### Web apps and sites (best quality, fully scripted, no permissions)

`pretty record web storyboard.json [--project P] [--look L] [-p preset] [--compress-idle]`

Headless Google Chrome runs at Retina scale and records at about 60 fps. A human-like cursor (arcs, minimum-jerk speed) does what the storyboard says, and every move, click, keystroke and scroll is logged so the renderer can draw a perfect cursor and place Smart Zooms.

```json
{
  "url": "https://deltabinder.com",
  "device": "desktop",
  "viewport": {"width": 1440, "height": 900},
  "colorScheme": "light",
  "css": ".cookie-banner{display:none}",
  "localStorage": {"onboarded": "1"},
  "leadIn": 0.8, "tailOut": 1.2, "speed": 1.0,
  "steps": [
    {"click": "text=Get started"},
    {"type": {"selector": "#email", "text": "tyler@example.com"}},
    {"press": "Meta+K"},
    {"zoom": {"target": ".pricing-card.pro", "duration": 2.5}},
    {"scroll": {"y": 700, "duration": 1.2}},
    {"scroll": "#faq"},
    {"hover": "text=Pro"},
    {"caption": {"text": "Track every card you own", "duration": 2.5}},
    {"spotlight": {"target": ".hero h1", "duration": 2}},
    {"wait": 1.0}
  ]
}
```

- **device:** `desktop` (1440×900 @2x), `laptop` (1280×800), `wide`, `iphone` (402-pt iPhone 17 Pro with a synthetic status bar and Safari bar in the frame), `iphone-max`, `ipad`, `android`.
- **Selectors** are Playwright selectors: `text=…`, CSS, `role=button[name="Save"]`. Targets can also be points: `{"x": 0.5, "y": 0.3}`, normalized or in CSS px.
- **Steps:** `click`, `doubleClick`, `rightClick`, `type` (`{selector?, text, delay?, clear?}`), `press` (`"Meta+Shift+P"`), `scroll` (`{y, x?, duration?}`, or a selector to bring into view), `hover`/`move`, `drag` (`{from, to}`), `select` (`{selector, value}`), `goto`, `waitFor`, `wait` (seconds), `eval` (JS), `css`.
- **Direction markers:** `zoom` (`{target | rect, level?, duration}`) places a deliberate zoom framing the element. `spotlight` and `highlight` (`{target, duration}`) dim everything else or outline the target. `caption` and `title` (`{text, duration}`) add text at that moment.
- **`type` clicks its `selector` first**, so you don't need a separate `click`. `delay` is seconds per character (default 0.065, with natural jitter). Use `clear: true` to select all and delete first.
- **Markers don't pause the script.** Add `"hold": true` to wait for the marker's duration, or `"hold": 1.5` to wait that many seconds. Example: `{"caption": {"text": "Search instantly", "duration": 2.5, "hold": true}}`.
- **Options:** `"after": seconds` on any step sets the pause afterwards. `"optional": true` lets a step fail without stopping the run. `"continueOnError": true` at the top level keeps going after failures.
- Relative `url` and `goto` paths resolve against the storyboard file, which makes local prototypes easy.
- Exit code 4 means a required step failed. The partial recording is still kept, and `recorderExit` appears in the JSON.
- `capturedFps` in the result is an average over the whole run. Chrome only sends frames when pixels change, so idle stretches pull the number down. Motion is still captured at about 60 fps, and the output is constant 60 fps.
- `-o` must point at a new bundle. Recording into an existing one is refused unless you pass `--force`, which replaces the recording and keeps `renders/`.
- `file://` pages show "localhost" in the browser bar. Set `frame.url=yourapp.com` to show your real domain.

### Mac apps, the desktop, any window

`pretty record screen --window "Delta Binder" --duration 20 [--system-audio] [--mic]`

- **Target:** `--window "App[:title]"` (captures one window, even if it is covered), `--display N`, or `--region x,y,w,h` in display points.
- The real cursor is hidden. Pointer telemetry is logged at 120 Hz and the cursor is re-drawn with smoothing, click ripples, and size control.
- **Detached:** `pretty record screen --window Safari --detach` returns immediately. Drive the app, then run `pretty record stop`.
- Keystrokes need Input Monitoring for the host app. Without it, log them yourself with `pretty mark key "cmd+k"` while recording.
- **When an agent drives the app** (computer use), the pointer teleports and there are long pauses. Pass `--compress-idle` (or run `pretty auto <bundle> --idle` later): idle stretches are cut, and the "smooth" cursor turns each teleport into a natural glide that lands on the click.

### iOS Simulator

```
pretty record sim --detach --project deltabinder      # status bar set to 9:41, full battery
#  …drive the app (XCUITest, the simulator tool, deep links)…
pretty mark tap 201 640          # optional: log taps in POINTS for touch indicators
pretty mark caption "Scan a card" --duration 2.5
pretty record stop
```

You get an iPhone (or iPad) device frame, touch indicators at the marked taps, and the right point scale. Boot only one simulator, and shut it down when you finish (`xcrun simctl shutdown all`).

No tap tool? Drive the app with deep links or URL schemes (`xcrun simctl openurl booted "myapp://screen"`), XCUITest, or `simctl launch`. Run `pretty mark tap X Y` just before each action so viewers see the touch.

### Existing footage

`pretty new clip.mov [--events events.json] [--camera face.mov] [--kind ios|web|desktop|window] [--look L] [-p preset]`

If there is no telemetry, the recording's own cursor shows and Smart Zooms need manual zooms. A title card with no video at all: `pretty new --card --duration 3 -o intro.prettystudio`.

## Editing reference (most-used keys)

Run `pretty schema` for every key with its default.

| Want | Set |
|---|---|
| Different backdrop | `background.preset=sunset` (`pretty backgrounds --sheet /tmp/bg.jpg` previews all 20), `background.type=color background.color=#0B0B0F`, `background.type=image background.image=/path.jpg`, `background.type=blur` |
| One-word style | `pretty new … --look midnight` (`pretty looks`) |
| More or less space | `layout.padding=0.12` |
| Room for a hook or CTA | `layout.headroom=0.16` (band above) and `layout.footroom=0.06` (band below). Text with `--position top` or `bottom` centers in them |
| Corners and shadow | `layout.corners=0.03 layout.shadow=0.7` |
| Output shape | `-p tiktok` / `-p youtube` / `layout.aspect=1:1` |
| Vertical crop of a desktop recording | `layout.fit=cover` (the camera follows the action) |
| Frame | `frame.type=browser\|window\|iphone\|ipad\|android\|macbook\|none`, `frame.theme=dark`, `frame.color=natural`, `frame.url=deltabinder.com` |
| Hero tilt | `layout.tiltY=-8 layout.tiltX=4` |
| Cursor | `cursor.size=2 cursor.style=white\|dot\|touch cursor.motion=smooth\|natural\|raw cursor.hideWhenIdle=true` |
| Clicks | `cursor.ripple.color=#FF2D55 cursor.ripple.style=filled cursor.pressEffect=false audio.clickSounds=true` |
| Zoom feel | `motion.zoomAnimation=dynamic`, `motion.blur=off\|low\|medium\|high`, `zoom.level=1.8` |
| Keystrokes | `keystrokes.mode=all` (typed text too), `keystrokes.theme=light`, `keystrokes.position=bottom-right` |
| Webcam / presenter | `source.camera=sources/face.mov camera.shape=circle\|square\|rectangle\|vertical camera.position=bottom-left` |

### Zooms (source time)
- Smart Zooms are generated on create from click clusters, typing, and storyboard `zoom` markers.
- `pretty zoom <b> add --start 3.2 --end 6 --level 1.8` follows the cursor. Add `--manual --focus 0.7,0.3` to fix the focus point (normalized).
- `pretty zoom <b> clear --auto` removes only the automatic zooms. `pretty auto <b>` regenerates them.
- Zooms closer than 0.4 s apart join into one continuous pan.

### Timeline (source time)
- `pretty trim <b> 1.2 18.5`
- `pretty cut <b> 7.0 9.4`
- `pretty speed <b> 10 14 3` (3× fast-forward)
- `pretty auto <b> --idle` compresses dead time (tune with `timeline.idle.*`).
- `pretty inspect` shows `kept` segments with both source and output times.

### Text, captions, audio (output time)
- `pretty text <b> "Your cards, organized" --start 0 --end 3 --style hero --position top --animation pop`
  - Styles: `hero`, `title`, `subtitle`, `kicker`, `caption`, `label`. Animations: `rise`, `pop`, `fade`, `slide`, `typewriter`, `none`.
  - Text that would land on the recording gets a legible pill automatically. Set `--fill "#FF2D55"` for a colored pill.
- `pretty caption <b> --srt subs.srt`, or `pretty caption <b> "Line" --start 1 --end 3`
- `pretty music <b> /path/track.m4a --volume 0.25`. Music ducks under voice and the mix is normalized to −14 LUFS.
  - `/Volumes/Master Storage/Library/Music/` is where reusable tracks belong, but it starts empty. Use a licensed track, or generate one (Higgsfield audio) and save it there with a sidecar.
- Voiceover: generate it (`say -v Samantha -o vo.aiff "…"`, or an AI voice), then set `audio.voiceover` to `[{"path": "...", "at": 1.0}]`.
- Image overlay or logo: add `{"type": "image", "path": "logo.png", "start": 0, "end": 3, "position": "top", "width": 0.2}` to `overlays`.
- Redact: `{"type": "blur", "rect": {"x": .6, "y": .1, "w": .3, "h": .05}, "start": 0, "end": 99}` (source time, normalized rect).

## Presets (`pretty presets`)

| Preset | Size | Notes |
|---|---|---|
| `youtube` | 1920×1080 at 60 fps | Default landscape |
| `youtube-4k` | 3840×2160 | |
| `tiktok`, `reels`, `shorts` | 1080×1920 at 30 fps | Keep text out of the top 220 px and the bottom 380 px |
| `instagram` | 1080×1350 | |
| `square` | 1080×1080 | |
| `x` | | |
| `linkedin` | | |
| `app-store-iphone` | 886×1920 | Silent stereo track added automatically; warns outside 15–30 s |
| `app-store-iphone-landscape` | | |
| `app-store-ipad` | 1200×1600 | |
| `web-hero` | | Silent loop, plus `.webm` and a poster `.jpg` |
| `gif` | | |
| `master` | Original resolution | ProRes 422 HQ |
| `preview` | 720p | Fast phone check |

## Recipes

**Landing-page hero loop:** record web with `device: desktop`, `--look clean`, then `pretty render b -p web-hero`. You get the mp4, webm, and poster to drop into the site.

**TikTok ad for an iPhone app:**
1. `pretty record sim --detach`, drive the app, then `pretty record stop`.
2. Run `pretty set b layout.headroom=0.24 layout.footroom=0.1 background.preset=lavender frame.color=natural` to leave room for the hook and CTA. The tiktok, reels, and shorts presets also keep text out of the platform UI zones (top 220 px, bottom 380 px, right 120 px) automatically.
3. Run `pretty text b "Stop losing track of your cards" --style hero --start 0 --end 3.5 --position top`.
4. Add a CTA: `pretty text b "Free on the App Store" --style label --start 9 --end 12 --position bottom`.
5. Check with `pretty sheet b -p tiktok`, then render with `-p tiktok`.

**Product walkthrough:** record web or screen, then `pretty auto b --idle`. Add `cursor.size=1.8`, `keystrokes.mode=all`, and captions from your script, then render with `-p youtube`.

**Multi-part ad:** make cards with `pretty new --card -p tiktok --look sunset -o intro.prettystudio --duration 2.5`. Cards inherit the sequence's canvas when stitched, so `-p` only matters if you render a card by itself. plus `pretty text intro.prettystudio "Delta Binder" --style hero --position center`. Then write `ad.sequence.json`:
```json
{"export": {"preset": "tiktok"}, "transition": {"type": "fade", "duration": 0.35},
 "music": {"path": "/Volumes/Master Storage/Library/Music/upbeat.m4a", "volume": 0.3},
 "items": [{"project": "intro.prettystudio"}, {"project": "demo.prettystudio"}, {"project": "outro.prettystudio"}]}
```
Run `pretty sequence ad.sequence.json -o ad.mp4`. Transitions: `fade`, `dissolve`, `slide`, `slideup`, `wipe`, `zoom`, `smooth`, `circle`, `blur`, `none`.

**App Store preview:** record a sim, keep it 15–30 s (`pretty trim`, `pretty speed`), then `pretty render b -p app-store-iphone`. Apple wants the device screen without a frame, so set `frame.type=none layout.padding=0 layout.corners=0 layout.shadow=0`.

## Time bases (important)

- **Source time** (seconds into the raw recording): zoom segments, cuts, speed, trim, and spotlight/blur/highlight overlays. These stay attached to the content when you cut.
- **Output time** (seconds into the final video): text and image overlays, captions, voiceover, music. Set `"time": "source"` on an overlay to pin it to the content instead (storyboard caption markers do this).
- `pretty inspect` lists each zoom's `out` times and each kept segment's mapping.

## Delivering on this Mac
- Masters stay in the bundle's `renders/` on Master Storage. Send Tyler a `-p preview` render or a `pretty sheet` JPEG, not the 4K master.
- Run one heavy job at a time: a render, a simulator, or a browser recording, never two. Shut down simulators you booted.
- A bundle is self-contained (sources are APFS clones), so it is safe to move or archive.

## Troubleshooting
- **`no frames were captured`:** the host app needs Screen Recording permission. Tyler approves it in System Settings → Privacy & Security.
- **Keystrokes missing in screen recordings:** grant Input Monitoring, or use `pretty mark key`.
- **Text unreadable:** set `color` and `fill` on the overlay, or move it with `y` (0–1). `pretty text <b> ls` lists overlays with their indexes, and `pretty text <b> rm N` removes one.
- **Every command has help:** `pretty <command> --help`.
- **A zoom feels wrong:** `pretty inspect` lists each zoom's id, source and output times, and focus. Adjust it with `pretty set b 'zoom.segments[2].level=1.4'`, or remove it with `pretty zoom b rm <id>`.
- **Web step fails:** check the selector in the error. Make the step `"optional": true` or add a `waitFor`.
