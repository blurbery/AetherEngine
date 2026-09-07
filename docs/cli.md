# aetherctl

A standalone macOS CLI shipped alongside the library for repro work without going through TestFlight + Apple TV. Most subcommands operate on a media source URL (`file://` or `http(s)://`); `live`, `dvr`, `hlsfixture`, and `hlslive` run against built-in synthetic fixtures.

```bash
swift run aetherctl probe <url>          # dump container + streams + duration, exit
swift run aetherctl serve <url>          # park the engine's loopback HLS-fMP4 server
swift run aetherctl validate <url>       # serve + run mediastreamvalidator, exit
swift run aetherctl segverify <url>      # SW-decode each loopback segment in isolation; report independence (#92)
swift run aetherctl swdecode <url>       # open SoftwareVideoDecoder, decode N packets, report
swift run aetherctl play <url>           # full load+play session smoke test: 1 Hz telemetry, cue log, host-call mimicry
swift run aetherctl dovitest <url>       # convert a DV Profile 7 stream to 8.1, dump for dovi_tool
swift run aetherctl pktdump <url>        # dump raw demuxer packet timing (dts/pts/keyframe) per open profile
swift run aetherctl dualsubs <file> ...  # dual subtitle-track render probe (--primary / --secondary stream index)
swift run aetherctl extract <url>        # FrameExtractor still-image extraction + leak testing
swift run aetherctl audio [--seconds N] <url>   # audio-only pipeline smoke test (default 10 s)
swift run aetherctl audiotap <url>       # decode the PCM audio tap headless, write mono 48 kHz WAV (#95)
swift run aetherctl bgaudio <url>        # SW-path background-audio keepalive probe (iOS background behavior)
swift run aetherctl customio <path>      # exercise the custom IOReader path end-to-end
swift run aetherctl disc-inspect <path>  # walk a local DVD / Blu-ray ISO: titles, chapters, recognition stages
swift run aetherctl live                 # live MPEG-TS session against the built-in fixture
swift run aetherctl dvr                  # DVR rewind matrix across native + SW paths
swift run aetherctl hlsfixture <ts>      # local HLS live fixture with fault knobs + ingest self-test
swift run aetherctl seektest <url>       # rapid-seek burst repro + clock-bounce / isSeeking probe
swift run aetherctl hlslive              # SSAI live-direct-play repro against a synthetic ad-pod feed
swift run aetherctl smbtest <smb-url>    # play a file off an SMB2/3 share via the AetherEngineSMB reader
swift run aetherctl <url>                # alias for serve (backwards compat)
```

Twenty-one subcommands plus the bare-URL `serve` alias.

## probe

Opens the demuxer, prints the codec / resolution / frame rate of the video track, the audio track list (codec, channels, language, Atmos flag), the subtitle track list, the parsed container metadata (`MediaMetadata`: title / artist / album / albumArtist + embedded cover art presence), then exits. No HLS server is started.

## serve

The original behavior. The CLI prints the loopback URL and parks until Ctrl-C; from another terminal you can:

```bash
curl -i  http://127.0.0.1:<port>/master.m3u8
curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/init.mp4
mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
mp4dump --verbosity 1 /tmp/init.mp4
ffprobe -v debug /tmp/seg0.mp4
open 'http://127.0.0.1:<port>/master.m3u8'   # macOS QuickTime
```

`--no-dv` forces the SDR / HDR10 route even for a Dolby Vision source (compare the two playlists).

