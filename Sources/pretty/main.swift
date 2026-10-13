import Foundation
import PrettyCore

let usage = """
pretty — Pretty Studio: agent-first screen recording studio (CleanShot Studio Mode-style polish).
All commands print JSON on stdout; progress and warnings go to stderr.

RECORD (each creates a .prettystudio project bundle)
  pretty record web <storyboard.json> [-o bundle] [--project P] [--look L] [-p preset] [--force] [--compress-idle]
        Script a browser (desktop / iphone / ipad / android viewports) and record it. See `pretty guide`.
  pretty record screen [--display N | --window "App[:title]" | --region x,y,w,h] [--duration S]
        [--system-audio] [--mic] [-o bundle] [--project P] [--detach]   (stop with `pretty record stop`)
  pretty record sim [--device booted|UDID] [--duration S] [-o bundle] [--detach]
  pretty record stop [bundle]          Stop a detached screen/sim recording and build the project.
  pretty mark <bundle> tap X Y | key "cmd+k" | zoom [--duration S] [--rect x,y,w,h] | caption "text"
        Log events into an in-progress recording (e.g. while an agent drives the simulator).
  pretty new <video> [--events e.json] [--camera cam.mov] [--kind K] [--look L] [-p preset] [-o bundle]
  pretty new --card [--duration 3] [--look L] [-p preset] -o card.prettystudio   (title card: background + text)

EDIT (bundle = .prettystudio dir or project.json)
  pretty inspect <bundle>              Durations, zooms, cuts, overlays, warnings. Start here.
  pretty set <bundle> key=value ...    e.g. cursor.size=2 background.preset=sunset layout.aspect=9:16
  pretty get <bundle> [key]
  pretty auto <bundle> [--zooms] [--idle]   Regenerate Smart Zooms and/or idle compression.
  pretty zoom <bundle> add --start S --end E [--level 1.8] [--focus x,y] [--manual] | list | clear [--auto] | rm ID
  pretty cut <bundle> START END        pretty speed <bundle> START END RATE      pretty trim <bundle> START [END]
  pretty text <bundle> "Headline" [--start 0] [--end 3] [--style title|hero|subtitle|kicker|caption|label]
        [--position top|center|bottom] [--x 0-1] [--y 0-1] [--size 1] [--color C] [--fill C] [--weight W]
        [--animation rise|pop|fade|slide|typewriter|none] [--time output|source]
  pretty text <bundle> ls | rm INDEX
  pretty caption <bundle> --srt file.srt | "text" --start S --end E
  pretty music <bundle> song.m4a [--volume 0.25]
  pretty validate <bundle>

RENDER
  pretty frame <bundle> --at T [-p preset] [-o out.png]      Render one frame (check your edit!)
  pretty sheet <bundle> [--count 12] [-p preset] [-o sheet.jpg]   Contact sheet of the whole timeline
  pretty render <bundle> [-p preset] [-o out.mp4] [--fps N] [--quality q] [--format f] [--resolution r]
  pretty sequence <sequence.json> [-o out.mp4]               Stitch cards + projects + clips into an ad

REFERENCE
  pretty guide          Full agent guide (workflows, storyboard format, recipes)
  pretty schema         Every project.json key with type, default and meaning
  pretty presets | looks | backgrounds [--sheet out.jpg]
  pretty doctor         Check ffmpeg, Chrome, Master Storage, permissions
  pretty open <bundle>  Open in the Pretty Studio editor app
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first, cmd != "help", cmd != "--help", cmd != "-h" else {
    print(usage); exit(0)
}
let args = Args(Array(argv.dropFirst()))
if args.has("quiet") { Log.quiet = true }
if args.has("help") {
    // Per-command help: the usage lines for this command (and their continuation lines).
    var out: [String] = [], keep = false
    for line in usage.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("  pretty ") { keep = line.hasPrefix("  pretty \(cmd)") || line.contains("| \(cmd) ") || line.contains("pretty \(cmd)") }
        else if !line.hasPrefix("        ") { keep = false }
        if keep { out.append(line) }
    }
    print(out.isEmpty ? usage : out.joined(separator: "\n") + "\n\nMore: pretty guide")
    exit(0)
}

do {
    switch cmd {
    case "new": try cmdNew(args)
    case "record": try cmdRecord(args)
    case "mark": try cmdMark(args)
    case "inspect", "info": try cmdInspect(args)
    case "set": try cmdSet(args)
    case "get": try cmdGet(args)
    case "auto": try cmdAuto(args)
    case "zoom", "zooms": try cmdZoom(args)
    case "cut": try cmdCut(args)
    case "speed": try cmdSpeed(args)
    case "trim": try cmdTrim(args)
    case "text", "title": try cmdText(args)
    case "caption", "captions": try cmdCaption(args)
    case "music": try cmdMusic(args)
    case "validate": try cmdValidate(args)
    case "frame", "still": try cmdFrame(args)
    case "sheet", "storyboard": try cmdSheet(args)
    case "render", "export": try cmdRender(args)
    case "sequence": try cmdSequence(args)
    case "presets": cmdPresets()
    case "looks": cmdLooks()
    case "backgrounds": try cmdBackgrounds(args)
    case "schema": print(Schema.reference())
    case "guide": try cmdGuide()
    case "doctor": try cmdDoctor()
    case "open": try cmdOpen(args)
    case "_cursor": try cmdDebugCursor(args)
    case "version", "--version": emit(["version": "1.0.0", "home": Home.root.path])
    default:
        FileHandle.standardError.write("unknown command '\(cmd)'\n\n\(usage)\n".data(using: .utf8)!)
        exit(64)
    }
} catch {
    printJSON(["ok": false, "error": "\(error)"])
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
