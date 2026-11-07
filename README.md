# pretty-screen-recorder

Agent-first screen recorder for mobile and web demos. It is primarily made to be used by agents, not humans. Runs on Mac.

The app is called **Pretty Studio**. It is an agent-first screen-recording studio for this Mac. It recreates the useful, good-looking parts of CleanShot X 5's **Studio Mode** (Smart Zooms, a smoothed and resizable cursor, click ripples and press effect, keystroke overlays, wallpaper and gradient backgrounds with padding, shadow and corners, a camera bubble, motion blur, aspect ratios, and a cut tool), then adds what agents need to make ads:

- **Scripted recording.** Web storyboards run in headless Chrome at 60 fps Retina, with human-like cursor paths. Desktop recording uses ScreenCaptureKit with cursor, click and key telemetry. iOS Simulator recording adds a clean 9:41 status bar and tap marks.
- **Device and browser frames:** Safari-style browser, macOS window, iPhone (with Dynamic Island, synthetic status and Safari bars for mobile web), iPad, Android, MacBook.
- **Directed videos:** beat storyboards pair each line with intentional actions (each with a `why`), cued to a spoken word or a music beat. The planner places every click, tap, type, scroll and select so it lands on its cue, and `conform` retimes loose simulator or desktop takes to the plan. `audio.mode` (none, music, voiceover, both, auto) chooses the soundtrack per platform.
- **Kinetic type:** full-screen scenes with no device — statement (with highlighter), punch, stack, reveal, typewriter, count-up and an icon lockup end card — dressed in the product's own colors and headline font (`pretty brand` extracts them from a site, an Xcode/web project or an icon). Words land on spoken words or beats. `pretty compose` makes type-only videos. A copy lint flags generic ad-speak.
- **Studio-grade narration or none:** ElevenLabs (Eleven v4, character-exact word timing) or OpenAI (gpt-4o-mini-tts). Keys live in the login Keychain. Without a narrator, `say` lines become headlines above the device. There are no robotic system voices.
- **Creative treatments:** keynote, studio, glow, editorial and cinematic directions set the backdrop (modern lit stages, not wallpapers), type, motion, transitions, score and sound design. A different one is picked per video for a project, so generations don't repeat.
- **Rotato-style 3D components:** Blender (headless) renders the real recorded screen on a 3D phone or iPad. Camera templates include hero turn, orbit, rise, tilt, flat-to-standing, dolly, macro closeup with depth of field, a two-device duo, slide and turntable, plus finishes and a glossy floor reflection. Each shot lands exactly on the flat device. Between shots the device has rise and tilt entrances with a light sweep, plus slow pushes.
- **AI B-roll:** Veo, Sora 2 or fal.ai clips for the human moments, under kinetic type and cached by prompt. The UI itself is never generated.
- **Composed scores and sound design:** ElevenLabs Music writes an original score per edit (intro, build, lift, resolve on the end card), plus whooshes, shimmers and impacts, mixed to exactly -14 LUFS.
- **Mandatory review:** `pretty review` builds a frame pack and checks grain, black or frozen frames, loudness and peaks, dropouts, dated looks, stock music, missing credits and repetition. Agents score a rubric and iterate before delivering.
- **Real music, legally:** your licensed library (Epidemic Sound, Artlist, Musicbed…) first, then Kevin MacLeod's widely heard CC BY 4.0 catalog (incompetech.com), searched by mood and tempo, beat-detected and started on a downbeat. Credits are shown on screen (optional) and written to `credits.txt` next to every render. A generated original score is the fallback.
- **Agent-shaped:** a JSON CLI, a plain-JSON project file with a self-documenting schema and typo detection, `frame` and `sheet` to check visually before rendering, idle-time compression and teleport-to-glide cursor humanizing for slow agent-driven recordings, and platform presets (YouTube, TikTok/Reels/Shorts, Instagram, X, LinkedIn, App Store previews, web hero loops, GIF, ProRes master).
- **A Mac app with Apple-style onboarding:** a guided first run covering the essentials check, a narrator with voice previews and Keychain key storage, music sources, and installing the CLI and the agent skill for Claude Code and Codex. It also has a Settings window (⌘,), a "Move to Applications" prompt when launched from a disk image or Downloads, and a drag-to-Applications DMG (`scripts/make-dmg.sh`). The app bundles the CLI and the web recorder, so it is self-contained.
- **A native editor** with a Studio Mode-style layout: icon rail, inspector panels, a live Metal preview using the same renderer as export, a zoom/clip timeline with blade cutting, and an export sheet. It watches `project.json` live, so an agent and a person can work on the same project at once.

## Layout

```
bin/pretty                launcher (symlinked to ~/.local/bin/pretty)
Sources/PrettyCore/       model, motion (cursor, camera springs, Smart Zooms, idle), renderer (Core Image/Metal), export, recorders
Sources/pretty/           CLI
Sources/PrettyStudio/     SwiftUI/AppKit editor
web-recorder/record.mjs   storyboard-driven Chrome recorder (playwright-core + installed Google Chrome)
docs/AGENT_GUIDE.md       full agent guide (`pretty guide`)
docs/SKILL.md             Claude/Codex skill (installed to ~/.claude/skills/pretty-studio)
examples/                 demo app + storyboards
scripts/build.sh          release build + self-contained app bundle;  scripts/install.sh  launcher + skill
scripts/make-dmg.sh       drag-to-Applications disk image (dmgbuild; sign/notarize with PRETTY_SIGN_ID / PRETTY_NOTARY_PROFILE)
scripts/selftest.sh       end-to-end timing/audio/scene check (narration against scripts/mock-voice-server.py)
```

## Build and install

```bash
"/Volumes/Master Storage/Code/pretty-screen-recorder/scripts/build.sh"
"/Volumes/Master Storage/Code/pretty-screen-recorder/scripts/install.sh"
pretty doctor
```

On Tyler's Mac the whole install (code, build products, node modules, the app) lives on Master Storage, and so do caches and downloaded music (`Dev.noindex/pretty-studio/cache`, `Library/Music`). The internal disk holds only the `~/.local/bin/pretty` symlink, the skill file, `~/.pretty-studio/recording.json` (active-recording state) and `~/Library/Application Support/Pretty Studio/settings.json`. API keys live in the login Keychain (service "Pretty Studio"), never in files.

For other Macs, `scripts/make-dmg.sh` produces `dist/Pretty-Studio-<version>.dmg`. Drag the app to Applications, open it, and the setup walks through the rest.

## How it renders

Each output frame is composed in Core Image, using half-float linear light on the GPU:

1. Background (mesh gradient, color, image, or blurred recording).
2. Two-layer soft shadow from the frame silhouette.
3. Frame chrome, drawn procedurally at the recording's native resolution.
4. The recording itself, masked with continuous-curvature corners.
5. Spotlights and highlights.
6. Click ripples.
7. Cursor sprites (vector macOS cursors).
8. The virtual camera. It is a spring simulation over the output timeline in log-zoom space, with deadzone cursor follow. Motion blur comes from shutter-interval sub-frame averaging.
9. The screen-space HUD: camera bubble, keystrokes, captions, text. Headlines step aside when a zoom pushes the content into their band.
10. Kinetic scenes, composited over (or instead of) the device, with push-through transitions where the words leave before the device returns.
11. Output dither.

Every resample happens once, from the source pixels, so zooms stay sharp. Frames go straight into VideoToolbox H.264, HEVC or ProRes through AVAssetWriter. Audio is mixed by ffmpeg, following the edit's cuts and speed changes.
