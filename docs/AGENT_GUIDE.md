# Pretty Studio: agent guide

Pretty Studio turns screen recordings into directed product videos in the style of CleanShot X's Studio Mode. That means wallpaper backgrounds, device frames and Smart Zooms, a smooth re-drawn cursor with click ripples, full-screen **kinetic type** in the product's own colors and font, studio-grade narration, and **real music** with its license handled. It is **agent-first**. Everything is a CLI that prints JSON, every project is a plain JSON file, and you can check any frame as a PNG before you spend time rendering.

- Install: `/Volumes/Master Storage/Code/pretty-screen-recorder` on Tyler's Mac (the launcher is `pretty`, `~/.local/bin/pretty`). Anywhere else, `Pretty Studio.app` bundles the CLI at `Contents/MacOS/pretty`.
- Run `pretty doctor` once per session (ffmpeg, Node, a browser, narration, music, permissions) and `pretty setup status` to see the voice, music, ElevenLabs plan, Blender (3D shots) and video-AI setup. Required checks decide `ok`.
- Default outputs go to `$PRETTY_PROJECTS_DIR/<project>/video/`, then the folder chosen in the app's setup, then `/Volumes/Master Storage/Projects/...`. Otherwise pass `-o`.
- Every command prints JSON on stdout and logs to stderr. Exit code 0 means ok. Errors come back as `{"ok": false, "error": ...}`.

## The loop

```
brand → storyboard (beats) → lint → plan → --check → record → sheet (look!) → render → REVIEW → fix → render → review … → deliver
```

