#!/usr/bin/env python3

import contextlib
import datetime as dt
import importlib.util
import io
from pathlib import Path
import tempfile
import time
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

    def test_stale_cache_stops_being_a_usable_fallback(self):
        """An expired key must not leave a days-old card showing as healthy."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cache.json"
            written = dt.datetime(2026, 7, 28, 12, 0).astimezone()
            weather.write_cache(path, "place", "CARD", written)
            cached = weather.read_cache(path, "place")

            recent = written + dt.timedelta(
                seconds=weather.MAX_CACHE_AGE_SECONDS - 60)
            expired = written + dt.timedelta(
                seconds=weather.MAX_CACHE_AGE_SECONDS + 60)
            self.assertTrue(weather.cache_is_usable_fallback(cached, recent))
            self.assertFalse(weather.cache_is_usable_fallback(cached, expired))

    def test_credentials_are_stripped_from_messages(self):
        """Failure text reaches the physical panel, so it must carry no key."""
        message = (
            "HTTPError: 401 for url: "
            "https://api.example.com/v7/minutely/5m?location=1,2&key=SECRET123")
        redacted = weather.redact(message)
        self.assertNotIn("SECRET123", redacted)
        self.assertIn("key=***", redacted)
        self.assertIn("location=1,2", redacted)

        bearer = weather.redact("Authorization: Bearer abc.def-123")
        self.assertNotIn("abc.def-123", bearer)

    def test_absent_data_is_not_drawn_as_dry_weather(self):
        """An empty forecast must read as "no data", not as a dry two hours."""
        self.assertEqual(weather.resample_max([], points=12), [None] * 12)
        self.assertEqual(weather.trend_text([]), weather.NO_DATA_MARK * 12)

        # A short but present series is upsampled from its nearest sample,
        # never zero-padded, so it keeps real intensities end to end.
        buckets = weather.resample_max([0.4, 0.8], points=12)
        self.assertNotIn(None, buckets)
        self.assertEqual((buckets[0], buckets[-1]), (0.4, 0.8))

    def test_sample_mode_runs_without_the_upstream_project(self):
        """--sample must work from a bare checkout of this example."""
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            exit_code = weather.main(["--sample", "--dual"])
        lines = buffer.getvalue().strip().split("\n")

        self.assertEqual(exit_code, 0)
        self.assertLessEqual(len(lines), 8)
        self.assertTrue(all(weather.display_units(l) <= 28 for l in lines))
        self.assertTrue(any("雨势" in line for line in lines))

    def test_slow_request_gives_up_before_mactr_kills_us(self):
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            weather._call_with_timeout(lambda: time.sleep(30), (), 0.2)
        self.assertLess(time.monotonic() - started, 5)


if __name__ == "__main__":
    unittest.main()
