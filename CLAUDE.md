# Working on Pretty Studio (the code)

- **Using** the tool to make videos: read `docs/AGENT_GUIDE.md` (`pretty guide`). This file covers **changing** the tool.
- The repo lives on Master Storage, and the path has a space, so quote it. Build with `scripts/build.sh` (release CLI + `dist/Pretty Studio.app`, signed ad-hoc). Debug iteration: `swift build --product pretty` and `.build/debug/pretty`.
- Run one heavy job at a time on this 16 GB Mac. A Swift build counts as one, and so does a render or a recording.
- The CLI and the app share `PrettyCore`. `Composer` is the only renderer, used by export, stills, sheets and the editor preview.
- Adding a project key means updating, in this order:
  1. The struct in `Model/Project.swift`, including its `CodingKeys` and its `init(from:)` defaults.
  2. `Bundle/Schema.swift`, which drives the docs and unknown-key warnings.
  3. The renderer.
  4. Optionally, an inspector control in `Sources/PrettyStudio/Inspector.swift`.
- Time bases: zooms, cuts, speed and content overlays use source time. Text, captions and audio use output time. `TimeMap` converts between them.
- Visual changes must be verified. Use `pretty frame <bundle> --at …` and `pretty sheet`, then look at the images. Test bundles live in a scratch dir or `/Volumes/Master Storage/Projects/pretty-studio/video/`.
- Core Image gotcha: `CIColorMatrix` works on unpremultiplied color. For opacity, scale alpha only (`CIImage.opacity`).
- ffmpeg gotcha: never fan one short input into many `adelay` branches that feed `amix`, because it can deadlock. Pre-render sample tracks (see `Media.clickTrack`), and always pass `-t` when an input loops.
