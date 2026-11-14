#!/usr/bin/env python3
"""Behavioral regression for finishSeeking(commit:): compiles the real function
extracted from DouDuo/ShortVideoPlayer.swift against stand-in seek/HUD state.
No device, account, or defaults access.

Guards the reported defect where the scrub preview HUD stayed on screen after a
seek. Cancelling a scrub must clear the HUD, drop the preview image, reset the
throttle and delta, bump the preview token and cancel in-flight image requests
without committing a seek. Ending a drag must commit the captured target
exactly once (position 0 included) and leave unrelated playback state alone.
"""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'DouDuo/ShortVideoPlayer.swift').read_text()


def extract_decl(source: str, signature: str) -> str:
    """Return the matched declaration plus its balanced `{...}` body, skipping
    strings and comments so braces inside them do not confuse the scan."""
    match = re.search(signature, source)
    assert match, f'RED: missing declaration matching {signature!r}'
    decl = match.start()
    start = source.index('{', match.end() - 1)
    depth = 0
    i = start
    while i < len(source):
        if source.startswith('//', i):
            nl = source.find('\n', i)
            i = len(source) if nl < 0 else nl + 1
            continue
        if source.startswith('/*', i):
            end = source.find('*/', i)
            assert end >= 0, 'unterminated block comment'
            i = end + 2
            continue
        ch = source[i]
        if ch == '"':
            i += 1
            while i < len(source):
                if source[i] == '\\':
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return source[decl:i + 1]
        i += 1
    raise AssertionError('unbalanced braces while extracting declaration')


SEEK_BODY = extract_decl(SOURCE, r'private func finishSeeking\(commit: Bool = false\)')

