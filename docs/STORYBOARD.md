# Storyboard reference (`pretty record web` / `pretty plan`)

A storyboard is JSON. Use `steps` for a plain scripted run, or `beats` for a **directed** run (narration + cued actions + music). If both exist, `beats` wins.

## Top level

| key | type | default | meaning |
|---|---|---|---|
| `url` | string | — | Page to open. Bare paths resolve against the storyboard file. |
| `html` | string | — | Inline HTML instead of `url`. |
| `device` | enum | `desktop` | `desktop` (1440×900 @2x) · `laptop` (1280×800) · `wide` (1680×945) · `iphone` (402-pt viewport, iOS status + Safari bars drawn by the frame) · `iphone-max` · `ipad` · `android` |
| `viewport` | {width,height} | per device | CSS px. Pixel size is rounded to even. |
| `scale` | number | per device | Device pixel ratio. |
| `colorScheme` | enum | `light` | `light` · `dark` |
| `channel` | enum | auto | `chrome` · `chromium` · `msedge`. Default tries them in that order (or `$PRETTY_BROWSER_CHANNEL`). |
| `css` | string | — | Injected CSS (hide cookie banners, chat bubbles). Tap highlights and scrollbars are hidden automatically. |
| `init` | string | — | JS run before page scripts. |
| `localStorage` | object | — | Seeded before load. |
| `cookies` | array | — | Playwright cookie objects. |
| `leadIn` | seconds | 0.8 | Still time before the first action (directed: first beat start). |
| `tailOut` | seconds | 1.2 / 1.0 | Still time after the last action. |
| `speed` | number | 1 | Pacing multiplier for `steps` runs (>1 slower). Ignored for directed runs. |
| `cursorStart` | {x,y} | {0.62,0.7} | Normalized start position of the pointer. |
| `continueOnError` | bool | false | Keep going after a failed step. |
| `name`, `project`, `look`, `preset` | string | — | Defaults for the bundle name, project folder, look and export preset. |
| `brand` | path or object | — | Brand kit (`pretty brand`): name, colors, font, icon, tagline, cta. Dresses scenes, headlines, the backdrop and the lockup. |
| `background` | string | brand | `brand` (gradient in the brand colors) or a background preset. Ignored when `look` is set. |
| `mood` | string | treatment's | Extra direction for the composed score / catalog search. |
| `treatment` | enum | varied | `keynote` · `studio` · `glow` · `editorial` · `cinematic` — the whole look, motion and sound. Default: picked per video, avoiding the project's last two. |
| `shots` | bool | true | Automatic 3D hero shot when a phone first appears (needs Blender). |
| `moves` | bool | true | Device entrances and slow pushes. |
| `sfx` | bool | true | Sound design (ElevenLabs sound effects). |
| `audio` | object | — | Directed runs only — see below. |

## Steps (both modes)

