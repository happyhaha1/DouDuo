#!/usr/bin/env python3
"""Behavioral regression for resumeAfterBackground(): compiles the real function
extracted from DouDuo/ShortVideoPlayer.swift against stand-in AVAudioSession /
AVPlayer / VLC / seamless-audio state. No device, account, or defaults access.
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


RESUME_BODY = extract_decl(SOURCE, r'private func resumeAfterBackground\(\)')
RESUME_POLICY = extract_decl(SOURCE, r'enum DYResumePolicy\s*\{')

HARNESS = '''import Foundation

func ddWrite(_ s: String) {}

/// Stand-in for the platform audio session: records every mutation.
enum AVAudioSessionCategory { case playback }
enum AVAudioSessionMode { case moviePlayback }
final class AVAudioSession {
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    var categoryCalls = 0
    var activeCalls: [Bool] = []
    func setCategory(_ category: AVAudioSessionCategory,
                     mode: AVAudioSessionMode = .moviePlayback) throws { categoryCalls += 1 }
    func setActive(_ active: Bool, options: Int = 0) throws { activeCalls.append(active) }
}

final class AVPlayer {
    var playCount = 0
    func play() { playCount += 1 }
}

final class HDPlayer {
    var playCount = 0
    func play() { playCount += 1 }
}

final class StubAudio { var isMuted = false }

final class StubMediaPlayer {
    var audio: StubAudio? = StubAudio()
    var playCount = 0
    var isPlaying = false
    func play() { playCount += 1; isPlaying = true }
    func pause() { isPlaying = false }
}

final class VLCPlayerController {
    let mediaPlayer = StubMediaPlayer()
}

final class DDSeamlessController {
    var playCalls: [(Float, Bool)] = []
    var syncCalls: [(Float, Bool)] = []
    func play(rate: Float, muted: Bool) { playCalls.append((rate, muted)) }
    func syncAfterForeground(rate: Float, muted: Bool) { syncCalls.append((rate, muted)) }
}

final class DDPlayback {
    static let shared = DDPlayback()
    static var bgPlay = false
    var appIsActive = true
    var coverHold = false
}

__RESUME_POLICY__

final class Harness {
    let id = "resume-regression"
    /// Captured once at onAppear and frozen afterwards: the stale value that
    /// used to be consulted for resume decisions.
    let isActive: Bool
    var pageActive: Bool
    var userPaused = false
    var pendingPosition: Double?
    var isPlaying = false
    var playRate: Float = 1
    var muted = false
    var player: AVPlayer?
    var hdPlayer: HDPlayer?
    var vlc: VLCPlayerController?
    var seamAudio = DDSeamlessController()

    init(capturedIsActive: Bool, pageActive: Bool) {
        self.isActive = capturedIsActive
        self.pageActive = pageActive
    }

__RESUME_BODY__

    func callResume() { resumeAfterBackground() }
}

var passed = 0
var failed: [String] = []
func expect(_ condition: Bool, _ name: String) {
    if condition { passed += 1 } else { failed.append(name) }
}

func fresh(capturedIsActive: Bool, pageActive: Bool,
           avPlayer: Bool = true, vlc: Bool = false) -> Harness {
    DDPlayback.shared.appIsActive = true
    DDPlayback.shared.coverHold = false
    DDPlayback.bgPlay = false
    AVAudioSession.instance.categoryCalls = 0
    AVAudioSession.instance.activeCalls = []
    let h = Harness(capturedIsActive: capturedIsActive, pageActive: pageActive)
    if avPlayer { h.player = AVPlayer() }
    if vlc { h.player = nil; h.vlc = VLCPlayerController() }
    return h
}

// 1. Retired page: captured isActive was true when the callback was registered,
//    but the page is no longer current. It must never take audio.
let stale = fresh(capturedIsActive: true, pageActive: false)
stale.callResume()
expect(stale.seamAudio.playCalls.isEmpty, "stale captured-active page resumed")
expect(!stale.isPlaying, "stale captured-active page marked playing")
expect(AVAudioSession.instance.activeCalls.isEmpty, "stale captured-active page activated the audio session")

// 2. Formerly preloaded page (captured isActive false) that is now current resumes.
let current = fresh(capturedIsActive: false, pageActive: true)
current.callResume()
expect(current.seamAudio.playCalls.count == 1, "current page did not resume once")
expect(current.isPlaying, "current page not marked playing after resume")
expect(AVAudioSession.instance.activeCalls == [true], "current page did not activate the audio session")

// 3. Duplicate resume from AppDelegate/Scene/page notifications plays only once.
let duplicate = fresh(capturedIsActive: false, pageActive: true)
duplicate.callResume()
duplicate.callResume()
duplicate.callResume()
expect(duplicate.seamAudio.playCalls.count == 1, "duplicate resume started playback more than once")
expect(duplicate.isPlaying, "duplicate resume left player stopped")

// 4. Manual pause intent survives the background round trip.
let manual = fresh(capturedIsActive: false, pageActive: true)
manual.userPaused = true
manual.callResume()
expect(manual.seamAudio.playCalls.isEmpty, "manual pause was overridden by resume")
expect(!manual.isPlaying, "manual pause was marked playing")
expect(AVAudioSession.instance.activeCalls.isEmpty, "manual pause still activated the audio session")

// 5. Pending source swap: resume must not race the replacement source.
let swapping = fresh(capturedIsActive: false, pageActive: true)
swapping.pendingPosition = 12.5
swapping.callResume()
expect(swapping.seamAudio.playCalls.isEmpty, "resume played while a source swap was pending")
expect(!swapping.isPlaying, "resume marked pending-swap player playing")

// 6. Cover overlay holds playback.
let covered = fresh(capturedIsActive: false, pageActive: true)
DDPlayback.shared.coverHold = true
covered.callResume()
expect(covered.seamAudio.playCalls.isEmpty, "resume played behind a cover overlay")
expect(!covered.isPlaying, "resume marked covered player playing")

// 7. App not yet active (notification ordering) must not resume.
let inactiveApp = fresh(capturedIsActive: false, pageActive: true)
DDPlayback.shared.appIsActive = false
inactiveApp.callResume()
expect(inactiveApp.seamAudio.playCalls.isEmpty, "resume played while the app was inactive")
expect(!inactiveApp.isPlaying, "resume marked player playing while app inactive")

// 8. AVPlayer path resumes through the seamless controller and rearms HD.
let av = fresh(capturedIsActive: false, pageActive: true)
av.hdPlayer = HDPlayer()
av.muted = true
av.callResume()
expect(av.seamAudio.playCalls.count == 1, "AV resume did not resume the seamless audio engine")
expect(av.seamAudio.playCalls.first?.1 == true, "AV resume ignored the muted state")
expect(av.hdPlayer?.playCount == 1, "AV resume did not restart the HD companion player")
expect(av.isPlaying, "AV resume did not mark playing")

// 9. VLC path resumes and reapplies mute.
let vlc = fresh(capturedIsActive: false, pageActive: true, avPlayer: false, vlc: true)
vlc.muted = true
vlc.callResume()
expect(vlc.vlc?.mediaPlayer.playCount == 1, "VLC resume did not play the media player")
expect(vlc.vlc?.mediaPlayer.audio?.isMuted == true, "VLC resume ignored the muted state")
expect(vlc.isPlaying, "VLC resume did not mark playing")
expect(vlc.seamAudio.playCalls.isEmpty, "VLC resume also started the seamless engine")

// 10. Background playback already running: only sync the engine, never restart.
let bgPlaying = fresh(capturedIsActive: false, pageActive: true)
DDPlayback.bgPlay = true
bgPlaying.isPlaying = true
bgPlaying.playRate = 2
bgPlaying.callResume()
expect(bgPlaying.seamAudio.playCalls.isEmpty, "already-playing resume restarted the seamless engine")
expect(bgPlaying.seamAudio.syncCalls.count == 1, "already-playing resume skipped the background sync")
expect(bgPlaying.seamAudio.syncCalls.first?.0 == 2, "background sync used the wrong rate")
expect(bgPlaying.isPlaying, "already-playing resume stopped playback")

// 11. Without background playback, an already-playing page stays untouched too.
let playing = fresh(capturedIsActive: false, pageActive: true)
playing.isPlaying = true
playing.callResume()
expect(playing.seamAudio.playCalls.isEmpty, "already-playing resume restarted playback without background mode")
expect(playing.seamAudio.syncCalls.isEmpty, "already-playing resume synced without background mode")
expect(playing.isPlaying, "already-playing resume stopped playback")

if failed.isEmpty {
    print("PASS playback resume regression: \\(passed) assertions across 11 scenarios")
} else {
    for name in failed { print("FAIL \\(name)") }
    print("FAILED \\(failed.count) of \\(passed + failed.count) assertions")
    exit(1)
}
'''

SWIFT = (HARNESS
         .replace('__RESUME_POLICY__', RESUME_POLICY)
         .replace('__RESUME_BODY__', RESUME_BODY))

with tempfile.TemporaryDirectory(prefix='resume-regression-') as d:
    p = pathlib.Path(d)
    (p / 'main.swift').write_text(SWIFT)
    subprocess.run(['swiftc', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
