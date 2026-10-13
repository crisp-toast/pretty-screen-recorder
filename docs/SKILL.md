---
name: pretty-studio
description: Pretty Studio, Tyler's agent-first screen-recording studio on this Mac (a CleanShot X Studio Mode clone). Use it whenever you need a polished product video, ad, demo, walkthrough, App Store preview, landing-page hero loop, GIF, or social clip (TikTok, Reels, Shorts, YouTube, X) of a website, web app, Mac app, or iOS app. It records the screen through scripted Chrome storyboards, ScreenCaptureKit, or the iOS Simulator. Then it adds wallpaper backgrounds, padding, rounded corners and shadows, Smart Zooms, a smooth re-drawn cursor with click ripples, keystroke overlays, device and browser frames, titles, captions, music, idle-time compression, and exports for every platform. Every part is a JSON CLI (`pretty`), and you can check frames as PNGs before rendering.
---

# Pretty Studio

- The CLI is `pretty` (`~/.local/bin/pretty`). The install lives on Master Storage at `/Volumes/Master Storage/Code/pretty-screen-recorder`. If the drive is unmounted, `pretty` prints an error. Tell Tyler.
- The editor app is `dist/Pretty Studio.app`. Open a project with `pretty open <bundle>`.
- **Read the full guide first:** `pretty guide`. Key reference: `pretty schema`, `pretty presets`, `pretty looks`, `pretty backgrounds`.
- Load the `mac-mini` skill too. It explains where outputs go and how to run one heavy job at a time.

## Fast path

```bash
pretty doctor                                             # once per session
pretty record web flow.storyboard.json --project deltabinder --look sky
#   or: pretty record screen --window "App" --duration 20 --compress-idle
#   or: pretty record sim --detach … pretty record stop
pretty inspect <bundle>                                   # zooms, cuts, warnings
pretty set <bundle> cursor.size=1.8 background.preset=dusk
pretty text <bundle> "Headline" --style hero --start 0 --end 3
pretty sheet <bundle> -p tiktok                           # one JPEG of the whole timeline; LOOK at it
pretty render <bundle> -p tiktok                          # → <bundle>/renders/…_vNN.mp4
pretty render <bundle> -p preview                         # small 720p file to send Tyler
```

## Rules of thumb
- Web flows give the best results. Write a storyboard with `click`, `type`, `scroll`, `zoom`, `caption` and `spotlight` steps. Use the `iphone` device for mobile web in a real-looking iPhone frame.
- After every edit, check with `pretty frame <bundle> --at T -p <preset>` before rendering.
- For agent-driven screen or simulator recordings, run `--compress-idle` or `pretty auto <bundle> --idle` to cut the dead time.
- Zooms, cuts and spotlight overlays use **source time**. Text, captions and music use **output time**. `pretty inspect` shows both.
- Send Tyler `-p preview` renders or sheet JPEGs. Keep masters in the bundle on Master Storage.