Every step is an object with **one action key**, plus optional annotations: `why` (reason, required in beats), `at` (cue, beats only), `after` (seconds to pause afterwards, steps only), `optional` (failure doesn't stop the run), `hold` (markers: wait their duration), `note`.

| action | value | notes |
|---|---|---|
| `click` / `doubleClick` / `rightClick` / `tap` | selector, or `{selector, offset:[0-1,0-1]}`, or `{x,y}` | Pointer glides in on a human arc. Touch devices tap. |
| `type` | `"text"` or `{selector?, text, delay?, clear?}` | Clicks `selector` first. `delay` = seconds per character (0.065 + jitter). |
| `press` | `"Meta+K"` | Key combos: Meta/Control/Alt/Shift + key. |
| `scroll` | `{y, x?, duration?, within?}` or `{selector, align?}` or selector | Smooth wheel/touch scroll of whatever actually scrolls (page, sheet, modal); a selector is brought to `align` (0-1, default 0.18) of its scroll area. |
| `hover` / `move` | selector or `{x,y}` | |
| `drag` | `{from, to, duration?}` | |
| `select` | `{selector, value}` | `<select>` option: the pointer travels and taps the picker, then the value is set. Use a precise selector (`select:not([disabled])`). |
| `goto` | url | |
| `waitFor` | selector | Waits until visible. |
| `wait` / `pause` | seconds | |
| `eval` | JS string | |
| `css` | CSS string | |
| `zoom` | `{target | rect, level?, duration?, pad?}` | Directed zoom framing the element. |
| `spotlight` / `highlight` | `{target, duration?}` | Dim everything else / outline the target. |
| `caption` / `title` | text or `{text, duration?}` | On-screen text at that moment. |

Selectors are Playwright selectors: `#id`, `.class`, `text=Label`, `role=button[name="Save"]`.

## Directed: `audio`

| key | type | default | meaning |
|---|---|---|---|
| `mode` | enum | `auto` | `none` · `music` · `voiceover` · `both` · `auto` (per export preset; never narration without a narrator). |
| `voice` | string or object | setup | Narrator: `{provider: elevenlabs\|openai, voice, model, speed, style, stability, instructions}`. A string is a voice name/id. Unset fields come from the app's setup. No on-device voices exist. |
| `music` | object or string | composed | Unset → licensed library, else an original score composed to the edit (ElevenLabs Music, paid plan). `"compose"` / `{compose: {bpm, mood}}` · `{track: "incompetech:…"}` · `{find: {mood, feel, bpm: [lo, hi], …}}` · `{path, license?, title?, artist?}` · `{generate: {…}}` · `"none"`. Also `volume`, `offset`, `showCredit`. |
| `text` | enum | `headline` | Without narration, `say` lines become `headline`s above the device, or `caption` pills. |
| `sync` | enum | `beats` | `beats`: beats start on the grid, clicks/taps/selects snap to half-beats within 0.22s, scenes run to the next beat, the video ends on a bar. `none`: no snapping. |

## Directed: `beats`

| key | type | meaning |
|---|---|---|
| `say` | string | The line (≤ ~8s; one idea). Spoken with a narrator; otherwise a headline. ElevenLabs audio tags (`[excited]`) are spoken, never shown. |
| `shot` | string or object | A 3D device shot for this beat: `"hero"` or `{move: hero\|orbit\|rise\|tilt\|flat\|dolly\|closeup\|macro\|duo\|slide\|turntable\|spin\|float, duration, finish, reflection, focus: [x, y], offset}`. |
| `broll` | string or object | AI B-roll under this beat's scene: `{prompt, seconds, provider: veo\|sora\|fal, model, image, aspect, text}`. Never the app's UI. |
| `scene` | string or object | Full-screen kinetic type instead of the device: `{style: statement\|punch\|stack\|reveal\|type\|count\|lockup, text, lines, sub, secondary, accent, marker, reveal, background, value, prefix, suffix, icon, cta, transition, size, font, weight}`. A string is a statement. Words land on spoken words, else on beats. |
| `do` | [step] | Actions, each with `why` and optionally `at`. |
| `zoom` / `spotlight` / `highlight` / `caption` / `title` | as steps | Direction at the beat start, lasting the beat unless `duration` is given. |
| `hold` | seconds (0.5) | Linger after the line/actions finish. |
| `gap` | seconds (0) | Pause before this beat — gives the cursor time to travel to an early cue. |
| `minDuration` | seconds | Minimum beat length. |

### Cues (`at`)

| cue | lands |
|---|---|
| `word:New` | when "New" is spoken (`word:it#2` = 2nd occurrence) |
| `auto` *(default for a beat's first action)* | on the spoken word matching the target's label (`text=New task` → "New"), else 40% into the line |
| `start` | 0.35s into the beat |
| `end` | just after the line ends |
| `after` *(default for later actions)* | 0.35s after the previous action (+ pointer travel) |
| `beat` | the first music beat the pointer can make after the previous action |
| number | seconds after the beat starts |

The planner always reserves pointer travel after the previous action; if that makes a cue late it warns and tells you how much `gap` to add. Run `pretty plan` to see every cue, then `pretty record web storyboard.json --check` for a fast dry run that catches broken selectors without recording.

## Type-only videos

`pretty compose storyboard.json -p tiktok` builds a video from beats that are all `scene`s: no URL, no recording. Music, brand and narration work the same way.

## Copy

`pretty lint storyboard.json` (also part of `plan`) flags generic ad-speak, hooks over 7 words, overstuffed scenes, a brand that's never named, and ads that don't end on a lockup. Use the product's own words and name concrete things on screen.
