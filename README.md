# pretty-screen-recorder

Agent-first screen recorder for mobile and web demos. It is primarily made to be used by agents, not humans. Runs on Mac.

The app is called **Pretty Studio**. It is an agent-first screen-recording studio for this Mac. It recreates the useful, good-looking parts of CleanShot X 5's **Studio Mode** (Smart Zooms, a smoothed and resizable cursor, click ripples and press effect, keystroke overlays, wallpaper and gradient backgrounds with padding, shadow and corners, a camera bubble, motion blur, aspect ratios, and a cut tool), then adds what agents need to make ads:

- **Scripted recording.** Web storyboards run in headless Chrome at 60 fps Retina, with human-like cursor paths. Desktop recording uses ScreenCaptureKit with cursor, click and key telemetry. iOS Simulator recording adds a clean 9:41 status bar and tap marks.
- **Device and browser frames:** Safari-style browser, macOS window, iPhone (with Dynamic Island, synthetic status and Safari bars for mobile web), iPad, Android, MacBook.
- **Ad tooling:** hero/title/kicker/caption/label text with animations, captions (SRT), spotlight, highlight and blur-redaction overlays, a music bed with ducking and loudness normalization, voiceover clips, click sounds, title cards, and multi-part `sequence` stitching with transitions.
- **Agent-shaped:** a JSON CLI, a plain-JSON project file with a self-documenting schema and typo detection, `frame` and `sheet` to check visually before rendering, idle-time compression and teleport-to-glide cursor humanizing for slow agent-driven recordings, and platform presets (YouTube, TikTok/Reels/Shorts, Instagram, X, LinkedIn, App Store previews, web hero loops, GIF, ProRes master).
- **A native editor** (`Pretty Studio.app`) with a Studio Mode-style layout: icon rail, inspector panels, a live Metal preview using the same renderer as export, a zoom/clip timeline with blade cutting, and an export sheet. It watches `project.json` live, so an agent and a person can work on the same project at once.

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
scripts/build.sh          release build + app bundle;  scripts/install.sh  launcher + skill
```

## Build and install

```bash
"/Volumes/Master Storage/Code/pretty-screen-recorder/scripts/build.sh"
"/Volumes/Master Storage/Code/pretty-screen-recorder/scripts/install.sh"
pretty doctor
```

The whole install (code, build products, node modules, the app) lives on Master Storage. The only files on the internal disk are the `~/.local/bin/pretty` symlink, the skill file, and `~/.pretty-studio/recording.json`, which holds the active-recording state.

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
9. The screen-space HUD: camera bubble, keystrokes, captions, text.
10. Output dither.

Every resample happens once, from the source pixels, so zooms stay sharp. Frames go straight into VideoToolbox H.264, HEVC or ProRes through AVAssetWriter. Audio is mixed by ffmpeg, following the edit's cuts and speed changes.