1. **Brand.** Run `pretty brand <site | app repo | icon.png> --project <name>`. It writes `brand.json` with the name, the product's own promise, colors, icon, logo and font into `Projects/<name>/marketing/brand/`. Review it. Then point the storyboard at it with `"brand": "../brand/brand.json"`.
2. **Write beats.** Pair what's said with what's done. Add a hook scene, 3D `shot`s, `broll` for emotion, and a closing lockup. Use the product's real copy: its App Store text, site headline and UI labels.
3. **Lint and plan.** Run `pretty lint storyboard.json`, then `pretty plan storyboard.json -p tiktok` (add `--no-generate` while iterating, so it doesn't pay for B-roll). The plan picks a **treatment** and composes the score. Fix every warning.
4. **Dry run.** `pretty record web storyboard.json --check` catches broken selectors in seconds, without recording.
5. **Record.** `pretty record web storyboard.json --project <name>` (or `record sim` / `record screen` + `pretty conform`).
6. **Look before rendering.** `pretty sheet <bundle> -p tiktok`, plus `pretty frame` on any moment you're unsure of.
7. **Render.** `pretty render <bundle> -p tiktok`. 3D shots render first (Blender, cached). A `*.credits.txt` lands next to the render.
8. **Review — mandatory.** Run `pretty review <bundle>`, then open `sheet.jpg` and every `moments/*.jpg`, score the rubric honestly (1-5), and fix anything below 4 plus every blocker or major issue. Its objective checks include a blank first frame (the hook must read on frame one: feeds autoplay muted), black frames, freezes, loudness and peaks, grain, dated looks, stock-sounding music, rights and repetition. Re-render and review again. **Never deliver a video that hasn't passed a review.** Tell Tyler about any blocker you can't fix yourself (such as the ElevenLabs plan).

## Creative treatments: every video its own look

The planner picks one of five treatments per video, avoiding the last two used for the project (`Projects/<name>/marketing/.pretty-history.json`). Pin one with `"treatment": "glow"`, or vary within it with `--seed N`.

| treatment | look | motion | sound |
|---|---|---|---|
| `keynote` | black stage, soft spotlight, white type with gray continuation | rise/tilt entrances, slow push | cinematic minimal electronic, felt piano, pulse |
| `studio` | light seamless set, crisp dark type | tilt entrance, drift | clean modern electronic, airy |
| `glow` | near-black with the brand's color glowing behind the device | orbit, push, zoom transitions | atmospheric electronic, emotional build |
| `editorial` | warm paper, large left-aligned serif statements | tilt, drift, cuts | minimal piano and strings |
| `cinematic` | deep graded dark, serif titles | rise, slow pushes | swelling strings, low hits, trailer arc |

A treatment sets the backdrop (`background.type: stage`), the device finish and shadow, scene backgrounds, type (weight, alignment, line or word reveals, two-tone), transitions, device moves, the score's style and the sound design. Anything the storyboard sets explicitly wins.

## Never generic: tailor every video

The test: could this video be about a different app if you swapped the logo? If yes, rewrite it.

- **Use the product's own words.** Mine its App Store screenshots and copy (Delta Binder: `~/code/deltabinder/marketing/app-store/design/campaign.json`), its site headline, and its UI labels. `pretty brand` pulls the tagline from the site.
- **Name concrete things.** Use the card, the number, the screen or the result (for example "What is your Charizard worth?" rather than "Track your collection's value"). Never invent stats or claims. Prices and counts come from what's on screen.
- **Hook in ≤7 words, one idea per beat, show it as it's said.** The headline names exactly what the next action reveals.
- **End on a lockup scene:** icon + name + the product's real promise + where to get it (`brand.cta`). Don't say "on the App Store" unless it's live.
- `pretty lint` (also run by `plan`) flags ad-speak ("seamless", "unlock", "game-changer", "effortless"...), long hooks, overstuffed scenes, a product that's never named, and ads without a lockup.

## Directing: what's said, what's done, and when

Every click has a reason. It lands as the line names it, and on the beat when there's music. Write a **beat storyboard**:

```json
{
  "url": "https://deltabinder.com/card/sv3pt5-199", "device": "iphone", "colorScheme": "dark", "preset": "tiktok",
  "brand": "../brand/brand.json",
  "audio": {"mode": "auto", "sync": "beats"},
  "beats": [
    {"scene": {"style": "statement", "text": "What is your Charizard worth?"}},
    {"say": "Follow your card's value.",
     "do": [{"waitFor": "text=Market Price", "why": "the price is the payoff"},
            {"scroll": {"selector": "text=Market Price", "align": 0.42}, "why": "bring today's price into view", "at": "beat"}]},
    {"say": "A year of price history, one tap.",
     "do": [{"scroll": {"selector": "text=Price history", "align": 0.22}, "why": "bring the chart into view", "at": "start"},
            {"click": "text=1Y", "why": "zoom out from 30 days to a full year", "at": "beat"}]},
    {"broll": {"prompt": "a collector's hands sliding a holographic card into a binder sleeve, warm desk lamp", "seconds": 6},
     "scene": {"style": "statement", "text": "Every card. Every printing. Priced."}},
    {"scene": {"style": "lockup"}}
  ]
}
```

(Music is left unset so the score is composed for this edit; the treatment is picked per video. Delta Binder storyboards live in `Projects/deltabinder/marketing/`.)

- **A beat holds:**
  - `say`: the line. With a narrator it's spoken (word-timed captions follow). Without one, it becomes a **headline** in the space above the device (`audio.text: "caption"` gives pills instead).
  - `do`: actions, each with a `why`.
  - `scene`: full-screen kinetic type. It replaces the device for that beat.
  - Direction at the beat's start: `zoom`, `spotlight`, `highlight`, `caption`, `title`. To act after the beat's first action, put direction inside `do` with `"at": "after"`, e.g. a zoom after a scroll.
  - Timing: `hold`, `gap`, `minDuration`.
- **Cues (`at`):**
  - `word:New` lands on that spoken word.
  - `auto` lands on the word matching the target's label.
  - `start` and `end` mean the start of the beat or the end of the line.
  - `after` follows the previous action.
  - `beat` is the first music beat the pointer can make.
  - A number is seconds into the beat.
- **What the planner guarantees:**
  - Narration is synthesized first, so word times are exact.
  - Pointer travel is reserved.
  - Clicks, taps and selects snap to half-beats.
  - Beats start on bar lines.
  - Scenes run to the next beat.
  - A closing scene holds to the end, and the video ends on a bar.
- Failed steps make `record web` exit 4 (`"ok": false`, `problem`). Fix and re-record with `--force`.
- Scrolls drive the element that actually scrolls (sheets, modals, lists), not just the page. `select` steps move the pointer and tap the picker on camera.

### Scenes: kinetic type with no device

Use scenes for the hook, for claims the UI can't show, and for the end card. The defaults are restrained: lines rise in with a soft blur clearing, and emphasis is two-tone (white plus gray, set by `secondary`; a two-sentence statement gets its second sentence in gray automatically). There are no bounces. The highlighter (`marker`) is opt-in and reads dated, so use it rarely.

| style | what it does | good for |
|---|---|---|
| `statement` | A sentence arrives line by line (or word by word with `"reveal": "words"`) | Hooks, questions, claims |
| `punch` | One word or phrase at a time, cut on the beat | Use once at most: "Scan. Price. Trade." |
| `stack` | Lines slide up from a slot; earlier lines settle into gray | Feature trios, `sub` underneath |
| `reveal` | Lines rise in quick succession | Two-line statements |
| `type` | Typewriter with caret | Dev tools, search prompts |
| `count` | A number counts up (`value`, `prefix`, `suffix`, `sub`) | Real metrics only |
| `lockup` | Icon (squircle, soft shadow), name, promise, CTA pill | Always the last beat of an ad |

- `background`: `keynote` · `studio` · `glow` · `paper` · `cinema` (lit stages that breathe slowly) · `content` (the recording, blurred) · `clip:<video>` (B-roll) · a hex color. The treatment alternates them for you.
- Words land on spoken words when narrated, otherwise on beats or in a calm cascade. Transitions: `dissolve` (default), `lift`, `zoom`, `fade`, `slide`, `cut`. Scene-to-scene changes dissolve with no device flash; the words always leave before the device returns.
- Type uses `brand.font` (the product's headline font), otherwise SF Pro Display with display tracking. CoreText sets the spacing exactly.
- **Type-only videos:** `pretty compose storyboard.json -p tiktok`.

### 3D device shots (components, Rotato-style)

A shot is a component inside a video: the real recorded screen on a 3D device, animated by a camera template, landing exactly where the flat device sits so the handoff is seamless. Blender renders it headless and caches it. On phone recordings, the first time the device appears becomes a shot automatically, with the move chosen from the treatment.

| move | what it does | good for |
|---|---|---|
| `hero` | three-quarter turn that lands straight on, gentle push | the first reveal |
| `orbit` | camera arcs around the device | glow/premium moments |
| `rise` | rises from below, tilted back, into place | a dramatic entrance |
| `tilt` | swings in from an angle | quick, clean entrance |
| `flat` | lying flat on a surface, then stands up to face you | editorial, "pick it up" |
| `dolly` | straight on, a slow push from far away | calm confidence |
| `closeup` | macro pass over one part of the screen (`focus: [x, y]`), depth of field, pulls back | the payoff detail (a price, a badge) |
| `macro` | holds on the full screen while the beat's line lands, then pushes into `focus: [x, y]` and stays there | the payoff, as the beat's last word |
| `duo` | two devices: this moment in front, another (`offset` seconds later) behind | before/after, two features |
| `slide` | slides in from the side | sequences |
| `turntable` | slow continuous rotation | end-card companions |
| `spin` / `float` | full spin to front / subtle hover | sparingly |

- `"shot": "closeup"` on any beat, or `{"move": "duo", "offset": 3, "duration": 2.8, "finish": "natural", "reflection": true}`. Finishes: black, natural, silver, white, blue, desert, gold. `reflection` adds a glossy floor (keynote and glow turn it on). iPad recordings get iPad geometry automatically. Turn the automatic shot off with `"shots": false`.
- `pretty shots <bundle> -p tiktok` pre-renders them (about 1-2 minutes each at 1080x1920). The shot's screen is the same frames the flat device shows (speed ramps included), so hand-offs are seamless. Zooms stay out of shots, and a headline is read before a zoom or a macro push covers it.
- Between shots the flat device still moves: `rise`/`tilt` entrances with a light sweep across the glass, then a slow `push` or `drift` (`moves[]`).

### AI B-roll: emotion the recording can't give

`"broll": {"prompt": "hands sliding a holographic card into a binder sleeve, warm window light", "seconds": 6}` on a beat generates a clip (Veo via a Gemini key, Sora 2 via OpenAI, or fal.ai) and plays it full-screen under that beat's `scene` text, with a slow push and a legibility scrim.
- Prompts describe people, hands, places, light and objects, never the app's interface (models can't render real UI; product shots come from the recording). The treatment's cinematic style and a negative prompt (no text, logos or UI; no bad hands) are added automatically.
- Clips are cached by prompt, so re-plans are free. Plan with `--no-generate` while iterating. `pretty broll "prompt"` makes a single clip to preview.
- **Review every frame of a generated clip** (hands, faces, physics, anything that looks fake) and disclose AI footage where the platform requires.

### Choosing the soundtrack (`audio.mode`: `none`, `music`, `voiceover`, `both`, `auto`)

| Video | Pick | Why |
|---|---|---|
| TikTok / Reels / Shorts / Instagram / X ad | `both` with a narrator, else `music` | Narration carries the story; without one, headlines and scenes do. Music sets the energy |
| YouTube walkthrough, tutorial, docs | `voiceover`, or `both` with music at 0.15 or lower | Clarity first |
| App Store preview | `music` | Autoplays muted; UI + beat-synced taps tell the story |
| Landing-page hero loop, GIF | `none` | Plays muted on loop |
| Teaser / sizzle | `music` + scenes | Pace everything to the beat |
| Internal QA or bug clip | `none` (system audio stays) | Fidelity, not polish |

`auto` follows this table. It never plans narration when no narrator is set up. `pretty inspect` reports what will play and why.

### Voice: studio-grade or none

There are no on-device voices. Narration is **ElevenLabs** (default model `eleven_v4`, character-exact word timing) or **OpenAI** (`gpt-4o-mini-tts`, voices `marin`/`cedar` recommended, word timing from whisper-1). Otherwise there's no narration, and the story is carried by headlines and scenes, which is often the better ad anyway.

- **Setup is Tyler's.** He sets it up in the Pretty Studio app (Settings → Voice, with previews) or with `pretty keys set elevenlabs` (hidden prompt; stored in the login Keychain; `ELEVENLABS_API_KEY` / `OPENAI_API_KEY` env vars override). Never ask for, print, or store keys yourself.
- `pretty setup status` shows whether narration is ready. `pretty voice list` lists the account's voices and models. `pretty setup voice --provider elevenlabs --voice NAME` sets the default.
- Per storyboard: `"audio": {"voice": {"provider": "elevenlabs", "voice": "Brian", "model": "eleven_v4", "speed": 1.05, "style": 0.3}}`. ElevenLabs v4 audio tags work in `say` lines ("[excited] It's already priced.") and never appear in captions.
- `pretty voice say "Line"` tests a voice; `pretty voice add <b> "Line" --at 3.2` places narration; `--file vo.mp3 --text "..."` imports narration recorded elsewhere. Synthesis is cached by content, so re-planning costs nothing.
- Credits: OpenAI voices must be disclosed as AI-generated. ElevenLabs free-plan audio needs attribution and is non-commercial. `credits.txt` says so.

### Music: scored, not stocked

No "royalty-free happy music". In order:

1. **Tyler's licensed library**, if it has tracks (Epidemic Sound, Artlist, Musicbed…; `pretty music library`).
2. **An original score composed for this edit** (ElevenLabs Music, using the voice key): sections follow the plan (a sparse intro under the hook, a build through the demo, a lift at the reveal, a warm resolve on the end card) in the treatment's style. The planner plans twice: once to learn the sections, then again on the composed track's real beat grid. **This needs a paid ElevenLabs plan** (the free plan returns 402). `pretty setup status` and the review show the plan.
3. **Classic catalog** (Kevin MacLeod, CC BY): off by default because many tracks read as stock music. If used, choose cinematic/ambient pieces, never the comedic or ukulele classics. The review flags happy-stock tracks as a major issue.

**Sound design** (on by default) uses ElevenLabs sound effects: soft whooshes on scene changes, a shimmer when the device lands, a riser into and an impact on the end card, and barely-there taps. On the free ElevenLabs plan these are non-commercial and need credit; the review blocks delivery until the plan allows commercial use.

The mix is measured on the encoded audio and trimmed to -14 LUFS with a -1 dBTP limiter.
- In storyboards: `"music": "compose"` (or `{"compose": {"bpm": 100, "mood": "..."}}`), `{"track": "incompetech:…"}`, `{"find": {…}}`, `{"path": "…", "license": {…}}`, or `"none"`.
- **Chart hits can't be used.** Attribution doesn't license them; they need sync and master licenses.
- `pretty credits <bundle>` prints the credit lines.

### Conform: retime a loose take to the plan (simulator, desktop)

Agents driving a simulator or a Mac app can't hit cues live, so record loosely and fix the timing afterwards:

1. `pretty plan storyboard.json -p tiktok`.
2. Record while performing the actions in the plan's order: `pretty record sim --detach`, then `pretty mark tap X Y` with each tap, then `pretty record stop`.
3. `pretty conform <bundle> --plan storyboard.plan/plan.json`.

Each recorded click or tap is matched to its planned cue: by selector for web recordings, otherwise by order. Dead time is cut or sped up, and short gaps get freeze-frame `timeline.holds`. Narration, music and captions are placed on the plan's timeline.

### Beat-synced sequences

In a sequence file, `"music": {"track": "incompetech:Inspired"}` (or `{"find": {...}}`, `{"path": ...}`, `{"generate": {...}}`) together with `"sync": "beats"` starts every clip on a beat, trimming clip tails by less than one beat. Directed clips at the same BPM keep their clicks on the beat. The output gets a `credits.txt` too.

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
- Smart Zooms are generated on create from click clusters, typing, and storyboard `zoom` markers. Web clicks record their container (card, dialog, form), so zooms frame the whole container with its heading instead of cropping tight.
- Phone recordings (`iphone`, `ipad`, `android`, simulator) get no automatic zooms, because the device frame is already the framing. Add `zoom` markers or `pretty zoom add` when you want one.
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
- Music: `pretty music use <b> "incompetech:Carefree"` (real track, credited), `pretty music <b> /path/licensed.m4a`, or `pretty music generate <b> --mood chill`. It ducks under the voice, and the mix is normalized to −14 LUFS.
- Narration: `pretty voice add <b> "Line" --at 1.0` (needs a narrator set up). See Directing above, and set `audio.mode` deliberately.
- Scenes: edit `scenes[]` in project.json (output time). See "Scenes" above.
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

**TikTok ad for an iPhone app (simulator):**
1. `pretty brand ~/code/<app> --project <app>`. Write a beat storyboard with a hook scene, `say` + `do` beats and a closing lockup. Run `pretty plan storyboard.json -p tiktok`.
2. `pretty record sim --detach`, perform the plan's actions in order (`pretty mark tap X Y` with each), then `pretty record stop`.
3. `pretty conform <b> --plan storyboard.plan/plan.json`. Clicks land on the plan's cues; scenes, headlines, brand and music come with it.
4. Check with `pretty sheet b -p tiktok`, then render with `-p tiktok`. The tiktok, reels, and shorts presets keep text out of the platform UI zones automatically.

**Product walkthrough:** record web or screen, then `pretty auto b --idle`. Add `cursor.size=1.8`, `keystrokes.mode=all`, and captions from your script, then render with `-p youtube`.

**Directed ad (best):** `pretty brand`, then a beat storyboard (see Directing) with `"brand"`, a hook scene, `say` + `do` beats, a `broll` beat for emotion, and a lockup. Leave music unset so it's composed. Run `pretty lint` and `pretty plan` (fix warnings), `--check`, `pretty record web`, `pretty sheet -p tiktok`, `pretty render -p tiktok`, then **`pretty review`** and iterate until it passes. Publish the lines in the render's `credits.txt`.

**Type-only teaser:** a storyboard of `scene` beats only, then `pretty compose teaser.json -p tiktok` and `pretty render`.

**Multi-part ad:** make cards with `pretty new --card -p tiktok --look sunset -o intro.prettystudio --duration 2.5`. Cards inherit the sequence's canvas when stitched, so `-p` only matters if you render a card by itself. plus `pretty text intro.prettystudio "Delta Binder" --style hero --position center`. Then write `ad.sequence.json`:
```json
{"export": {"preset": "tiktok"}, "transition": {"type": "fade", "duration": 0.35},
 "music": {"track": "incompetech:Funky Chunk", "volume": 0.3}, "sync": "beats",
 "items": [{"project": "intro.prettystudio"}, {"project": "demo.prettystudio"}, {"project": "outro.prettystudio"}]}
```
Run `pretty sequence ad.sequence.json -o ad.mp4`. Transitions: `fade`, `dissolve`, `slide`, `slideup`, `wipe`, `zoom`, `smooth`, `circle`, `blur`, `none`.

**App Store preview:** record a sim, keep it 15–30 s (`pretty trim`, `pretty speed`), then `pretty render b -p app-store-iphone`. Apple wants the device screen without a frame, so set `frame.type=none layout.padding=0 layout.corners=0 layout.shadow=0`.

## Time bases (important)

- **Source time** (seconds into the raw recording): zoom segments, cuts, speed, trim, and spotlight/blur/highlight overlays. These stay attached to the content when you cut.
- **Output time** (seconds into the final video): text and image overlays, captions, voiceover, music. Set `"time": "source"` on an overlay or a voiceover clip to pin it to the content instead. Directed web recordings do this, so narration stays attached through later edits.
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