`--force-dv` is `LoadOptions.forceDolbyVisionOnNonDVDisplay` (AE#455): a Profile 8.1 source is served as a Profile 5, so the master reads `CODECS="dvh1.05.LL"` and `init.mp4` carries a `dvh1` sample entry with a `dvcC` claiming profile 5. It only has an effect together with `--no-dv`. Serve the same file twice and diff `mp4dump --verbosity 1 init.mp4` to see the sample entry and the record move. Available on `serve`, `validate` and `segverify`.

`--native-subs <index>` turns on the native WebVTT subtitle renditions (the `LoadOptions.prepareNativeSubtitles` path a full session uses): the engine calls `requestNativeSubtitleTrack()` before `start()`, then `attachAllNativeSubtitleStores()` after start. Every non-bitmap text track is served as a language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` rendition (`DEFAULT=NO,AUTOSELECT=NO`) in the master playlist, backed by a per-track `subs_N.m3u8` WebVTT media playlist. (An earlier design muxed `mov_text`/tx3g traks into the fMP4; in-band timed text is not HLS-conformant and AVPlayer rejected it, so the WebVTT rendition replaced it, see [formats.md › Native subtitle renditions](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).) The `<index>` value is legacy and now ignored, kept only for CLI compatibility: every non-bitmap track is always declared, and actual track selection happens via the host API in a full session, not from this flag. `curl` the `master.m3u8` (or open it in QuickTime) to verify the `SUBTITLES` group + `subs_N.m3u8` endpoints enumerate every language as a legible `AVMediaSelection` group. Omit the flag to reproduce the default behavior (no renditions, output identical to before).

`--throttle-kbps N` is a TEST-ONLY slow-CDN simulation: it caps source-IO delivery to N kbit/s. Set it below the stream bitrate to starve the producer below real-time and provoke AVPlayer rebuffers (for example the #92 open-GOP repro). Also available on `seektest` and `play`.

`--start-position S` starts the session at S seconds, the resume anchor a host passes to `load(url:startPosition:)`. Also available on `play`.

`--audio-delay <ms>` parks the server with the AE#464 audio offset already in its muxer, which is how the DELIVERED offset is measured rather than argued about: fetch the media playlist and walk its segments, then read the first audio and video packet timestamps out of `init.mp4` + a segment with `ffprobe -show_entries packet=stream_index,pts_time`. On a 30 fps H.264 + AAC fixture the source's own alignment is +21.8 ms, `--audio-delay 200` reads +221.8 ms and `--audio-delay -150` reads -128.2 ms, i.e. exactly the offset asked for, with the video timestamp unchanged in every arm.

## validate

`serve` plus an inline `xcrun mediastreamvalidator` run against the loopback manifest, with the report printed and the engine torn down on completion.

## swdecode

Opens `SoftwareVideoDecoder` for the source's video stream, feeds up to N packets (default 100, override with `--frames N`), and reports counters plus first-frame metadata (pixel format, dimensions). Tests the SW-pipeline decode path end-to-end without needing a render layer. Useful for legacy codecs (MPEG-4 Part 2, MPEG-2, VC-1) and AV1 / VP9 on platforms where the native AVPlayer path doesn't accept them. Verdict distinguishes three failure modes:

- decoder open failed (FFmpegBuild gate or malformed extradata)
- decoder opened but no frames produced (pixel-format conversion, no IDR in window)
- SW decode end-to-end healthy (if real playback still hangs, the failure is downstream in `SoftwarePlaybackHost` frame-enqueue, display-layer attach, or audio-clock sync)

Backed by the public `AetherEngine.swDecodeProbe(url:maxPackets:options:)` static API returning `SoftwareDecodeProbeResult`. Hosts can use the same probe in their own diagnostic overlays.

## play

Runs a full `load()` + `play()` session exactly like a host app and prints 1 Hz transport telemetry (state, phase, currentTime, sourceTime, buffered frontier, duration) plus the network half of the same `liveTelemetry` snapshot a host reads (`net` throughput, `rx` what the playback consumer pulled over its own link, `origin` what the session pulled from the SOURCE, `ahead` fetched-but-unconsumed window, `cushion` decoded video past the clock, `fwd` native forward buffer, `drop` / `delay`). Fields absent on the running path are omitted, so a software session reads `cushion` where a native one reads `fwd`. Note that `drop` climbs steadily in a CLI run: nothing binds a render surface, and the renderer drops what it cannot present. `rx` and `origin` are two different links and routinely disagree: on the native path `rx` counts what AVPlayer fetched from the engine's own loopback server, so a live session whose source has gone quiet can keep raising `rx` out of the segment cache while `origin` stays flat. An origin question is an `origin` question (AE#443, where a fall in `rx` was read as an origin socket event). Both are session totals: they are summed across AVFoundation's access-log entries and across the subsystems a live reopen replaces, so neither falls back mid-session. Where `swdecode` proves the decoder, `play` proves the transport: it fails loud on the two silent failure modes of a session that "loads fine" but never actually plays (#107): exit 2 when the clock does not advance, exit 3 when a selected subtitle track produces no cues.

```bash
swift run aetherctl play <url>                                  # VOD load, 30 s telemetry
swift run aetherctl play --seconds 60 <url>                     # longer window
swift run aetherctl play --live --dvr-window 1800 <url>         # live path with a DVR ring
swift run aetherctl play --subs teletext <url>                  # activate the first matching subtitle track, log every cue + trim
swift run aetherctl play --host-calls reloadlive,play,extractor,setrate <url>   # mimic a host's post-load call sequence
swift run aetherctl play --live --dvr-window 1800 --audio-stats <url>           # decoded-PCM continuity + per-second audio lead
swift run aetherctl play --live --native-hls <master.m3u8>      # nativeRemoteHLS bypass (carriage watchdog + #293 probe)
swift run aetherctl play --sidecar de=/tmp/de.srt --subs de <master.m3u8>   # declare a sidecar at load (#316)
```

`--sidecar <lang>=<path-or-url>[,<lang>=<path>...]` fills `LoadOptions.externalSubtitles`, the load-time
declaration a host makes. On a remote `m3u8` this is what makes the engine stand up its rewritten master
(#316), so it is the way to see the whole chain from the CLI: the served `master.m3u8` body is logged, the
engine reports how many renditions it injected, and selecting the track (`--subs <lang>` matches the
external track by language) shows the `subs_N.m3u8` and `subs_N_0.vtt` fetches arriving. The end-of-run
`subtitle tracks` line is the settled list a host's picker would show, with `*` marking external ids; note
that `cues=0` and "no cues arrived" are CORRECT there, because AVPlayer renders a rendition itself and the
overlay pipeline stays empty (same as AE#154).

`play` prints a `PHASE <phase> t+Ns` line on every `playbackPhase` edge, stamped from the load call on
the same clock as `FIRSTFRAME`. The 1 Hz tick samples the phase, which is far too coarse to tell a start
signal apart from the moment the rate rolls; a healthy native join is exactly two edges, `loading` at the
load and `playing` at the roll (AE#440).

`--subs <codec-or-lang>` matches against the track's libavcodec name or language and logs every overlay cue and cue trim as it lands. `--host-calls` replays host post-load behavior against the fresh session: `play`, `extractor` (`makeFrameExtractor`), `setrate` (`setRate(1.0)`), `ratehold` (set 1.5, pause at tick 3, resume at tick 5, then read the rate back off the transport itself: the #436 drill, and it fails the run if the resume came back at 1.0), `reloadlive` (reload the URL on the live path when the probe flags it live, the AetherPlayer Open URL flow), `seekback` (rewind 20 s into the DVR window at t=15, return to the live edge at t=30), `overlapseek` (the #292 seek-window drills below), and `pauseseek` (pause at t=12, seek at t=15 while paused, resume at t=20; with `--sw` the five paused ticks between landing and resume show what the `[SWDiag]` line reports while the pump is parked and has not heard of the seek, the AE#479 shape); this is how the pre-arming `setRate` wedge was isolated.

`--seek-every N` seeks once every N ticks past tick 10, walking `--seek-pattern <abs,abs,...>` if one is given (a short backward hop otherwise), and `--seek-count K` stops after K seeks so a run can be a BURST and then play. Both halves are needed for anything about what a seek sequence leaves behind: the burst puts the store in the state under test, and only the playing half shows what the overlay carries through it. That pairing is what made AE#362's second mechanism reproducible (a hole between a restarted pump and the island the previous run left ahead of it, decoded across and then never re-read).

`--host-calls overlapseek` (pair it with `--sw`) runs three drills at t=8, each making a transport call while a seek's demuxer reposition is still in flight, which is the window #254 opened by moving that reposition off the main actor: **A** a second same-target seek (the #292 report: a scrub arriving as two seeks, the second superseding the first), **B** a `pause()`, **C** a `play()` from paused. `seektest` cannot reach any of this because it awaits every seek, so its bursts are strictly serial. Each drill heals the session with pause + play first, so a defect one drill provokes is not inherited by the next, and each reports its own PASS / FAIL / INCONCLUSIVE (`inWindow=NO` means the call arrived after the landing and the run proves nothing). Exit 4 when any drill fails, 5 when any is inconclusive. Before the #292 fix, A and C land the clock at `rate=0.0` while the engine reports `.playing` and B silently keeps playing through the pause.

`--live-ingest` loads the URL through `HLSLiveIngestReader` as a custom source, which is the shape a host uses for a live channel it ingests and re-serves itself (Sodalite's direct live path). Pair it with `--live`. It reaches the reader DIRECTLY, which is what a repro of the reader itself needs; since AE#363 plain `--live` also ends up there, but by way of the engine's own route (the raw live path detects the playlist and hands it to the ingest), so use `--live-ingest` when the reader is the subject and plain `--live` when the routing is. `hlslive` only serves local `.ts` files. AE#359 (the master's SUBTITLES renditions were parsed away) survived precisely because this path had no harness; `--live-ingest --subs <lang>` reproduces and verifies it in 40 s against a public broadcaster URL.

`--fast-zap` sets `LoadOptions.liveJoinProfile = .fastZap` for the load. `live` has carried the flag for its own raw-TS fixture since AE#195, but that fixture has no upstream playlist, and the served `#EXT-X-TARGETDURATION` is floored by the UPSTREAM's observed arrival cadence (`LiveCadencePolicy`), which is what sizes the holdback the first serve waits for. So fastZap against an origin of one's own, the shape a downstream player actually ships, could not be driven from here at all. Measured on the same 1 s-GOP seed, `--preroll 0 --realtime`: raw TS with no playlist serves at 1.325 s on TARGETDURATION 1 (holdback 3 s, full cushion), the same content behind an `hlsfixture` origin cutting 2 s segments serves on TARGETDURATION **2** (holdback 6 s) although the engine re-cut it at 1 s. Pair it with `--live`, and read the first-serve line (AE#374) rather than a first-frame stopwatch.

`--live-start-immediately` / `--no-live-start-immediately` set `LoadOptions.liveJoinStartsImmediately`,
which cuts AVPlayer's stall-avoidance hold short once at the live join (AE#440). It is **on by default**
since 6.55.0, so `--no-live-start-immediately` is the flag that drives the control arm now; the positive
one is still accepted. **The hold it addresses does not reproduce on this harness**, and that is itself the finding: measured on 6 window geometries against the raw-TS fixture
at `--realtime --preroll 0` (shallow window under the holdback, window exactly at it, and a deep window
from `--preroll 6/12/30`), the gap between `layer.isReadyForDisplay=true` and `timeControlStatus=playing`
stayed between 10 and 60 ms every time, against 1.5 to 2.8 s reported on an Apple TV 4K over the same
shape.
Loopback answers at memory speed, so AVPlayer's buffering-rate evaluation concludes at once. The flag is
here to drive the engine end of a device A/B, not to prove anything from a Mac. That A/B has since run
(AE#440, on 6.53.0) and is what turned the default on; see the live-join section of `api.md` for its
numbers.

`--header "Name: Value"` (repeatable) fills `LoadOptions.httpHeaders` and, on `--live-ingest`, the reader's own fetches. Origins that enforce a per-request `User-Agent` / `Referer` / `Authorization` (tokenized IPTV, STB profiles) could not be driven from the CLI at all before AE#363; pair it with `hlsfixture --require-header` below to have both ends of the contract in one run.

`--native-hls` sets `LoadOptions.nativeRemoteHLS`, the path a host uses for a live channel AVPlayer can play itself. It is the only way to exercise the #168 carriage watchdog, the #293 carriage probe and the AE#363 origin-refusal reroute from the CLI (`hlslive` loads the ingest reader directly and never mounts natively). Pair it with `--live`; without that the m3u8 takes the raw live path, which since AE#363 routes it onto the ingest instead of mounting AVPlayer at all.

`--switch-audio <index>[@ms]` replays a host applying a viewer's language preference just after playback starts (default +20 ms, the #337 field case): the engine rebuilds the session with the new stream at `resumeAt = 0`, which is the only shape where the rebuilt session's video renderer can fill before the newly selected stream's first packet arrives. Pick a stream whose first packet sits late in the mux and the run before the fix reads `state=playing cur=0.00` for its whole length with a first frame on screen; the end-of-run verdict names it. `--audio-stats` alongside it re-installs the tap after the switch, because the tap is bound to the software host the switch replaces and would otherwise report silence for a session that is playing fine. Build a fixture with a late track by offsetting one input: `ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30:duration=40 -f lavfi -i sine=frequency=440:duration=40 -itsoffset 12 -f lavfi -i sine=frequency=660:duration=28 -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a libopus late-audio.mkv`.

`--teletext-page N` sets `LoadOptions.teletextPage` for the load, and `--switch-teletext-page <page|auto>[@ms]` changes it on a channel that is already playing (default +20 s, deliberately long: the switch has to land after `--subs` has a teletext track showing, else the run measures the load option it could already measure). The engine states what the change reached, `re-decoding N channel(s)` or `no active teletext track to re-decode`, so a page that does nothing is distinguishable from a page that never arrived. Real teletext needs a broadcast transport stream; there is no way to synthesise one with ffmpeg, so the CLI check covers the wiring and the gate, and the decode itself is confirmed against a live DVB channel (#364).

`--audio-delay <ms>` sets `LoadOptions.audioDelaySeconds` for the load, and `--switch-audio-delay <ms>[@ms]` calls `setAudioDelay(_:)` on a session that is already playing (default +20 s, same reason as the teletext switch). The runtime half is the interesting one: at load the offset is just a number handed to a muxer or a renderer, while mid-session it has to reach media the session has already committed to the previous value, and the two routes pay differently for that (a seek on `.software`, the session-preserving reload on `.loopback`). The engine states the delivered offset rather than the requested one: `[AudioOutput] AE#464 audio delay in effect: +200 ms (sample at 3.994s delivered at 4.194s)` on the software path, `[MP4SegmentMuxer] AE#464 cutting seg1+ with audio delay -150 ms` on the loopback one (AE#464).

`--switch-audio-delay` is repeatable and `--paused` mounts with `autoplay = false`, which is what makes
the round-2 pair of AE#464 reproducible without hardware. `--paused --host-calls play` is a host that
owns transport (mount paused, play next to its own load), and the rebuild the engine raises for a nudge
has no such caller: before the fix item #2 settled `timeControlStatus=paused reason=- t+0.00s`, never
reached `playing`, and the producer parked on `#65 backpressure PARK (advance) ... (consumer paused)`
while the run still ended `VERDICT: OK`. After it, `#2 timeControlStatus=playing t+0.06s`. Three presses
inside one runloop turn (`--switch-audio-delay 50@15000 --switch-audio-delay 100@15003
--switch-audio-delay 150@15006`) stack three reloads, two superseded by generation, and before the fix
the survivor loaded `startPos=nil` and cut `seg0+` on a session 14.90 s in; after it,
`startPos=14.90s`, `initial producer anchored at idx=3` and `seg3+`.

`play --live` without `--dvr-window` is the live-only shape, and it is the one that shows the re-anchor
gate: `AE#464: audio delay = +150 ms stands, but this session cannot re-anchor at the playhead
(state=playing, live=true); it arrives at the next seam`. With `--dvr-window 1800` the same run takes the
re-anchor and re-cuts. Before round 2 the gate read `liveWindow != nil`, which is true for both, so the
live-only session took a rebuild that rejoins at the edge.

`--reload-applying <key>=<value>` (repeatable, with one shared `--reload-applying-at <ms>`, default +20 s) corrects a `LoadOption` on the playing session through `reloadAtCurrentPosition(applying:)` (#460). Keys: `header.<Name>`, `audio-bridge`, `preferred-audio`, `decode-path`, and `is-live`, which is there to drive the refusal, since a field that names the session has to be observably refused rather than observably ignored. Both outcomes print, which is the pair a host's recovery ladder has to tell apart. Pair it with a header-logging origin to read the correction from the other end: with `--header "X-Auth: stale"` at load and `--reload-applying header.X-Auth=fresh`, the origin log shows three requests carrying the stale value, then three carrying the fresh one, and the transport telemetry carries straight through the rebuild (`resumed at 10.90s from 9.90s`).

`play --sw` sets `LoadOptions.preferredDecodePath = .software` (#461), the shipping per-session lever, rather than the process-global `setForceSoftwarePathForTesting` it drove before; that hook is still what `live --sw` and `dvr` use, since those harnesses run several sessions and want every one of them on the software host. `--reload-applying decode-path=software` is the same lever applied to a session that is already playing: on the 300 s H.264 fixture the run dispatches `codec=27 → native`, takes the correction at t=9.90 s and comes back `codec=27 → software` at 10.81 s, playing. On a live load the override reaches the same routing decision, which is the case with no alternative, since the #2 capability gate is VOD-only and a live session is never classified at all.

`--drop-audio` forces every audio pipeline to fail, so the AE#462 video-only drop is observable without a source this build has no decoder for: the loopback cascade skips both the stream-copy probe and the bridge, and `SoftwarePlaybackHost` refuses its decoder open. The run then prints `audio delivery=droppedNoPipeline pipeline=none`, which is the pair a host reads (the typed fact plus the human label), against `delivery=streamCopy` / `bridged` / `decoded` on the same source without the flag. It is loud in the log on purpose, in both the CLI line and the engine's own, because a forced classification read as a real one would be worse than no harness.

`--frame-times` installs the #311 software frame-time observer BEFORE `load()` (the documented usage: the engine re-arms each new host with it) and reads `softwarePresentationTimebase`. Per tick it appends `ft` (frames reported since the last tick), `ftLast` (newest reported presentation time), `ftGen` (renderer flush generation, which a seek moves) and `ooo`, the count of reports that arrived out of presentation order. `ooo` is the API's own claim under test: these are reported past the reorder buffer, so it must stay 0. `tb` is the timebase read at the same instant, and its closeness to `ftLast` is the point, both are on the source axis with nothing to convert between them.

`--sequential-origin` declares `LoadOptions.sequentialOrigin`, the IPTV timeshift / catch-up shape whose `206` answers are fabricated (#346): one long-lived unranged GET, no ranged probes, no tail read, so **seeking is unavailable** in the run. On VOD it needs `--declared-duration S`, which fills `LoadOptions.declaredDurationSeconds`, because the estimate that the tail read would have produced is gone with the tail read.

`--picture-probe` attaches an `AVPlayerItemVideoOutput` to the running item and decodes the source
time out of the picture itself, which is the one axis question nothing else here can answer: every
other observable (`#260` frame times, `prodShift` / `hostShift`) describes what the engine WROTE, not
where AVPlayer then PUT it. Per tick it appends `pic` (source seconds decoded from the frame),
`picItem` (AVPlayer's own `itemTimeForDisplay` for that frame), `axisErr` (their difference, 0 on an
honest axis), `capErr` (the same error as a host placing a cue at `sourceTime` would make it) and
`capFr`, that same error in frames.

The two errors do NOT have the same resolution, which is why `capFr` is printed. `axisErr`
differences two frame-grid values read out of one `copyPixelBuffer` call, so it is a whole number of
frames and every digit of it is a reading. `capErr` differences that same grid value against the
engine's continuous clock, so below one frame it carries the sub-frame phase of the sampling instant:
`capFr=+0.40` is the same frame, `capFr=+1.80` is not. Two runs whose `capErr` differs by less than a
frame have not been shown to differ.
Needs a fixture whose picture states its own frame number, which `Scripts/timecode-fixture.sh`
writes; against anything else it prints `pic=none` or nonsense. `pic=none` is also the normal read
before the first frame and during a stall, so it is not reported as a zero. This is what settled
AE#418: AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it
carries, and then plays continuously from there, so a gate that opened below its boundary shifts the
whole run by the re-aim (`axisErr=-13.583` on a 13.583 s re-aim, constant for the run).

Round 3 added a second oracle, and this one works on a device with no capture card:
`AVPlayerItem.loadedTimeRanges`. The range holding the playhead begins where AVPlayer PLACED that
run, so `advertised - rangeStart` is the axis it composed onto, measured rather than assumed. The
engine reads it after every VOD seam and says what it found, `#418 segN placement confirmed` or
`#418 segN placed on base Xs, not Ys`, the second of which is a placement this side counted that
AVPlayer discarded (a fetch during a seek burst, which is a fetch and not a placement). Against the
picture probe the two oracles agree exactly: a resume predicting a seam at `52.000` reads
`loaded [52.000-64.958]`, and a far seek predicting `21.000` reads `[21.000-38.622]`.

**Round 4 lets that reading WIN.** Round 3 collapsed the measured base onto the nearest axis the
session had already published, which made the prediction the yardstick for the measurement meant to
check it: a base matching no prediction was refused (a reporter's session composed to `-26.152` while
two readings 400 s of media apart both said `-10.93`, and ended 42.6 s out), and a base a frame or
two off was called a confirmation, so that difference stayed in the axis and the next placement
composed on top of it. What decides now is where the reading came from: a run that overlaps nothing
the item held when the placement was recorded, or one that opened ABOVE it. A start that walked
DOWNWARD is the same run backfilling, which AVPlayer does after a run opens, and is never read. The
new lines are `#418 segN placement confirmed` (residual under a millisecond), `#418 segN placed on
base Xs, not Ys (... residual Zs)`, `#418 segN opened no run of its own to measure`, and
`#418 segN superseded before it was measured`.

Round 4 also needs a fixture with B-FRAMES, and `Scripts/timecode-fixture.sh` now writes one
(`tc-bframes.mkv`). `-preset ultrafast` disables them, so on `tc-drought.mkv` a segment's dts and pts
are one number and the gate's offset is the same either way. On real content they are not: the gate
opens on a random-access point in DECODE order, and taking the offset there put the axis
`video_delay` frames under the truth on every epoch. The pair isolates exactly that. Read the verdict per axis in
`capFr`, whole frames: a single tick carries up to two frames of the probe's own quantisation. A mean
of `|capErr|` over ticks does NOT buy resolution below that quantum, it averages the sampling phase
(AE#418 round 11).

**Round 8: how far a placement sits below its axis is MEASURED, in seconds.** Rounds 5, 6 and 7 read
that distance as a multiple of the epoch's presentation lead: round 5 shipped the multiple as
arithmetic, round 6 measured it per source, round 7 held the median of its readings. The premise was
that the distance is a geometry of the source. It is not. `Scripts/timecode-fixture.sh` writes three
clips identical but for their reorder depth, and on the same burst arm over a throttled origin
(`Scripts/slowrange.py`, 3200 kbps + 100 ms), `--picture-probe` reading the axis off AVPlayer's own video
output, 2 runs each and every run identical:

| clip | gate lead | placement 2 sits | placement 3 sits |
|---|---|---|---|
| `tc-cues-lie.mkv` | 0.000 (no reordering) | 0.000 below its axis | **0.042 below its axis** |
| `tc-bf1-cues-lie.mkv` | 0.042 (one frame) | 0.000 | 0.083 |
| `tc-bf-cues-lie.mkv` | 0.083 (two frames) | 0.083 | 0.125 |

The bold cell is what retires the model: that clip has `has_b_frames=0`, every gate opens with
`lead=0`, and its third placement still sits a frame below its axis. A quantity that is nonzero where
the lead is exactly zero is not a multiple of the lead, and no coefficient can express it. The middle
row retires the source-law premise separately: one source, two placements, 0.000 then 0.083.

So the session carries the distance in the units it corrects, reads it off the same placement reading
that already measures the base, and every reading teaches it, a confirmation included. That is also
what fixes the starvation round 7 shipped: only a placement carrying a lead could teach, and on a
source without reordering, or on any session whose placements are AE#412 re-cuts (worth 0 and lead 0
by construction), there is never one. Measured on `tc-wide-cues-lie.mkv`, 13 of 13 placements across
two runs carried `lead 0.000s`, so the parameter could not move at all.

Each `placed` line names what it composed with (`sitting 0.083s below its axis`), and a reading that
moves it says so: `#418 segN sat Xs below the axis it composed on, not Ys; the next composition
starts there`. An item's FIRST placement is no longer a case of its own: with nothing measured yet
the distance is zero, which is what AVPlayer does there (measured base 0.000 on every arm of every
fixture). The gate-open line still prints `lead=`, now purely as a source fact.

Round 9 puts the lesson on the reading's own line, because round 8 printed only the MOVES and two
different things were silent under that. Every verdict line now ends in one of three clauses: `taught
the distance Xs` (an own-run reading that moved it, with the `sat` line under it), `taught the
standing distance Xs again` (an own-run reading that agreed with it), or `taught nothing, read off a
rebuilt timeline; the distance stays Xs`. The third is the one worth having: a rebuilt-timeline
reading corrects the axis like any other, by 28.000 s on `tc-wide-cues-lie.mkv`, and round 7 refuses
it the parameter on purpose, so its correction line was otherwise indistinguishable from one that had
just taught a 28 s lesson.

AE#481 is the case those ten rounds could not see, because a seek burst heals it inside a second. The
axis belongs to the RUN a re-aimed segment opened, not to the timeline from its advertised start on:
run the same chain with the re-anchoring seek LAST (`--seek-count 5 --seek-pattern 65,60,70,58,75`,
served through `Scripts/slowrange.py` at 600 kbps / 300 ms) and the picture reads `pic - picItem` of
-9.000 at item 53.000 and 0.000 everywhere the landing goes, while the session keeps mapping with
-9.000 and `capErr` sits at +9.017 to the end of the run. A seek landing now reads what its run
carries, and says so: `#481 the run holding the landing at item Xs opens at Ys, which is segN's own
playlist position, so it carries Zs and not the Ws this session was mapping with`. The discriminator
is that opening, asked of ONE segment: the first the local server answered after the seek, which is the
one whose content opens that run. It goes into a timeline carrying an axis at the seam that axis
predicts and into a timeline carrying nothing at its own position, which is round 7's pair of
admissible answers. Asked of the whole plan the same rule publishes on a coincidence (31 boundaries
over 120 s against a half-second tolerance: measured, a 0.000 axis written into a timeline carrying
-27.875 s). Measured on the arm above, `capErr` goes from +9.037 to +0.037, which is 216 frames and the
only unambiguous number in the set, while the 24-seek arms it must not touch are unchanged (10
placements, axis -34.376, no reading fired in 2 of 2 runs). On the two slow arms the `capErr` tail
moves onto the same one-frame lattice pair the fast arm sits on (`+0.009` / `-0.033`). That is a
sub-frame move and carries no accuracy claim in either direction: an earlier revision of this
paragraph read it as an improvement from 0.0230 and 0.0411 to 0.0162, which is the mistake AE#418
round 11 documents on both sides of that thread.

`--start-position S` starts at a resume anchor, the same one `serve` takes. `--sw` forces the software path for a source that would route native, which is how a native-only fixture exercises the SW pipeline.

`--malloc-census` turns on the large-allocation census (`AetherEngine.setLargeAllocationCensusEnabled`) for the run, for tracing a footprint that grows where the segment budget says it should not. Besides the 30 s sample it arms a jump trigger, which exists because the 30 s memprobe cannot catch a failure that completes inside one sample (every kill on #220 was that shape): a counter polled at `--census-hz N` runs the zone walk once it climbs `--census-threshold-mb N` above its running high-water. Both flags are inert without `--malloc-census`.

`--audio-stats` installs the engine audio tap and watches the decoded PCM itself: an `AGAP` line for every source-PTS discontinuity > 2 ms between consecutive buffers, and per-second `alead` (last decoded audio PTS minus the synchronizer clock) plus `abufs` (buffers delivered) appended to the telemetry. `alead` is the audio renderer's safety margin: on the SW live path the look-ahead pump holds it near `AudioLookaheadPolicy.targetLeadSeconds`; a collapse toward zero means the source or the feeder cannot keep real time (this is how the #107 audio-chopping report was diagnosed).

## segverify

Fetches `init.mp4` and then each media segment in turn from the loopback server and SW-decodes each segment **in isolation** (a fresh decoder per segment, no carried reference frames), reporting how many are independently decodable. A segment that yields `framesDecoded == 0` is not self-contained: its first sample is not an IRAP, so it depends on a predecessor, which is the open-GOP / B-frame boundary defect (#92). `--from N` / `--count K` bound the range (default 0 / 12), `--no-dv` forces the SDR route, `--dump <dir>` writes each fetched segment for offline inspection. Exit 0 when every tested segment is independent, 2 when any is not. This is the ground-truth verifier the #92 fix was validated against (ffmpeg's `hls` muxer scores every segment independent).

## dovitest

Runs the Dolby Vision Profile 7 to 8.1 converter over every video packet of the source and writes the converted elementary stream (Annex B) to `/tmp/aetherctl-dovitest.hevc`, reporting packets processed, conversions, and failures. Lets you confirm the in-engine `DoviRpuConverter` (libdovi) output matches the `dovi_tool -m 2` ground truth offline, without a DV panel:

```bash
swift run aetherctl dovitest <p7-source>
dovi_tool extract-rpu -i /tmp/aetherctl-dovitest.hevc -o out.rpu
dovi_tool info -i out.rpu -f 0   # expect dovi_profile 8, disable_residual_flag true
```

## pktdump

Opens the demuxer under a selectable open profile, optionally seeks, and dumps raw video packet timing exactly as the demuxer delivers it (before any producer-side dts repair and before muxing): per-packet dts / pts / duration / keyframe flag samples, NOPTS and non-monotonic dts counts, and dts-delta / duration histograms. Also prints the resolved stream fields that `find_stream_info` fills (`avg_frame_rate`, `codecpar.video_delay`).

```bash
swift run aetherctl pktdump --at 660 --count 300 --profile playback        <url>
swift run aetherctl pktdump --at 660 --count 300 --profile restartReopen   <url>
swift run aetherctl pktdump --at 660 --count 300 --profile stillExtraction <url>
```

`--profile` defaults to `playback`; `stillExtraction` is the third open profile, the one the `FrameExtractor` uses (a short-range AVIO with its own thread count), for comparing what a still-extraction open resolves against what playback resolves.

The profile differential is the diagnostic: a `video_delay=0` plus NOPTS or non-monotonic dts under one profile while the other is clean means that profile's open path cannot reconstruct decode-order dts for B-frame content (the #93 post-recovery judder root cause). Backed by the public `PacketTimingProbe.run(url:seekSeconds:packetCount:profileName:)`.

## extract

Opens a `FrameExtractor` against the source and pulls a still frame. Thumbnail mode (default) snaps to the nearest keyframe and downscales to `--width` (default 320); `--snapshot` decodes frame-accurately at full resolution. `--at <sec>` sets the seek position (default 60.0). The first frame is written to `/tmp/aetherctl-extract-<mode>.png`. `--loops N` repeats the extraction across eight cycling positions, which pairs with `leaks --atExit` to validate the decode-context teardown is clean:

```bash
swift run aetherctl extract --at 612 --snapshot <url>          # frame-accurate still
swift run aetherctl extract --width 480 <url>                  # keyframe thumbnail
leaks --atExit -- .build/debug/aetherctl extract --loops 8 <url>   # leak sweep
```

## audio

Plays a source through the audio-only pipeline (default ten seconds, `--seconds N` to override) and reports which host took it (bare AVPlayer vs the FFmpeg renderer path), exercising the same dispatch a music host sees.

## audiotap

    aetherctl audiotap [--duration S] [--out PATH.wav] [--remote | --software] <url>

Brings up the loopback session headless, decodes the audio tap (#95) as fast as segments are produced, writes mono Float32 48 kHz WAV (default `/tmp/audiotap.wav`), and prints buffer count, PCM seconds, discontinuity count, and the covered `sourceTime` span. A clean run reports exactly one discontinuity (the install itself). `--remote` drives the remote-HLS delivery path instead (direct AVPlayer ingest of an HLS url, no loopback): rendition/variant resolution, segment fetch + decrypt, playhead-follow decode. Verification tool for the PCM audio tap across the stream-copy and bridge audio paths.

`--software` drives the third delivery path, the SW sink (`AudioTapPCMConverter`), which the other two modes cannot reach: they drive their readers directly, while the sink only exists inside a real session. This mode therefore loads the source through the whole engine, fails if it did not route to the software host, installs the tap through the public `installAudioTap()` and plays, so the sink runs exactly as it does in a host. It is bound to wall clock (the SW host decodes in real time), and it reports `peak` next to the buffer count because the two ways this path fails look identical in a report otherwise: **exit 3 covers both no buffers at all and buffers of digital silence**, which at a consumer is indistinguishable from a muted source. That gap is not hypothetical. With no harness here, a force unwrap that trapped on the FIRST buffer of any multichannel track shipped in 6.1.3 and survived to main (#400), and the silent-downmix defect underneath it only became visible once the trap was gone. Software routing needs a source the native path declines, e.g. `ffmpeg -f lavfi -i testsrc2 -f lavfi -i sine -c:v libvpx-vp9 -c:a aac -shortest clip.mkv`; add `-af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0"` for the multichannel case and `-af "pan=quad|c0=c0|c1=c0|c2=c0|c3=c0"` for the layout AVAudioConverter refuses to mix.

## bgaudio

Verifies SW-path background audio (iOS keepalive) headless on macOS, where the `UIApplication` background lifecycle that normally drives it does not exist. Loads a software-routed source through the full engine, plays a foreground baseline, toggles the SW host into background-audio-only (`--fg N` foreground seconds, `--bg N` background seconds; defaults 3 / 6), then returns to foreground. Reports per-tick the audio clock, the SW video-frame count, and the process memory footprint, and a verdict. A healthy run shows the clock advancing through the background phase (audio alive), the video-frame count flat (video dropped), the footprint roughly flat (the loop paces on the audio renderer rather than buffering the rest of the file), and the video-frame count rising again on foreground return (resync at the next keyframe). The flag and counters are exposed through DEBUG-only engine hooks, so this command is unavailable in a Release build. Generate a quick software-path clip with `ffmpeg -f lavfi -i testsrc2 -f lavfi -i sine -c:v libvpx-vp9 -c:a aac -shortest clip.mkv`.

## customio

Wraps a local file in a custom `IOReader` and plays it through `load(source:)`. `--memory` reads via `DataIOReader`, `--forward-only` drops the seek capability, `--audio-only` routes through the audio-only pipeline, and `--reload` / `--switch-audio` / `--select-subs` / `--extract` exercise the optional capabilities (background reload, audio-track switch, embedded subtitles, scrub preview) end-to-end. `--audio-index N` names the audio stream at LOAD and prints what it asked for next to what it got. Pair it with `--forward-only` for the one question a live host has to answer: `selectAudioTrack` refuses such a source (rebuilding a drained FIFO), so naming the stream at load is the only way onto another track, and this is where that was measured rather than assumed (Sodalite#64).

### `--live`: a host-owned live spool, and the memory it costs (AE#445)

`customio --live <file.ts>` puts the same file behind a reader shaped like a live host's: paced at
`--rate-kbps` (default 8000) against the wall clock, blocking at the edge instead of ever returning
EOF, answering `AVSEEK_SIZE` negative, and seekable by logical offset. `--seconds N` sets the run
length (default 720), `--dvr-window N` the timeshift, `--report-size` makes the size known, and
`--no-wrap` stops it looping the file. Every ten seconds it prints `physFP` and its slope, and it
closes with that slope stated against the source's own mux rate:

```
VERDICT: physFP 105 -> 402 MB over 240s = 1.24 MB/s (source mux rate 0.95 MB/s, retention ratio 1.30)
```

A ratio near 1 means the session keeps one byte for every byte it plays, which on a source that never
EOFs is unbounded by construction; near 0 means the footprint is the session's, not the stream's. That
is the whole measurement, and before AE#445 the custom-source live shape had no harness at all: the
defect it found (host reader callbacks ran on the pump's undrained thread) was reachable by every
custom reader and visible to none of the engine's own buckets.

**Which reader arm is running decides what the ratio is about.** The default arm reads with `pread`
straight into the engine's buffer and allocates nothing, so whatever it retains is the ENGINE's.
`--foundation-reader` swaps in a `FileHandle.readData` arm, which strands one autoreleased `Data`
per read on any thread that never drains a pool, so what it retains is the HOST's.

That distinction was learned the expensive way. AE#445 round 1 shipped only the Foundation arm and
measured ratio 1.00 before the bridge pool and 0.00 after, which reads like the reporter's defect
reproduced and fixed. It was not: his adapter `pread`s and allocates nothing, so the run had
reproduced the harness's own retention with his signature. A harness that brings the cause with it
matches the shape and answers a different question, and only a second arm that allocates nothing can
tell those two apart. Run both: the Foundation arm is now the control that proves the pool drains,
and the POSIX arm is the one that measures the engine.

**`--reload-at S` rebuilds the live session in place S seconds in, and `--cancel-latches` is the
reader that reads `cancel()` as terminal.** The correction it applies (`httpHeaders`) is inert on a
custom source on purpose: what the arm measures is the REBUILD, not the field. It reports the
playhead and the reader's cursor on both sides of it, and the closing `LOOKBACK` line states how far
back the rebuild reached:

```
  RELOAD at t=60s: playhead=41.52s cursor=15.0MB edge=15.0MB
  RELOAD done: playhead 41.52s -> 0.00s, reader cursor 15.0 -> 15.8 MB, edge 15.0 -> 15.8 MB
LOOKBACK: 7 seeks, deepest reach-back 0.0 MB behind the live edge (0 s of source at this rate)
```

A reach-back of 0 MB is the rebuild rejoining at the edge. Before the AE#460 follow-up the same run
reported 15.0 MB (61 s of source) and a playhead of 1.90 s: the reopen rewound the host's spool to
its base and re-read the whole delivered window. `--cancel-latches` is the other arm, and it is a
control rather than a defect: a reader that treats `cancel()` as terminal cannot serve the rebuild
that reuses it, so the reopen dies on stream info and the correction throws.

**`--reload-decode-path automatic|software` makes the correction the decode path itself** (AE#461
follow-up), on `customio` with `--reload` and on `customio --live` with `--reload-at`. The header
probe those arms apply by default is inert on a custom source on purpose, so it measures the rebuild
and can never measure this field; the field is what a host actually corrects. Both arms print the
backend on each side of the rebuild, which is the whole observable:

```
  RELOAD applying preferredDecodePath=software: playhead=0.00s backend=native
[AetherEngine] #461: reload re-routing this session native -> software on the host's preference (custom source: true)
  RELOAD done: playhead 0.00s -> 0.33s, backend native -> software, decoder=libavcodec H264 (SW)
```

Before the follow-up the same run logged `#460: reload applying preferredDecodePath` and then
`backend native -> native, decoder=VideoToolbox H264 (HW)`: accepted, named in the log, ignored.

On a source the software path cannot represent the arm measures the OTHER half, that a refusal costs
nothing, by reporting the state the refusal left behind rather than exiting on the throw. The Dolby
browser test kit is the fixture, because it carries its own control:

```
# Profile 5 (IPT-only): refused, and the session is untouched
  REFUSED state=playing backend=native playhead=0.00s (was 0.00s) decoder=VideoToolbox HEVC (HW)
VERDICT: correction refused, session untouched and still playing
# Profile 8.1, same material and grading: honoured
  RELOAD done: playhead 0.00s -> 0.26s, backend native -> software, decoder=libavcodec HEVC (SW)
```

**Read the live arm's retention ratio over a long run, not a short one.** The slope anchors at 60 s
to skip the load step, which is exactly where `--reload-at 60` puts a SECOND step: the software
pipeline's own baseline. A 100 s run reads ratio 1.31 and means nothing by it; a 260 s run shows
`physFP` stepping 25 to 66 MB across the switch and then flat at 67 for 140 s, ratio 0.18 and still
falling, which is a step being amortized rather than a session retaining anything.

**`--host-carry removeFirst|subdata` is the third arm, and it names a cause rather than measuring
the engine.** Round 3's census on the reporter's device pinned his footprint to ONE `REALLOC`-tagged
block growing on an exact x1.25 ladder, holding every byte the session had consumed. That factor is
Foundation's: `Data` grows a large buffer by `newLength >> 2`, where `av_fast_realloc` adds a
sixteenth and FFmpeg's AVIO dynamic buffer a half, so the block is a Swift `Data`. The one `Data`
shape that grows like that while its `count` stays tiny is a parse carry consumed from the front
with `removeFirst`, which only advances the slice's lower bound and leaves the backing store holding
everything below it. `--host-carry removeFirst` puts exactly that carry on the harness's delivery
path, so the tool that measures the engine at ratio 0.00 can also produce ratio 1.00 on demand;
`--host-carry subdata` is the same carry re-based, i.e. the fix. Both arms print the tell every ten
seconds:

```
  t=240s ... physFP=447MB srcMB=417.2 growthMBps=1.67 carryCount=112B carryStart=417.1MB
```

A carry whose `count` is under one TS packet while its slice's lower bound tracks the consumed
stream is riding a backing allocation that large. `startIndex` is the cheapest probe there is for
this defect, in any host, without Instruments.

## disc-inspect

Walks a local DVD-Video or Blu-ray ISO at the filesystem layer (FFmpeg-free) and reports what `DiscReader.wrap` makes of it: the recognition verdict and the stages it went through (ISO9660 / UDF signatures, BDMV / VIDEO_TS contents, resolved extents), so a disc that fails to play is debuggable instead of surfacing a bare `INVALIDDATA`. It also prints the full selectable-title list with each title's duration and chapter offsets (the same titles + chapters the engine exposes via `discTitles` / `discChapters`). Exit 0 when the image is recognized as playable, else 1. `--dump` adds the verbose UDF volume structure under the `.demux` log.

## dualsubs

Activates two subtitle tracks simultaneously on one source (primary + secondary) and prints both cue lists, exercising the dual / bilingual subtitle path. `--primary <streamIndex> --secondary <streamIndex>` select the tracks; `--seek <seconds>` jumps first so you can confirm both channels re-resolve after a seek.

## live

Runs a live MPEG-TS session against a built-in fixture that serves an endless broadcast by looping a seed `.ts` with rewritten timestamps. Flags simulate the failure modes the live path hardens against: `--drop-after N` (mid-stream connection drop + reconnect), `--discontinuity-at N` (program-boundary PTS / PCR jump), `--realtime` (1x wall-clock pacing), `--preroll N` (backlog seconds the paced fixture bursts before 1x pacing; default 30, `0` models a strict-realtime origin with no backlog), `--fast-zap` (loads with `LoadOptions.liveJoinProfile = .fastZap`; the first serve prefers the full holdback but is bounded after two finalized segments plus a 0.5...2.0 s observed-segment grace), `--dvr-window N` (timeshift), `--measure-rss` (sliding-window retention), `--reload-test` (live rejoin end to end, including the full-backlog replay shape some origins serve on reconnect). `--seed <ts>` overrides the seed clip, `--sw` forces the software live path, `--report-cache-bytes` tracks on-disk DVR footprint, `--serve-only` parks the fixture without attaching an engine (raw `curl` / `ffprobe` inspection), `--rewind-test` runs the DVR rewind-and-return matrix variant, `--rewind-hold N` parks the playhead N seconds behind the edge and HOLDS it there for the rest of the run (the regime that separates a resident floor doing its job from a window outrunning the reader: it reports the floor-minus-playhead inversion, stalled ticks, and any `live window slid past the consumer` line), `--freeze-after N` freezes the upstream with the connection still open, `--rewind-before-freeze N` parks the playhead inside the DVR window first, `--unfreeze-after N` lets the frozen upstream deliver again after N seconds (the only way to drive the recovery half: a window closed with ENDLIST re-opening, and where the rejoin puts a timeshifted viewer), `--live-only` loads with no DVR window at all (the shape of a client that keeps its rewind outside the engine, which is where AE#446 round 4 came from: the freeze leg then measures the only timeshift such a session can have, the backlog an outage puts between the closed window's end and the source's return, and the sliding 60 s live-only retention makes the fresh item's own axis observable), `--force-recovery-reload-at N` drives the stage-2 recovery reload without waiting for a real item death, and `--gen-highbitrate-seed` generates a ~22 Mbps 1080p H.264 MPEG-TS seed (for RSS-retention measurement) then exits. `--sliding` is still accepted and does nothing: the sliding window is unconditional for live sessions now, and the flag stays only so an older script does not fail on it.

The freeze leg's verdict is stated in SEGMENTS, not in seconds. A forward step in seconds cannot tell a lost position from a source discontinuity the session correctly folded: a client that reconnects during the freeze is served from a fresh loop of the seed, and since a connection always starts at a loop boundary the remainder of the loop the parked connection had not reached is skipped, which is a real jump in the source (28.8 s on the bundled seed, 49.1 s reported on a 93 s capture) and shows up as a legitimate step in the playhead. What the verdict reads instead is which segments the consumer fetched before and after the rejoin: any the window listed, that it had not reached, and that the rejoin then jumped over. It also fails a rejoin that re-enters further below the place it held than the landing's own backward buffering explains (a re-fetch is not a re-watch, and the allowance is computed from the cut size because AVPlayer's lookback is a fixed 6 to 8 s of content), and a run where the source delivered again and the session never went live at all, which every seconds-based number reads as healthy (the playhead had not moved, so it had not moved wrong).

## dvr

Runs the rewind matrix across the native and SW paths (`--path native|sw|both`). `--seconds N` and `--dvr-window N` size the run.

## hlsfixture

Slices a local `.ts` into a sliding live HLS playlist and serves it over loopback, with fault knobs (`--master` indirection, `--codecs`, `--resolution`, `--discontinuity-at`, `--slow-refresh`, `--drop-segment`, `--encrypted`, `--fmp4`, `--port`, `--segment-seconds`, `--target-duration`, `--window`) and a `--self-test` mode that runs `HLSLiveIngestReader` against it end to end. Every request is logged as one `[HLSFixture] REQ <path>` line, so what a load actually costs the origin is countable rather than arguable.

`--segments-dir <dir>` serves pre-cut segments (`ffmpeg -i in.ts -c copy -f hls -hls_time 4 -hls_flags independent_segments -hls_segment_filename seg%d.ts out.m3u8`) instead of byte slices, sorted numerically. Byte slices start mid-GOP, which is fine for "did it route" and useless for "did it play": the run rebuffers forever because nothing decodes. Use the directory whenever the question is playthrough.

### The advertised TARGETDURATION and the window depth (AE#374)

`--target-duration N` advertises a `#EXT-X-TARGETDURATION` independent of the real cut size, and `--window N` sets how many segments the sliding window keeps visible (default 6, minimum 3). Packagers commonly pad the target duration (`segment + 1`) to widen a client's patience for an unchanged playlist, and a downstream host asked whether that padding was what its live joins were paying for. Neither shape could be expressed here, so the question could not be answered by measurement at all.

Measured against pre-cut GOP-aligned segments, `play --live --fast-zap` entered on a saturated window, three passes per row, engine 6.34.1:

| origin cut | advertised TD | window | served TD | first serve held |
|---|---|---|---|---|
| 2 s | 3 (padded) | 3 | 3 | 2.004 / 2.010 / 2.010 s |
| 2 s | 2 (`ceil(max EXTINF)`) | 3 | **3** | 2.010 s, three times |
| 2 s | 3 | 5 | 3 | 2.001 / 2.007 / 2.010 s |
| 2 s | 5 (over-padded) | 3 | **5** | 2.010 s, three times |
| 1 s | 2 (padded) | 3 | 2 | 1.001 / 1.010 / 1.010 s |
| 1 s | 1 (`ceil(max EXTINF)`) | 3 | **2** | 1.005 / 1.007 / 1.010 s |
| 1 s | 2 | 7 | 2 | 1.003 / 1.005 / 1.010 s |
| 0.5 s GOP inside 1 s segments | 2 | 3 | 2 | **0.510 s, three times** |

Removing the padding changed nothing **at 6.34.1**, and that finding is what AE#447 later turned out to be. The served TARGETDURATION was `max(advertised, ceil(observed arrival cadence), ceil(max own EXTINF), ceil(1.5 x cut target))`, and a strict-realtime origin's real inter-arrival gap is always a hair above the nominal cut, so the `ceil` landed on `cut + 1` whether or not the origin advertised it. Reading that as "the padding is not what you pay for" was right; reading it as "there is nothing to pay" was not. Both terms were wrong for the same reason: an arrival interval is a cadence, and `ceil` treats it as a segment duration.

From **6.56.0** the advertised value is not read at all (it is printed in the seal line and nowhere else), and a measured cadence enters as the TARGETDURATION its patience actually needs, `ceil(gap / 1.5)`, because `1.5 x TD` is the unchanged-playlist tolerance the floor exists to satisfy. On the same 2 s origin advertising 3, measured on this harness: served TD **3, then 4, then 4** across three joins before, holdback 9 s then 12 s twice, escalating because the gate's own wait was being measured as the source's cadence; served TD **2** on every join after, holdback 6 s, measured floor 2.019 to 2.141 s. Deepening the window changes nothing either: the ingest joins exactly three segments behind the edge at window 3, 5 and 7, so a deeper upstream window never becomes a deeper cushion. What moves is the cut, because the fastZap grace is `min(2.0, max(0.5, own cut duration))` and the engine re-cuts at the source GOP.

Over-padding costs somewhere else than the join. TD 5 on 2 s cuts still serves in 2.010 s, because the bounded fastZap exit fires on the grace either way, but the served playlist then carries a 15 s holdback, so AVPlayer targets that far behind the live edge for the rest of the session. Since 6.56.0 an over-padded advert cannot produce that at all: only the source's own segments and its closed inter-arrival gaps can.

The seal line is where the whole derivation is now readable, once per session:

```
[HLSVideoEngine] live TARGETDURATION sealed at 2s (holdback 6.000s): max EXTINF 2.000s,
  1.5 x cut target 0.750s, measured floor 2.069s needs 2s of patience;
  upstream advertises 3.000s (reported, not used)
```

**And this harness cannot reproduce the last term of it (AE#447 round 2).** After the four fixes above, the reporter's device still sealed at 3 while that same line printed `max EXTINF 2.000s`. A live EXTINF is `nextStart - startSeconds`, a difference of two accumulated item-axis doubles, so a strictly 2.000 s GOP whose first segment starts at 0.060 s yields the odd `2.0000000000000004`; `ceil` charges a whole second for it, and the seal takes the max over the window, so one such segment is enough (6 of his 80 were). The fixture here starts its first segment at exactly 0 and cuts at a binary-exact duration, so its differences are exactly 2.0 and five joins in a row sealed at 2. The case lives in `Issue447TargetDurationEvidenceTests` instead, built by accumulating the way the producer accumulates. Since **6.56.0** every term is taken at the resolution the playlist serves (`#EXTINF` is written with `%.3f`), so the seal line can be checked against itself: what it prints is what decided it.

### The header-enforcing origin (AE#363)

A tokenized IPTV origin refuses anything that arrives without its per-request header, which is a shape none of the fixtures could produce, so neither live client could be driven against one:

```bash
# portal on 8099 answers /entry.m3u8 with a 302 to the "CDN edge" on 8100, both enforcing the header
aetherctl hlsfixture --segments-dir ./segs --master --codecs "avc1.4d401f,mp4a.40.2" \
  --resolution 1280x720 --require-header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --redirect-entry --redirect-port 8100 --port 8099
aetherctl play --live --header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --seconds 60 http://127.0.0.1:8099/entry.m3u8
```

The REQ log then carries the verdict per request (`auth=ok` / `auth=MISSING -> 403`), which is what makes "who lost the header, and on which hop" a measurement. Knobs: `--require-header "Name: Value"`, `--deny-status N` (401 and 403 reach the engine as different `NSURLError` codes), `--deny-segments-only` (refuse after readyToPlay rather than at the master), `--deny-user-agent S` (refuse `AppleCoreMedia` and serve everyone else, the one origin shape that tells the AVPlayer bypass and the engine's own ingest fetcher apart), `--redirect-entry` / `--redirect-host` / `--redirect-port` (portal-to-edge 302, cross-origin by host name and port while staying on loopback), `--media-origin H:P` (master's variants point at a second origin absolutely).

Measured with it before AE#363 was written, and worth knowing before suspecting the engine: `LoadOptions.httpHeaders` survive BOTH shapes on the AVPlayer bypass on macOS, the cross-origin 302 and the absolutely referenced second origin. Every request arrived with the header and the session played through.

`--codecs` / `--resolution` write `CODECS=` / `RESOLUTION=` onto both `EXT-X-STREAM-INF` lines. Without them AVFoundation reports no `videoAttributes` for the variants, so everything that reads master evidence (the #168 watchdog, the #293 probe gate) sees a master advertising no video at all and the fixture quietly stops carrying the case under test.

Note that the slicing is byte-based, not keyframe-aligned, so segments start mid-GOP and the decoder logs parameter-set errors on the rerouted ingest. That is fine for routing and plumbing questions; for a run that has to *play*, produce real segments with `ffmpeg -f hls` and serve those instead.

## seektest

Drives a real AVPlayer (native loopback-HLS path) through a burst of rapid seeks and reports the producer-restart coalescing behavior, the longest "wedge" (state `.playing` but the clock frozen), and final settle accuracy (AetherEngine#35). A concurrent sampler probe also checks the seek clock-bounce / `isSeeking` signal (AetherEngine#37 / #38): a single backward seek must not bounce the clock back through the pre-seek position, and `isSeeking` must span the real landing. The run ends with a `#38 SEEK EVENT LEDGER`: every `.began` must reach a terminal event (an unpaired one is a stranded in-flight window), and `.stalled` seeks are listed with any late `.landed` that followed them. `--seeks N`, `--gap-ms N`, `--settle N` shape the burst; needs `> 30 s` of seekable VOD. `--throttle-kbps N` caps source-IO delivery to simulate a slow CDN and force rebuffers during the burst (see `serve`).

## hlslive

Replays a synthetic SSAI ad-pod feed through the live-direct-play path to repro the FAST-channel ad-break handling (program-switch detection, muxer rotation with versioned `#EXT-X-MAP`, audio re-anchor, no-cut watchdog). `--segments a.ts,b.ts,c.ts` is required: a comma-separated list of real `.ts` segment files served in order (content / ad / content) without timestamp rewriting. `--seconds N` (default 40) and `--segment-seconds N` (default 5) size the run; `--disc i,j` marks which segment indices carry a leading `#EXT-X-DISCONTINUITY` (default: auto-detected on every file change).

## smbtest

Connects to an SMB2/3 share with `SMBConnection` (SMBClient backend), wraps the file in `SMBIOReader`, and runs a sequential-throughput pass plus a random-seek consistency check. macOS-only; needs the optional `AetherEngineSMB` product (`swift build --product aetherctl` pulls it in). Validates the SMB byte source without a device:

```bash
swift run aetherctl smbtest "smb://user:pass@host/share/path/to/file.mkv" --reads 128
```

`--reads N` sets the random-seek count (default 64). Credentials default to guest when omitted from the URL; URL-encode special characters in the password.

## Fixtures

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR, HEVC HDR10, AV1, VP9) covering both the native AVPlayer path and the software fallback. Real-world DV / Atmos / multichannel sources go in `./Fixtures/user/` (gitignored).
