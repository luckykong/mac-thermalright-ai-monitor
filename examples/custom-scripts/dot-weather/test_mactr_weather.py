#!/usr/bin/env python3

import datetime as dt
import importlib.util
from pathlib import Path
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("mactr_weather.py")
SPEC = importlib.util.spec_from_file_location("mactr_weather", MODULE_PATH)
weather = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(weather)


def nowcast(summary: str, when: dt.datetime, values: list[float]):
    return {
        "summary": summary,
        "updateTime": when,
        "minutely": [{"precip": value} for value in values],
    }


class MacTRWeatherTests(unittest.TestCase):
    def test_absolute_time_marks_next_day(self):
        result = weather.add_absolute_times(
            "20分钟后开始下雨", dt.datetime(2026, 7, 28, 23, 50))
        self.assertEqual(result, "20分钟后[次日00:10]开始下雨")

    def test_trend_is_fixed_width(self):
        trend = weather.trend_text([0, 0.1, 0.5, 1.2] * 6)
        self.assertEqual(len(trend), 12)
        self.assertIn("█", trend)

    def test_dual_card_fits_renderer_budget(self):
        primary = nowcast(
            "约40分钟后雨渐停，当前为小雨",
            dt.datetime(2026, 7, 28, 12, 30),
            [0.3, 0.6, 1.2, 0.8, 0.2, 0] * 4,
        )
        secondary = nowcast(
            "约1小时后转中雨",
            dt.datetime(2026, 7, 28, 12, 30),
            [0] * 10 + [0.2, 0.8] * 7,
        )
        lines = weather.card_lines(primary, "广州", secondary, "佛山")
        self.assertLessEqual(len(lines), 8)
        self.assertTrue(all(weather.display_units(line) <= 28 for line in lines))

    def test_refresh_schedule_matches_original_script(self):
        at = lambda hour: dt.datetime(2026, 7, 28, hour, 0)
        self.assertEqual(weather.refresh_interval_seconds(at(8)), 300)
        self.assertEqual(weather.refresh_interval_seconds(at(12)), 600)
        self.assertEqual(weather.refresh_interval_seconds(at(18)), 300)
        self.assertEqual(weather.refresh_interval_seconds(at(22)), 1200)
        self.assertEqual(weather.refresh_interval_seconds(at(2)), 7200)

    def test_cache_round_trip_and_clock_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            now = dt.datetime(2026, 7, 28, 12, 0).astimezone()
            weather.write_cache(path, "place", "CARD", now)
            cached = weather.read_cache(path, "place")
            self.assertIsNotNone(cached)
            self.assertTrue(weather.cache_is_fresh(cached, now, 600))
            earlier = now - dt.timedelta(minutes=1)
            self.assertFalse(weather.cache_is_fresh(cached, earlier, 600))


if __name__ == "__main__":
    unittest.main()
