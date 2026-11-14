#!/usr/bin/env python3
"""Compile the real Foundation-only video policy and exercise synthetic fixtures.

Run: python3 scripts/test_danmaku_layout.py -v
No API, simulator, app installation, or third-party Python packages are used.
Swift sources/binaries/caches live in a temporary directory under the repo root.
"""
import collections
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "DouDuo" / "DouyinExtras.swift"
START = "// MARK: - 弹幕调度策略"
END = "// MARK: - 弹幕层（视频）"

# Every input below is explicitly synthetic; none represents an API response.
HARNESS = r'''
func synthetic(_ id: String, _ text: String, _ time: Double) -> DYDanmaku {
    DYDanmaku(id: "synthetic-" + id, text: text, offset: time)
}
let mode = CommandLine.arguments[1]
func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
fileprivate func placed(_ items: [DYDanmaku], lanes: Int = 6, speed: CGFloat = 10000,
            density: DYDanmakuPolicy.Density = .dense, dedup: Bool = false, w: CGFloat = 390,
            fontSize: CGFloat = 15) {
    let result = DYDanmakuPolicy.layout(items, w: w, lanes: lanes,
                                      speed: speed, density: density, deduplicate: dedup,
                                      fontSize: fontSize)
    emit(result.map { p in
        ["id": p.d.id, "text": p.d.text, "offset": p.d.offset,
         "lane": p.lane, "width": Double(p.width), "dur": p.dur] as [String: Any]
    })
}
switch mode {
case "region":
    var rows: [[String: Any]] = []
    for height: CGFloat in [0, 80, 192, 240, 276, 300, 600, 844, 926, 1200, 2400] {
        for inset: CGFloat in [-20, 0, 20, 59, 200] {
            for raw in 0...2 {
                for fontSize: CGFloat in [10, 15, 28] {
                    for lines in [0, 3, 10] {
                        let d = DYDanmakuPolicy.Density(rawValue: raw)!
                        let r = DYDanmakuPolicy.region(height: height, topInset: inset, density: d,
                                                       fontSize: fontSize, lines: lines)
                        rows.append(["height": Double(height), "inset": Double(inset), "density": raw,
                                     "fontSize": Double(fontSize), "lines": lines,
                                     "top": Double(r.top), "bottom": Double(r.bottom), "lanes": r.lanes,
                                     "maxLanes": d.maxLanes, "maxPerSecond": d.maxPerSecond,
                                     "laneHeight": Double(DYDanmakuPolicy.laneHeight(fitting: fontSize)),
                                     "gap": Double(DYDanmakuPolicy.gap)])
                    }
                }
            }
        }
    }
    emit(rows)
case "density0", "density1", "density2":
    let raw = Int(String(mode.last!))!
    placed((0..<240).map { synthetic("burst-\($0)", "合成密度 \($0)", Double($0) * 0.025) },
           density: DYDanmakuPolicy.Density(rawValue: raw)!)
case "normalize":
    placed([synthetic("a", " ＨｅＬＬＯ　World ", 0),
            synthetic("b", "hello world", 1), synthetic("c", "HELLO\nWORLD", 2),
            synthetic("d", "h e l l o w o r l d", 3),
            synthetic("e", "另一条", 4), synthetic("f", "😀", 5),
            synthetic("g", "😃", 6)], dedup: true)
case "cooldown":
    placed([synthetic("a", "冷却合成", 0), synthetic("b", "冷却合成", 9.999),
            synthetic("c", "冷却合成", 10), synthetic("d", "冷却合成", 20.001)], dedup: true)
case "dedupOff":
    placed([synthetic("a", "相同文本", 0), synthetic("b", "相同文本", 1),
            synthetic("a", "不同文本但相同ID", 2)], dedup: false)
case "dedupOnIDs":
    placed([synthetic("a", "文本一", 0), synthetic("a", "文本二", 1),
            synthetic("b", "文本三", 2)], dedup: true)
case "invalid":
    placed([synthetic("negative", "负数", -1), synthetic("nan", "非数", .nan),
            synthetic("inf", "无穷", .infinity), synthetic("ninf", "负无穷", -.infinity),
            synthetic("empty", "", 0), synthetic("blank", " \t\n　", 1),
            synthetic("valid", "有效合成", 2)])
case "zero":
    placed([synthetic("a", "零轨道合成", 0)], lanes: 0)
case "collision":
    placed((0..<200).map { synthetic("collision-\($0)", "很长的合成弹幕用于检查尾部间距 \($0)", Double($0) * 0.1) },
           lanes: 2, speed: 100)
case "deterministic":
    placed((0..<120).map { synthetic("tie-\($0)", "相同时间戳合成 \($0)", Double($0 / 8)) })
case "widths":
    var rows: [[String: Any]] = []
    for w: CGFloat in [240, 390, 768, 1024] {
        let r = DYDanmakuPolicy.layout([synthetic("width", "合成宽度", 0)], w: w,
                    lanes: 1, speed: 100, density: .dense, deduplicate: false)
        rows.append(["w": Double(w), "count": r.count,
                     "width": r.first.map { Double($0.width) } ?? -1,
                     "dur": r.first?.dur ?? -1])
    }
    emit(rows)
case "fontScale":
    var rows: [[String: Any]] = []
    for fontSize: CGFloat in [10, 12, 15, 18, 22, 26, 28] {
        let r = DYDanmakuPolicy.layout([synthetic("font", "合成字号宽度测试需要足够长", 0)], w: 390,
                    lanes: 1, speed: 100, density: .dense, deduplicate: false, fontSize: fontSize)
        rows.append(["fontSize": Double(fontSize),
                     "laneHeight": Double(DYDanmakuPolicy.laneHeight(fitting: fontSize)),
                     "width": r.first.map { Double($0.width) } ?? -1,
                     "dur": r.first?.dur ?? -1])
    }
    emit(rows)
case "fontCollision":
    placed((0..<200).map { synthetic("font-collision-\($0)", "字号放大后的长弹幕仍需保持尾部间距 \($0)", Double($0) * 0.1) },
           lanes: 2, speed: 100, fontSize: 28)
case "linesCap":
    placed((0..<120).map { synthetic("lines-\($0)", "行数上限合成 \($0)", Double($0) * 0.3) },
           lanes: 14, speed: 10)
case "fontDefaults":
    let items = [synthetic("default-a", "默认字号一致性", 0),
                 synthetic("default-b", "第二行合成", 0.01)]
    let implicit = DYDanmakuPolicy.layout(items, w: 390, lanes: 3, speed: 100,
                                         density: .standard, deduplicate: true)
    let explicit = DYDanmakuPolicy.layout(items, w: 390, lanes: 3, speed: 100,
                                          density: .standard, deduplicate: true, fontSize: 15)
    let implicitRegion = DYDanmakuPolicy.region(height: 844, topInset: 59, density: .standard)
    let explicitRegion = DYDanmakuPolicy.region(height: 844, topInset: 59, density: .standard,
                                                fontSize: 15, lines: 0)
    let layoutRows: ([DYDanmakuPolicy.Placed]) -> [[String: Any]] = { placed in
        placed.map { p -> [String: Any] in ["id": p.d.id, "lane": p.lane, "width": Double(p.width), "dur": p.dur] }
    }
    emit(["layout": layoutRows(implicit), "explicit": layoutRows(explicit),
          "region": ["top": Double(implicitRegion.top), "bottom": Double(implicitRegion.bottom),
                     "lanes": implicitRegion.lanes],
          "explicitRegion": ["top": Double(explicitRegion.top), "bottom": Double(explicitRegion.bottom),
                             "lanes": explicitRegion.lanes]])
case "settingsClamp":
    emit(["font": [DYDanmakuSettings.fontSizeValue(.nan), DYDanmakuSettings.fontSizeValue(.infinity),
                   DYDanmakuSettings.fontSizeValue(5), DYDanmakuSettings.fontSizeValue(99),
                   DYDanmakuSettings.fontSizeValue(18)],
          "lines": [DYDanmakuSettings.linesValue(-5), DYDanmakuSettings.linesValue(0),
                    DYDanmakuSettings.linesValue(4), DYDanmakuSettings.linesValue(99)],
          "opacity": [DYDanmakuSettings.opacityValue(.nan), DYDanmakuSettings.opacityValue(0),
                      DYDanmakuSettings.opacityValue(1.5), DYDanmakuSettings.opacityValue(0.62)],
          "laneHeight": [DYDanmakuPolicy.laneHeight(fitting: 4),
                         DYDanmakuPolicy.laneHeight(fitting: .nan),
                         DYDanmakuPolicy.laneHeight(fitting: 10),
                         DYDanmakuPolicy.laneHeight(fitting: 28),
                         DYDanmakuPolicy.laneHeight(fitting: 96)]])
case "empty": placed([])
default: fatalError("Unknown synthetic test case")
}
'''


class DanmakuPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.binary = None
        cls.temp = None

    @classmethod
    def tearDownClass(cls):
        if cls.temp is not None:
            cls.temp.cleanup()

    def require_policy(self):
        self.assertTrue(START in self.source,
                        "RED: missing video danmaku scheduling policy marker")
        self.assertTrue("enum DYDanmakuPolicy" in self.source,
                        "RED: DYDanmakuPolicy has not been implemented")
        self.assertIn(END, self.source)

    def run_case(self, name):
        self.require_policy()
        cls = type(self)
        if cls.binary is None:
            self.assertIsNotNone(shutil.which("swiftc"), "swiftc is required")
            model = re.search(r"(?:fileprivate\s+)?struct DYDanmaku\b[^\{]*\{.*?^\}",
                              self.source, re.MULTILINE | re.DOTALL)
            if model is None:
                self.fail("Cannot extract the actual DYDanmaku model")
            # The marked section also contains SwiftUI views; cut at the options menu struct.
            policy = self.source.split(START, 1)[1].split("struct DYDanmakuOptions", 1)[0]
            self.assertIn("enum DYDanmakuPolicy", policy)
            self.assertIn("enum DYDanmakuSettings", policy,
                          "settings contract must stay Foundation-only inside the policy slice")
            cls.temp = tempfile.TemporaryDirectory(prefix=".danmaku-regression-", dir=ROOT)
            tmp = Path(cls.temp.name)
            swift = tmp / "main.swift"
            swift.write_text("import Foundation\n" + model.group(0) + "\n" + policy + "\n" + HARNESS,
                             encoding="utf-8")
            binary = tmp / "danmaku-tests"
            result = subprocess.run(["swiftc", "-module-cache-path", str(tmp / "module-cache"),
                                     str(swift), "-o", str(binary)],
                                    capture_output=True, text=True, timeout=120, cwd=ROOT)
            self.assertEqual(result.returncode, 0,
                             "Actual extracted policy must compile using only Foundation:\n" + result.stderr)
            cls.binary = binary
        result = subprocess.run([str(cls.binary), name], capture_output=True, text=True,
                                timeout=30, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_policy_present(self):
        self.require_policy()

    def test_region_complete_rows_stay_in_top_third(self):
        lane_heights = {10: 19, 15: 28, 28: 52}
        for row in self.run_case("region"):
            with self.subTest(height=row["height"], inset=row["inset"], density=row["density"],
                              fontSize=row["fontSize"], lines=row["lines"]):
                cap = [2, 4, 6][row["density"]]
                top = max(0, row["inset"]) + 64
                bottom = row["height"] / 3
                lane_height = lane_heights[row["fontSize"]]
                self.assertEqual(row["laneHeight"], lane_height)
                self.assertEqual(row["gap"], 28)
                self.assertEqual(row["maxLanes"], cap)
                self.assertEqual(row["maxPerSecond"], [1, 2, 4][row["density"]])
                self.assertAlmostEqual(row["top"], top)
                self.assertAlmostEqual(row["bottom"], bottom)
                limit = min(row["lines"], 10) if row["lines"] else cap
                fitted = max(0, math.floor((bottom - top) / lane_height))
                self.assertEqual(row["lanes"], min(limit, fitted))
                self.assertLessEqual(row["lanes"], 10)
                if row["lanes"]:
                    self.assertLessEqual(top + row["lanes"] * lane_height, bottom + 1e-8)

    def test_manual_ten_lines_clip_to_available_top_third(self):
        lanes = {}
        for row in self.run_case("region"):
            if row["inset"] == 59 and row["density"] == 2 and row["lines"] == 10:
                lanes[(row["fontSize"], row["height"])] = row["lanes"]
        for height, expected in {600: 1, 844: 3, 926: 3, 1200: 5}.items():
            with self.subTest(fontSize=28, height=height):
                self.assertEqual(lanes[(28, height)], expected,
                                 "28pt text only fits what the top third allows")
        for height, expected in {844: 8, 926: 9}.items():
            with self.subTest(fontSize=10, height=height):
                self.assertEqual(lanes[(10, height)], expected)
        self.assertGreater(lanes[(10, 1200)], lanes[(28, 1200)])

    def test_font_size_scales_width_and_duration(self):
        rows = self.run_case("fontScale")
        base = next(r for r in rows if r["fontSize"] == 15)
        lane_heights = {10: 19, 12: 22, 15: 28, 18: 34, 22: 41, 26: 49, 28: 52}
        widths = []
        for row in rows:
            with self.subTest(fontSize=row["fontSize"]):
                widths.append(row["width"])
                self.assertAlmostEqual(row["width"], base["width"] * row["fontSize"] / 15, places=6)
                self.assertAlmostEqual(row["dur"], (390 + row["width"]) / 100, places=6)
                self.assertEqual(row["laneHeight"], lane_heights[row["fontSize"]])
        self.assertEqual(widths, sorted(widths))
        self.assertGreater(widths[-1], widths[0] * 2.5)

    def test_large_font_keeps_tail_gap_between_neighbours(self):
        output = self.run_case("fontCollision")
        self.assertGreater(len(output), 1)
        self.assertGreater(max(p["width"] for p in output), 390,
                           "28pt long text must span the whole screen")
        lanes = collections.defaultdict(list)
        for p in output:
            self.assertLess(p["lane"], 2)
            self.assertAlmostEqual(p["dur"], (390 + p["width"]) / 100, places=6)
            lanes[p["lane"]].append(p)
        for lane in lanes.values():
            lane.sort(key=lambda p: p["offset"])
            for previous, current in zip(lane, lane[1:]):
                travelled = (current["offset"] - previous["offset"]) * 100
                self.assertGreaterEqual(travelled + 1e-7, previous["width"] + 28)

    def test_layout_lane_count_caps_at_ten_rows(self):
        output = self.run_case("linesCap")
        self.assertEqual(sorted({p["lane"] for p in output}), list(range(10)))

    def test_default_arguments_keep_fifteen_point_layout(self):
        output = self.run_case("fontDefaults")
        self.assertTrue(output["layout"])
        self.assertEqual(output["layout"], output["explicit"])
        self.assertEqual(output["region"], output["explicitRegion"])

    def test_settings_clamps_nonfinite_and_out_of_range_values(self):
        output = self.run_case("settingsClamp")
        self.assertEqual(output["font"], [15, 15, 10, 28, 18])
        self.assertEqual(output["lines"], [0, 0, 4, 10])
        self.assertEqual(output["opacity"], [0.92, 0.1, 1, 0.62])
        self.assertEqual(output["laneHeight"], [19, 28, 19, 52, 52])

    def test_density_caps_and_distinct_throughput(self):
        counts = []
        for raw, (max_lanes, per_second) in enumerate([(2, 1), (4, 2), (6, 4)]):
            output = self.run_case(f"density{raw}")
            self.assertTrue(output)
            counts.append(len(output))
            buckets = collections.Counter(math.floor(p["offset"]) for p in output)
            self.assertTrue(all(n <= per_second for n in buckets.values()), buckets)
            self.assertTrue(all(0 <= p["lane"] < max_lanes for p in output))
        self.assertLess(counts[0], counts[1])
        self.assertLess(counts[1], counts[2])

    def test_normalizes_whitespace_case_and_fullwidth_without_emoji_loss(self):
        output = self.run_case("normalize")
        self.assertEqual([p["id"] for p in output],
                         ["synthetic-a", "synthetic-e", "synthetic-f", "synthetic-g"])

    def test_repeat_text_allowed_at_ten_seconds_not_before(self):
        self.assertEqual([p["id"] for p in self.run_case("cooldown")],
                         ["synthetic-a", "synthetic-c", "synthetic-d"])

    def test_dedup_off_allows_text_but_never_repeated_ids(self):
        self.assertEqual([p["id"] for p in self.run_case("dedupOff")],
                         ["synthetic-a", "synthetic-b"])

    def test_dedup_on_still_rejects_repeated_ids(self):
        self.assertEqual([p["id"] for p in self.run_case("dedupOnIDs")],
                         ["synthetic-a", "synthetic-b"])

    def test_filters_nonfinite_negative_and_blank(self):
        self.assertEqual([p["id"] for p in self.run_case("invalid")], ["synthetic-valid"])

    def test_zero_lanes(self):
        self.assertEqual(self.run_case("zero"), [])

    def test_layout_duration_for_different_screen_widths(self):
        for row in self.run_case("widths"):
            self.assertEqual(row["count"], 1)
            self.assertGreater(row["width"], 0)
            self.assertAlmostEqual(row["dur"], (row["w"] + row["width"]) / 100, places=6)

    def test_empty_items(self):
        self.assertEqual(self.run_case("empty"), [])

    def test_same_lane_tail_gap_and_duration(self):
        output = self.run_case("collision")
        self.assertGreater(len(output), 2, "Fixture must exercise lane reuse")
        lanes = collections.defaultdict(list)
        for p in output:
            self.assertIn(p["lane"], [0, 1])
            self.assertTrue(math.isfinite(p["width"]) and p["width"] > 0)
            self.assertAlmostEqual(p["dur"], (390 + p["width"]) / 100, places=6)
            lanes[p["lane"]].append(p)
        for lane in lanes.values():
            lane.sort(key=lambda p: p["offset"])
            for previous, current in zip(lane, lane[1:]):
                travelled = (current["offset"] - previous["offset"]) * 100
                self.assertGreaterEqual(travelled + 1e-7, previous["width"] + 28)

    def test_identical_input_order_has_deterministic_output(self):
        first = self.run_case("deterministic")
        self.assertTrue(first)
        self.assertEqual(len({p["id"] for p in first}), len(first))
        for _ in range(3):
            self.assertEqual(self.run_case("deterministic"), first)


if __name__ == "__main__":
    unittest.main()