HARNESS = '''import Foundation

final class UIImage {}

/// Stand-in for AVAssetImageGenerator: only the cancellation surface that
/// finishSeeking touches is modelled.
final class AVAssetImageGenerator {
    var cancelCount = 0
    func cancelAllCGImageGeneration() { cancelCount += 1 }
}

final class Harness {
    // Scrub HUD state owned by the player.
    var seeking = false
    var previewImage: UIImage?
    var seekPreview: Double = 0
    var seekDelta: Double = 0
    var lastPreviewAt: Double = 0
    var previewGeneration: UInt = 0
    var imgGen: AVAssetImageGenerator?

    // Unrelated playback state: finishing a scrub must never touch it.
    var isPlaying = false
    var userPaused = false
    var current: Double = 0

    var seekToCalls: [Double] = []

__SEEK_BODY__

    func seekTo(_ pos: Double) { seekToCalls.append(pos) }
    func callFinish(commit: Bool = false) { finishSeeking(commit: commit) }
}

var passed = 0
var failed: [String] = []
func expect(_ condition: Bool, _ name: String) {
    if condition { passed += 1 } else { failed.append(name) }
}

/// A player mid-scrub: HUD showing a preview, throttle armed, request in flight.
func scrubbing(_ preview: Double, delta: Double, throttle: Double,
               generation: UInt = 5) -> Harness {
    let h = Harness()
    h.seeking = true
    h.previewImage = UIImage()
    h.seekPreview = preview
    h.seekDelta = delta
    h.lastPreviewAt = throttle
    h.previewGeneration = generation
    h.imgGen = AVAssetImageGenerator()
    return h
}

// 1. Cancelled scrub: HUD state, image, throttle and delta are cleared, the
//    token advances, pending requests are cancelled, and nothing is committed.
let cancelled = scrubbing(37.5, delta: 12.5, throttle: 12.3)
cancelled.isPlaying = true
cancelled.callFinish()
expect(!cancelled.seeking, "cancelled scrub still marked seeking")
expect(cancelled.previewImage == nil, "cancelled scrub left the preview image in the HUD")
expect(cancelled.seekDelta == 0, "cancelled scrub left a stale seek delta")
expect(cancelled.lastPreviewAt == 0, "cancelled scrub left the preview throttle armed")
expect(cancelled.previewGeneration == 6, "cancelled scrub did not advance the preview token")
expect(cancelled.imgGen?.cancelCount == 1, "cancelled scrub did not cancel in-flight preview requests")
expect(cancelled.seekToCalls.isEmpty, "cancelled scrub committed a seek")
expect(cancelled.isPlaying, "cancelled scrub stopped playback")

// 2. The default argument does not commit.
let defaulted = scrubbing(20, delta: 4, throttle: 2.5)
defaulted.callFinish()
expect(defaulted.seekToCalls.isEmpty, "default finishSeeking committed a seek")
expect(defaulted.previewGeneration == 6, "default finishSeeking did not advance the token")

// 3. Drag end commits the captured target once and clears the HUD, while
//    unrelated playback state survives untouched.
let committed = scrubbing(42.25, delta: 18.25, throttle: 9.5)
committed.isPlaying = true
committed.userPaused = true
committed.callFinish(commit: true)
expect(committed.seekToCalls == [42.25], "drag end did not commit the captured target exactly once")
expect(!committed.seeking, "drag end still marked seeking")
expect(committed.previewImage == nil, "drag end left the preview image in the HUD")
expect(committed.seekDelta == 0, "drag end left a stale seek delta")
expect(committed.lastPreviewAt == 0, "drag end left the preview throttle armed")
expect(committed.previewGeneration == 6, "drag end did not advance the preview token")
expect(committed.imgGen?.cancelCount == 1, "drag end did not cancel in-flight preview requests")
expect(committed.isPlaying, "drag end changed playing state")
expect(committed.userPaused, "drag end changed userPaused state")

// 4. Scrubbing back to the very start commits position 0 rather than dropping it.
let toStart = scrubbing(0, delta: -60, throttle: 4)
toStart.callFinish(commit: true)
expect(toStart.seekToCalls == [0], "seek to position 0 was not committed")

// 5. Repeated finish (gesture end plus a reset) commits once and cancels once.
let repeated = scrubbing(10, delta: 1, throttle: 3)
repeated.callFinish(commit: true)
repeated.callFinish(commit: true)
repeated.callFinish(commit: true)
expect(repeated.seekToCalls == [10], "repeated finish committed the seek more than once")
expect(repeated.previewGeneration == 6, "repeated finish advanced the preview token more than once")
expect(repeated.imgGen?.cancelCount == 1, "repeated finish cancelled preview requests more than once")

// 6. Finishing with no active scrub is a no-op: no commit, no token churn.
let idle = Harness()
idle.imgGen = AVAssetImageGenerator()
idle.previewGeneration = 3
idle.seekPreview = 80
idle.callFinish(commit: true)
expect(idle.seekToCalls.isEmpty, "finish without an active scrub committed a seek")
expect(idle.previewGeneration == 3, "finish without an active scrub advanced the preview token")
expect(idle.imgGen?.cancelCount == 0, "finish without an active scrub cancelled preview requests")

// 7. A fresh drag after a cancelled scrub still commits its own target.
let redrag = scrubbing(37.5, delta: 12.5, throttle: 12.3)
redrag.callFinish()
redrag.seeking = true
redrag.seekPreview = 55
redrag.seekDelta = 5
redrag.lastPreviewAt = 1.75
redrag.previewImage = UIImage()
redrag.callFinish(commit: true)
expect(redrag.seekToCalls == [55], "a fresh drag after cancellation could not commit its target")
expect(redrag.previewGeneration == 7, "second scrub did not advance the preview token again")
expect(redrag.imgGen?.cancelCount == 2, "second scrub did not cancel its own preview requests")
expect(redrag.previewImage == nil, "second scrub left the preview image in the HUD")

if failed.isEmpty {
    print("PASS seek preview regression: \\(passed) assertions across 7 scenarios")
} else {
    for name in failed { print("FAIL \\(name)") }
    print("FAILED \\(failed.count) of \\(passed + failed.count) assertions")
    exit(1)
}
'''

SWIFT = HARNESS.replace('__SEEK_BODY__', SEEK_BODY)

with tempfile.TemporaryDirectory(prefix='seek-preview-regression-') as d:
    p = pathlib.Path(d)
    (p / 'main.swift').write_text(SWIFT)
    subprocess.run(['swiftc', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
