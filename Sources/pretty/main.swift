import Foundation
import PrettyCore

let usage = """
pretty — Pretty Studio: agent-first screen recording studio (CleanShot Studio Mode-style polish).
All commands print JSON on stdout; progress and warnings go to stderr.

RECORD (each creates a .prettystudio project bundle)
  pretty record web <storyboard.json> [-o bundle] [--project P] [--look L] [-p preset] [--force] [--compress-idle]
        Script a browser (desktop / iphone / ipad / android viewports) and record it. Format: `pretty schema --storyboard`.
        --check runs every step fast without recording (catches bad selectors). Exits 4 if any step failed.
  pretty record screen [--display N | --window "App[:title]" | --region x,y,w,h] [--duration S]
        [--system-audio] [--mic] [-o bundle] [--project P] [--detach]   (stop with `pretty record stop`)
  pretty record sim [--device booted|UDID] [--duration S] [-o bundle] [--detach]
  pretty record stop [bundle]          Stop a detached screen/sim recording and build the project.
  pretty mark <bundle> tap X Y | key "cmd+k" | zoom [--duration S] [--rect x,y,w,h] | caption "text"
        Log events into an in-progress recording (e.g. while an agent drives the simulator).
  pretty new <video> [--events e.json] [--camera cam.mov] [--kind K] [--look L] [-p preset] [-o bundle]
  pretty new --card [--duration 3] [--look L] [-p preset] -o card.prettystudio   (title card: background + text)

DIRECT (tailored copy + kinetic type + narration + real music + intentional, cued actions)
  pretty brand <site | project dir | icon.png> [--project P] [-o dir] [--name] [--tagline] [--cta] [--colors #a,#b] [--icon f]
        The product's name, promise, colors, icon, logo and font → brand.json (use as "brand" in storyboards).
  pretty lint <storyboard.json>            Generic ad-speak, long hooks, missing lockup, product never named.
  pretty plan <storyboard.json> [-p preset] [--out dir]   Time a beat storyboard: say/do/why/at/scene → plan.json + timeline.
        `record web` plans automatically when the storyboard has "beats". Review warnings first.
        Storyboard format: `pretty schema --storyboard`.   Dry run: `pretty record web <storyboard> --check`.
  pretty compose <storyboard.json> [-o bundle] [-p preset]   Type-only video from scene beats (no recording).
  pretty conform <bundle> --plan plan.json   Retime a loose sim/desktop take so clicks land on the plan's cues.
  pretty voice list [--provider elevenlabs|openai] | say "text" [-o f] [--voice V] | add <bundle> "text" --at T
        | add <bundle> --file vo.mp3 --at T [--text] | clear <bundle>        (ElevenLabs / OpenAI only; no system voices)
  pretty music search [text] [--mood upbeat|confident|corporate|chill|playful|cinematic|dramatic|minimal] [--bpm 100-125]
        [--min S] [--famous] | get <track> | use <bundle> <track> [--volume] | library | moods
        Real tracks: your licensed folder, then Kevin MacLeod (CC BY 4.0, credited automatically).
  pretty music generate [<bundle>] [--mood upbeat|corporate|chill|cinematic|minimal] [--bpm N] [-o f.wav]   (original fallback)
  pretty music analyze <file|bundle>        Tempo + downbeat of a track (enables beat sync).
  pretty credits <bundle> [-p preset]       Credit lines the published video must carry (also written next to renders).
  pretty shots <bundle> [-p preset]         Render the project's 3D device shots now (Blender).
  pretty broll "prompt" [--provider veo|sora|fal] [--seconds 6] [--aspect 9:16] [--image f] [--treatment T]   One AI B-roll clip.
  pretty review <bundle | render.mp4> [-p preset]   MANDATORY before delivering: review pack + objective checks + rubric.
  Soundtrack: pretty set <bundle> audio.mode=none|music|voiceover|both|auto

SETUP (the app's Settings window does all of this with previews)
  pretty setup [status] | setup voice --provider elevenlabs|openai|none [--voice NAME] [--model M] [--speed] [--style]
        | setup music [--licensed DIR|none] [--incompetech on|off] [--generated on|off] [--credits on|off]
  pretty keys set <elevenlabs|openai|gemini|fal> (hidden prompt or stdin; login Keychain) | test | remove <p> | status

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
  pretty music <bundle> song.m4a [--volume 0.25]   (tempo/downbeat detected for beat sync)
  pretty validate <bundle>

RENDER
  pretty frame <bundle> --at T [-p preset] [-o out.png]      Render one frame (check your edit!)
  pretty sheet <bundle> [--count 12] [-p preset] [-o sheet.jpg]   Contact sheet of the whole timeline
  pretty render <bundle> [-p preset] [-o out.mp4] [--fps N] [--quality q] [--format f] [--resolution r]
  pretty sequence <sequence.json> [-o out.mp4]               Stitch cards + projects + clips into an ad

REFERENCE
  pretty guide          Full agent guide (workflows, storyboard format, recipes)
  pretty schema         Every project.json key with type, default and meaning (--storyboard: storyboard format)
  pretty presets | looks | backgrounds [--sheet out.jpg]
  pretty doctor         Check ffmpeg, Chrome, narration, music, Master Storage, permissions
  pretty open <bundle>  Open in the Pretty Studio editor app
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first, cmd != "help", cmd != "--help", cmd != "-h" else {
    print(usage); exit(0)
}
let args = Args(Array(argv.dropFirst()))
Shots.defaultTools = .find(script: Home.root.appendingPathComponent("scripts/blender/device_shot.py"))
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
    case "music": try cmdMusicDispatch(args)
    case "voice", "voiceover": try cmdVoice(args)
    case "plan": try cmdPlan(args)
    case "setup": try cmdSetup(args)
    case "keys", "key": try cmdKeys(args)
    case "credits": try cmdCredits(args)
    case "brand": try cmdBrand(args)
    case "lint": try cmdLint(args)
    case "compose": try cmdCompose(args)
    case "review": try cmdReview(args)
    case "broll": try cmdBroll(args)
    case "shot", "shots": try cmdShots(args)
    case "conform": try cmdConform(args)
    case "validate": try cmdValidate(args)
    case "frame", "still": try cmdFrame(args)
    case "sheet", "storyboard": try cmdSheet(args)
    case "render", "export": try cmdRender(args)
    case "sequence": try cmdSequence(args)
    case "presets": cmdPresets()
    case "looks": cmdLooks()
    case "backgrounds": try cmdBackgrounds(args)
    case "schema":
        if args.has("storyboard") {
            let doc = Home.root.appendingPathComponent("docs/STORYBOARD.md")
            print((try? String(contentsOf: doc, encoding: .utf8)) ?? "storyboard reference missing: \(doc.path)")
        } else { print(Schema.reference()) }
    case "guide": try cmdGuide()
    case "doctor": try cmdDoctor()
    case "open": try cmdOpen(args)
    case "_cursor": try cmdDebugCursor(args)
    case "version", "--version": emit(["version": "1.1.0", "home": Home.root.path])
    default:
        FileHandle.standardError.write("unknown command '\(cmd)'\n\n\(usage)\n".data(using: .utf8)!)
        exit(64)
    }
} catch {
    printJSON(["ok": false, "error": "\(error)"])
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
