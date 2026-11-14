#!/usr/bin/env python3
"""Actual JS mapper and Swift model tests; fixtures are captured public metadata."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'DouDuo/DouyinFeedView.swift'
QUALITY = ROOT / 'DouDuo/DDPlaybackPreferences.swift'
FIXTURE = Path(__file__).parent / 'fixtures/video-metadata.json'

MAPPER = r'''
const fs=require('fs'),vm=require('vm');
const s=fs.readFileSync(process.argv[1],'utf8');
const js=s.match(/static let requestJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const rows=JSON.parse(fs.readFileSync(process.argv[2],'utf8')).samples;
const out=rows.map(a=>vm.runInNewContext(js+'\nmapA(a)',{a,URLSearchParams}));
console.log(JSON.stringify(out));
'''

def map_file(path):
    p = subprocess.run(['node', '-e', MAPPER, str(SOURCE), str(path)], capture_output=True, text=True, check=True)
    return json.loads(p.stdout)

def mapped_samples():
    return map_file(FIXTURE)

def map_samples(samples):
    with tempfile.NamedTemporaryFile('w', suffix='.json', encoding='utf-8', delete=False) as handle:
        json.dump({'samples': samples}, handle, ensure_ascii=False)
        path = handle.name
    try:
        return map_file(path)
    finally:
        os.unlink(path)

SYNTHETIC_SOURCES = [{
    'aweme_id': 'synthetic-quality',
    'desc': '合成多档清晰度',
    'create_time': 1793651325,
    'video': {
        'width': 1080, 'height': 1920,
        'play_addr': {'url_list': ['https://cdn/default.mp4', 'https://www.douyin.com/aweme/v1/play/?id=default']},
        'bit_rate': [
            {'gear_name': '720p', 'bit_rate': 400000, 'is_h265': 0,
             'play_addr': {'width': 1280, 'height': 720,
                           'url_list': ['https://cdn/720.mp4', 'https://www.douyin.com/aweme/v1/play/?id=720']}},
            {'gear_name': '720p-dup', 'bit_rate': 400000, 'is_h265': 0,
             'play_addr': {'width': 1280, 'height': 720,
                           'url_list': ['https://cdn/720.mp4', 'https://www.douyin.com/aweme/v1/play/?id=720']}},
            {'gear_name': 'broken', 'bit_rate': 999999, 'play_addr': {'url_list': []}},
            {'gear_name': '1080p', 'bit_rate': 900000, 'is_h265': 1,
             'play_addr': {'width': 1920, 'height': 1080,
                           'url_list': ['https://cdn/1080.mp4', 'https://www.douyin.com/aweme/v1/play/?id=1080']}},
        ]
    }
}]

HARNESS = r'''
var failures = 0
func check(_ value: Bool, _ name: String) {
    if !value { failures += 1; FileHandle.standardError.write(Data(("FAIL " + name + "\n").utf8)) }
}
func syntheticAweme(_ extra: [String: Any]) -> DYAweme {
    var base: [String: Any] = ["id": "synthetic", "desc": "", "width": 1080, "height": 1920,
        "duration": 1, "images": [], "music": "", "userDigged": 0, "isCollect": 0,
        "author": ["name": "合成", "avatar": NSNull(), "secUid": NSNull()],
        "stats": ["digg": 0, "comment": 0, "collect": 0, "share": 0]]
    for (key, value) in extra { base[key] = value }
    return try! JSONDecoder().decode(DYAweme.self, from: JSONSerialization.data(withJSONObject: base))
}
func gear(_ url: String, _ alternate: String?, _ height: Int, _ bitrate: Int,
          _ hevc: Bool = false) -> [String: Any] {
    ["url": url, "alternate": alternate ?? NSNull(), "height": height,
     "bitrate": bitrate, "isHEVC": hevc]
}
func describe(_ quality: DDVideoQuality?) -> [String: Any] {
    guard let quality else {
        return ["url": NSNull(), "height": 0, "bitrate": 0, "hevc": false,
                "alternate": NSNull(), "title": NSNull()]
    }
    return ["url": quality.url, "height": quality.height, "bitrate": quality.bitrate,
            "hevc": quality.isHEVC, "alternate": quality.alternate ?? NSNull(),
            "title": quality.title]
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let items = try JSONDecoder().decode([DYAweme].self, from: data)
check(items[0].aiDeclaration == "作者声明：内容由 AI 生成", "real AI declaration despite false boolean")
check((items[0].qualitySources ?? []).isEmpty, "captures without gear lists decode to an empty quality list")
var object = (try JSONSerialization.jsonObject(with: data) as! [[String: Any]])[0]
object.removeValue(forKey: "publishedAt")
object.removeValue(forKey: "aiDeclaration")
object.removeValue(forKey: "qualitySources")
let old = try JSONDecoder().decode(DYAweme.self, from: JSONSerialization.data(withJSONObject: object))
check(old.publishedAt == nil && old.aiDeclaration == nil && old.qualitySources == nil,
      "legacy cache decodes without publish/declaration/quality fields")
let now = Date(timeIntervalSince1970: 2_000_000_000)
var sample = items[0]
for (age, expected) in [(30.0, "刚刚发布"), (120.0, "2分钟前发布"),
                        (7200.0, "2小时前发布"), (172800.0, "2天前发布")] {
    sample.publishedAt = now.timeIntervalSince1970 - age
    check(sample.publicationText(now: now) == expected, expected)
}
for invalid in [0.0, -1.0, Double.nan, Double.infinity, now.timeIntervalSince1970 + 60] {
    sample.publishedAt = invalid
    check(sample.publicationText(now: now) == nil, "invalid/future time hidden")
}
sample.publishedAt = now.timeIntervalSince1970 - 30
check(sample.metadataText(now: now) == "刚刚发布 · 作者声明：内容由 AI 生成", "combined metadata row")
check(sample.metadataText(now: now, includePublication: false) == "作者声明：内容由 AI 生成",
      "hiding publication keeps the AI declaration")
sample.aiDeclaration = "  作者声明：内容由 AI 生成  "
check(sample.metadataText(now: now, includePublication: false) == "作者声明：内容由 AI 生成",
      "hidden publication trims the AI declaration")
sample.aiDeclaration = nil
check(sample.metadataText(now: now, includePublication: false) == nil,
      "hidden publication without declaration has no fake label")
check(sample.metadataText(now: now) == "刚刚发布", "publication only when declaration missing")
sample.publishedAt = nil
check(sample.metadataText(now: now) == nil, "unknown metadata has no fake label")

let sourceData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
let synthItems = try JSONDecoder().decode([DYAweme].self, from: sourceData)
check(synthItems.count == 1, "synthetic source sample decoded")
let mappedSources = synthItems[0].qualitySources ?? []
if mappedSources.count == 2 {
    check(mappedSources[0].url == "https://cdn/720.mp4" && mappedSources[0].height == 720
          && mappedSources[0].bitrate == 400_000 && !mappedSources[0].isHEVC, "720p gear decoded")
    check(mappedSources[1].url == "https://cdn/1080.mp4" && mappedSources[1].height == 1080
          && mappedSources[1].bitrate == 900_000 && mappedSources[1].isHEVC, "1080p HEVC gear decoded")
    check(mappedSources[1].title == "1080p · 900 kbps", "quality title formatting")
    check(mappedSources[1].id == mappedSources[1].url, "quality identity is its url")
}

let lowGear = gear("https://cdn/low.mp4", nil, 720, 400_000)
let midGear = gear("https://cdn/mid.mp4", "https://www.douyin.com/aweme/v1/play/?id=mid", 1080, 900_000)
let highGear = gear("https://cdn/high.mp4", "https://www.douyin.com/aweme/v1/play/?id=high", 2160, 2_000_000, true)
let multi = syntheticAweme(["play": "https://cdn/high.mp4",
                            "playAlt": "https://www.douyin.com/aweme/v1/play/?id=high",
                            "qualitySources": [lowGear, midGear, highGear]])
let bare = syntheticAweme(["play": "https://cdn/only.mp4",
                           "playAlt": "https://www.douyin.com/aweme/v1/play/?id=only",
                           "playFast": "https://cdn/fast.mp4"])
let missingPlay = syntheticAweme(["width": 720, "height": 1280])
let mixed = syntheticAweme(["play": "https://cdn/hd.mp4",
                            "qualitySources": [gear("https://cdn/hd.mp4", nil, 1080, 500_000),
                                               gear("https://cdn/sd.mp4", nil, 720, 300_000)]])
var quality: [String: Any] = [:]
quality["best"] = describe(DDVideoQualityPolicy.select(multi, preference: "best", savingData: false))
quality["low"] = describe(DDVideoQualityPolicy.select(multi, preference: "low", savingData: true))
quality["autoSaving"] = describe(DDVideoQualityPolicy.select(multi, preference: "auto", savingData: true))
quality["autoNormal"] = describe(DDVideoQualityPolicy.select(multi, preference: "auto", savingData: false))
quality["explicit"] = describe(DDVideoQualityPolicy.select(multi, preference: "https://cdn/mid.mp4", savingData: true))
quality["unknown"] = describe(DDVideoQualityPolicy.select(multi, preference: "https://cdn/absent.mp4", savingData: false))
quality["fallbackLow"] = describe(DDVideoQualityPolicy.select(bare, preference: "low", savingData: false))
quality["fallbackAutoSaving"] = describe(DDVideoQualityPolicy.select(bare, preference: "auto", savingData: true))
quality["fallbackAuto"] = describe(DDVideoQualityPolicy.select(bare, preference: "auto", savingData: false))
quality["missing"] = describe(DDVideoQualityPolicy.select(missingPlay, preference: "auto", savingData: false))
quality["lowByBitrate"] = describe(DDVideoQualityPolicy.select(mixed, preference: "low", savingData: false))

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
calendar.locale = Locale(identifier: "en_US_POSIX")
func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0,
         _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day,
                                       hour: hour, minute: minute, second: second))!
}
func stamp(_ date: Date) -> TimeInterval { date.timeIntervalSince1970 }
func filtered(_ publishedAt: TimeInterval?, _ unit: String, _ value: Int,
              now: Date, undated: Bool = true, useDefaultCalendar: Bool = false) -> Bool {
    if useDefaultCalendar {
        return DDRecommendationTimeFilter.includes(publishedAt, unit: unit, value: value,
                                                   includeUndated: undated, now: now)
    }
    return DDRecommendationTimeFilter.includes(publishedAt, unit: unit, value: value,
                                               includeUndated: undated, now: now, calendar: calendar)
}
var filters: [String: Bool] = [:]
let march10 = day(2026, 3, 10, 12)
filters["offNil"] = filtered(nil, "off", 7, now: march10)
filters["unknownUnitNil"] = filtered(nil, "weeks", 7, now: march10)
filters["daysBoundaryIn"] = filtered(stamp(day(2026, 3, 3, 12)), "days", 7, now: march10)
filters["daysBoundaryOut"] = filtered(stamp(day(2026, 3, 3, 11, 59, 59)), "days", 7, now: march10)
filters["daysValue0In"] = filtered(stamp(day(2026, 3, 9, 12)), "days", 0, now: march10)
filters["daysValue0Out"] = filtered(stamp(day(2026, 3, 9, 11, 59, 59)), "days", 0, now: march10)
filters["daysCapIn"] = filtered(stamp(day(2025, 3, 11, 12)), "days", 10_000, now: march10)
filters["daysCapOut"] = filtered(stamp(day(2025, 3, 9, 12)), "days", 10_000, now: march10)
let march15 = day(2026, 3, 15)
filters["monthsBoundaryIn"] = filtered(stamp(day(2026, 2, 15)), "months", 1, now: march15)
filters["monthsBoundaryOut"] = filtered(stamp(day(2026, 2, 14, 23, 59, 59)), "months", 1, now: march15)
filters["monthsValue0In"] = filtered(stamp(day(2026, 2, 15)), "months", 0, now: march15)
filters["monthsValue0Out"] = filtered(stamp(day(2026, 2, 14, 23, 59, 59)), "months", 0, now: march15)
let march31 = day(2026, 3, 31)
filters["monthsEndMarchIn"] = filtered(stamp(day(2026, 2, 28, 12)), "months", 1, now: march31)
filters["monthsEndMarchOut"] = filtered(stamp(day(2026, 2, 27, 23, 59, 59)), "months", 1, now: march31)
let may31 = day(2026, 5, 31)
filters["monthsEndMayIn"] = filtered(stamp(day(2026, 4, 30, 12)), "months", 1, now: may31)
filters["monthsEndMayOut"] = filtered(stamp(day(2026, 4, 29, 23, 59, 59)), "months", 1, now: may31)
filters["monthsCapIn"] = filtered(stamp(day(2024, 3, 15)), "months", 1_000, now: march15)
filters["monthsCapOut"] = filtered(stamp(day(2024, 3, 14, 23, 59, 59)), "months", 1_000, now: march15)
let future = march10.timeIntervalSince1970 + 60
let invalidTimes: [(String, TimeInterval?)] = [("nil", nil), ("zero", 0), ("negative", -1),
                                               ("nan", .nan), ("infinity", .infinity),
                                               ("future", future)]
for (key, value) in invalidTimes {
    filters["undatedOn-" + key] = filtered(value, "days", 7, now: march10, undated: true)
    filters["undatedOff-" + key] = filtered(value, "days", 7, now: march10, undated: false)
}
let june15 = day(2026, 6, 15, 12)
filters["localCalendarIn"] = filtered(stamp(june15.addingTimeInterval(-20 * 86400)), "months", 1,
                                      now: june15, useDefaultCalendar: true)
filters["localCalendarOut"] = filtered(stamp(june15.addingTimeInterval(-60 * 86400)), "months", 1,
                                       now: june15, useDefaultCalendar: true)

let payload: [String: Any] = ["quality": quality, "filters": filters]
let out = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
FileHandle.standardOutput.write(out)
exit(failures == 0 ? 0 : 1)
'''

class MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SOURCE.read_text()
        model = source[source.index('struct DYAweme:'):source.index('/// 点赞/收藏的结果')]
        preferences = QUALITY.read_text()
        quality = preferences[preferences.index('struct DDVideoQuality:'):preferences.index('enum DDChromeGroup')]
        cls.temp = tempfile.TemporaryDirectory(prefix='douduo-metadata-', dir=os.environ.get('TMPDIR'))
        directory = Path(cls.temp.name)
        harness = directory / 'main.swift'
        harness.write_text('import Foundation\n' + model + '\n' + quality + '\n' + HARNESS, encoding='utf-8')
        binary = directory / 'verify'
        build = subprocess.run(['swiftc', str(harness), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode != 0:
            raise AssertionError('Actual extracted Swift model must compile:\n' + build.stderr)
        cls.mapped = mapped_samples()
        cls.synthetic = map_samples(SYNTHETIC_SOURCES)
        (directory / 'samples.json').write_text(json.dumps(cls.mapped, ensure_ascii=False), encoding='utf-8')
        (directory / 'sources.json').write_text(json.dumps(cls.synthetic, ensure_ascii=False), encoding='utf-8')
        cls.process = subprocess.run([str(binary), str(directory / 'samples.json'), str(directory / 'sources.json')],
                                     capture_output=True, text=True)
        cls.result = json.loads(cls.process.stdout) if cls.process.stdout.strip() else {}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_swift_contracts_pass(self):
        self.assertEqual(self.process.returncode, 0, self.process.stdout + self.process.stderr)

    def test_mapper_preserves_real_metadata_and_does_not_infer_from_false(self):
        raw = json.loads(FIXTURE.read_text())['samples']
        for a, b in zip(raw, self.mapped):
            self.assertEqual(b.get('publishedAt'), a['create_time'])
            self.assertEqual(b.get('qualitySources'), [])
        self.assertFalse(raw[0]['is_aigc_media'])
        self.assertEqual(self.mapped[0].get('aiDeclaration'), '作者声明：内容由 AI 生成')
        self.assertIsNone(self.mapped[1].get('aiDeclaration'), 'personal opinion is not an AI declaration')
        self.assertIsNone(self.mapped[2].get('aiDeclaration'), 'missing label is not an AI verdict')

    def test_mapper_emits_deduplicated_quality_sources(self):
        sample = self.synthetic[0]
        self.assertEqual(sample['play'], 'https://cdn/1080.mp4')
        self.assertEqual(sample['qualitySources'], [
            {'url': 'https://cdn/720.mp4',
             'alternate': 'https://www.douyin.com/aweme/v1/play/?id=720',
             'height': 720, 'bitrate': 400000, 'isHEVC': False},
            {'url': 'https://cdn/1080.mp4',
             'alternate': 'https://www.douyin.com/aweme/v1/play/?id=1080',
             'height': 1080, 'bitrate': 900000, 'isHEVC': True},
        ])

    def test_swift_quality_policy_selects_synthetic_gears(self):
        quality = self.result.get('quality', {})
        self.assertEqual(set(quality), {
            'best', 'low', 'autoSaving', 'autoNormal', 'explicit', 'unknown',
            'fallbackLow', 'fallbackAutoSaving', 'fallbackAuto', 'missing', 'lowByBitrate',
        })
        high = {'url': 'https://cdn/high.mp4', 'height': 2160, 'bitrate': 2000000, 'hevc': True,
                'alternate': 'https://www.douyin.com/aweme/v1/play/?id=high',
                'title': '2160p · 2000 kbps'}
        low = {'url': 'https://cdn/low.mp4', 'height': 720, 'bitrate': 400000, 'hevc': False,
               'alternate': None, 'title': '720p · 400 kbps'}
        fast = {'url': 'https://cdn/fast.mp4', 'height': 0, 'bitrate': 0, 'hevc': False,
                'alternate': 'https://www.douyin.com/aweme/v1/play/?id=only', 'title': '原始画质'}
        for key in ('best', 'autoNormal', 'unknown'):
            with self.subTest(key=key):
                self.assertEqual(quality[key], high)
        for key in ('low', 'autoSaving'):
            with self.subTest(key=key):
                self.assertEqual(quality[key], low)
        self.assertEqual(quality['explicit'], {
            'url': 'https://cdn/mid.mp4', 'height': 1080, 'bitrate': 900000, 'hevc': False,
            'alternate': 'https://www.douyin.com/aweme/v1/play/?id=mid',
            'title': '1080p · 900 kbps'})
        for key in ('fallbackLow', 'fallbackAutoSaving'):
            with self.subTest(key=key):
                self.assertEqual(quality[key], fast)
        self.assertEqual(quality['fallbackAuto'], {
            'url': 'https://cdn/only.mp4', 'height': 1080, 'bitrate': 0, 'hevc': False,
            'alternate': 'https://www.douyin.com/aweme/v1/play/?id=only', 'title': '1080p'})
        self.assertEqual(quality['missing'], {
            'url': None, 'height': 0, 'bitrate': 0, 'hevc': False, 'alternate': None, 'title': None})
        self.assertEqual(quality['lowByBitrate'], {
            'url': 'https://cdn/sd.mp4', 'height': 720, 'bitrate': 300000, 'hevc': False,
            'alternate': None, 'title': '720p · 300 kbps'})

    def test_time_filter_windows_boundaries_and_undated(self):
        filters = self.result.get('filters', {})
        expected = {
            'offNil': True, 'unknownUnitNil': True,
            'daysBoundaryIn': True, 'daysBoundaryOut': False,
            'daysValue0In': True, 'daysValue0Out': False,
            'daysCapIn': True, 'daysCapOut': False,
            'monthsBoundaryIn': True, 'monthsBoundaryOut': False,
            'monthsValue0In': True, 'monthsValue0Out': False,
            'monthsEndMarchIn': True, 'monthsEndMarchOut': False,
            'monthsEndMayIn': True, 'monthsEndMayOut': False,
            'monthsCapIn': True, 'monthsCapOut': False,
            'localCalendarIn': True, 'localCalendarOut': False,
        }
        for key in ('nil', 'zero', 'negative', 'nan', 'infinity', 'future'):
            expected['undatedOn-' + key] = True
            expected['undatedOff-' + key] = False
        self.assertEqual(set(filters), set(expected))
        for key, value in expected.items():
            with self.subTest(filter=key):
                self.assertEqual(filters[key], value)

if __name__ == '__main__': unittest.main()
