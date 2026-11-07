---
name: pretty-studio
description: Pretty Studio, Tyler's agent-first video studio on this Mac (a CleanShot X Studio Mode clone, plus directing). Use it whenever you need a polished product video, ad, demo, walkthrough, App Store preview, landing-page hero loop, GIF, or social clip (TikTok, Reels, Shorts, YouTube, X) of a website, web app, Mac app, or iOS app. Videos are directed and tailored — every click has a reason and lands on its cue — with a creative treatment per video, Rotato-style 3D device shots as components (hero turns, orbits, close-ups, duos — rendered with Blender), AI B-roll (Veo/Sora/fal), restrained kinetic type in the product's own font, studio-grade narration or none, an original composed score with sound design, and a mandatory `pretty review` before anything ships. Every part is a JSON CLI (`pretty`).
---

# Pretty Studio

- The CLI is `pretty` (`~/.local/bin/pretty`). The install lives on Master Storage at `/Volumes/Master Storage/Code/pretty-screen-recorder`. If the drive is unmounted, `pretty` prints an error. Tell Tyler.
- The app (`Pretty Studio.app`) has the setup window (voice, music, agents) and the editor. Open a project with `pretty open <bundle>`.
- **Read the full guide first:** `pretty guide`. Reference: `pretty schema`, `pretty schema --storyboard`, `pretty presets`.
- Load the `mac-mini` skill too. It explains where outputs go and how to run one heavy job at a time.

## Make it about THIS product (never generic, never cheesy)
1. `pretty brand <site | ~/code/<app> | icon.png> --project <app>` gives the name, promise, colors, icon, logo and font. Review it.
2. Mine the product's own copy (App Store text, site headline, UI labels). Name concrete things on screen. Never invent numbers or claims.
3. Beat storyboard: hook `scene` (≤7 words) → `say` + `do` beats (every action has a `why` and a cue) → a `broll` beat for emotion when a video key exists → a closing `lockup`. On phones the first device beat becomes a 3D hero `shot` automatically.
4. Leave `treatment` and `music` unset: the planner picks a fresh treatment for the project and composes the score. Don't add `marker`, pastel backgrounds, `punch` spam or happy-stock tracks.
5. `pretty lint` → `pretty plan -p tiktok` (fix every warning; `--no-generate` while iterating) → `pretty record web … --check` → record → `pretty sheet` → `pretty render -p tiktok`.
6. **`pretty review <bundle>`, then LOOK at sheet.jpg and every moments/*.jpg and score the rubric.** Fix and re-render until there are no blockers or majors and every line scores 4+. Never deliver an unreviewed video; report blockers you can't fix (e.g. the ElevenLabs plan) to Tyler.

## Audio
- **Narration is studio-grade or absent.** Run `pretty setup status`. Never handle API keys. Tyler adds them in the app (Settings → Voice / Video & 3D) or with `pretty keys set`.
- **Music is composed for the edit** (ElevenLabs Music; needs a paid plan, and the review blocks free-plan output for ads), or comes from Tyler's licensed library. The classic CC BY catalog is opt-in and often reads as stock. Chart hits are impossible. Every render writes `*.credits.txt`.
- Sound design (whooshes, shimmer, impact) is planned automatically.

## Fast path

```bash
pretty doctor && pretty setup status                      # once per session
pretty brand https://example.com --project example
pretty plan ad.directed.json -p tiktok                    # timeline + warnings
pretty record web ad.directed.json --check                # dry run, no recording
pretty record web ad.directed.json --project example
pretty sheet <bundle> -p tiktok                           # one JPEG of the whole timeline; LOOK at it
pretty render <bundle> -p tiktok                          # mp4 + credits.txt (3D shots render first)
pretty review <bundle>                                    # mandatory: look at the pack, fix, re-render
pretty compose teaser.json -p tiktok                      # type-only video (scenes + music)
```

## Rules of thumb
- Web flows give the best results; `device: iphone` for mobile web in a real iPhone frame. Simulator takes: `pretty record sim` (captures to the internal disk, then moves to Master Storage), perform the plan, `pretty conform <bundle> --plan plan.json`.
- Put direction that depends on an action (a zoom after a scroll) inside `do` with `"at": "after"`.
- Zooms, cuts and spotlight overlays use **source time**. Text, captions, scenes and music use **output time**.
- Send Tyler `-p preview` renders or sheet JPEGs. Keep masters on Master Storage (`Projects/<app>/exports`).
