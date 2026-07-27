#!/usr/bin/env python3
"""Render dot-weather_push nowcast data as MacTR custom-card text.

The script writes only the finished card to stdout. Diagnostics go to stderr,
which MacTR keeps out of the card and shows only when the run fails, so a
stale-but-real card is never replaced by a stack trace.

`--sample` needs nothing but this file: it renders built-in fixture data so the
card layout can be checked from a fresh checkout. Live data additionally needs
a dot-weather_push checkout for its QWeather client and location config.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import sys
import threading
from typing import Any, Iterable


CARD_UNITS = 28
TREND_POINTS = 12
FULL_SCALE_MM = 1.2
CACHE_FILE = "mactr_weather_cache.json"

# A cached card older than this is worse than no card: MacTR would keep showing
# it, in its normal green "succeeded" state, long after an expired API key or a
# renamed dependency stopped the data ever refreshing.
MAX_CACHE_AGE_SECONDS = 6 * 60 * 60

# Must stay comfortably below MacTR's own script timeout (30 s at the suggested
# 300 s interval). If MacTR kills us first we are SIGKILLed, and the cache
# fallback below never gets to run.
REQUEST_TIMEOUT_SECONDS = 10.0

# Rendered where "no rain" is `·`, so that missing data does not masquerade as
# a dry forecast. Full-width like the block characters, to keep the bar aligned.
NO_DATA_MARK = "╌"

_RELATIVE_TIME = re.compile(
    r"(?:(?P<hours>\d+)\s*小时(?:\s*(?P<hour_minutes>\d+)\s*分钟)?"
    r"|(?P<after_minutes>\d+)\s*分钟)后"
    r"|持续\s*(?P<duration_minutes>\d+)\s*分钟"
)

# QWeather authenticates with a query parameter, so a requests exception string
# carries the key in full. MacTR renders script failures on the physical panel,
# where a photo of the desk would leak it.
_SECRET_PATTERN = re.compile(
    r"((?:key|token|apikey|api_key|password|secret)=)[^&\s\"']+"
    r"|(?i:(bearer)\s+)[A-Za-z0-9._\-]+",
    re.IGNORECASE,
)


def redact(value: Any) -> str:
    """Remove credentials from text that may reach the display or the log."""
    def replacement(match: re.Match[str]) -> str:
        if match.group(1):
            return f"{match.group(1)}***"
        return f"{match.group(2)} ***"

    return _SECRET_PATTERN.sub(replacement, str(value))


def display_units(text: str) -> int:
    """Approximate MacTR's 15 pt monospaced card width."""
    return sum(1 if ord(char) < 128 else 2 for char in text)


def clip_text(text: str, max_units: int = CARD_UNITS) -> str:
    text = " ".join(str(text).replace("\r", " ").replace("\n", " ").split())
    if display_units(text) <= max_units:
        return text

    result: list[str] = []
    used = 0
    ellipsis_units = display_units("…")
    for char in text:
        units = display_units(char)
        if used + units + ellipsis_units > max_units:
            break
        result.append(char)
        used += units
    return "".join(result).rstrip() + "…"


def wrap_text(
    text: str,
    max_units: int = CARD_UNITS,
    max_lines: int = 2,
) -> list[str]:
    """Wrap CJK/ASCII text without letting MacTR create surprise extra lines."""
    text = " ".join(str(text).replace("\r", " ").replace("\n", " ").split())
    if not text:
        return ["暂无临近预报"]

    tokens = re.findall(r"\[[^\]]+\]|[A-Za-z0-9.:/+%_-]+|\s+|.", text)
    lines: list[str] = []
    current = ""
    index = 0

    while index < len(tokens) and len(lines) < max_lines:
        token = tokens[index]
        candidate = (current + token).lstrip() if not current else current + token
        if display_units(candidate.rstrip()) <= max_units:
            current = candidate
            index += 1
            continue

        if current.strip():
            lines.append(current.rstrip(" ，,"))
            current = ""
            continue

        # A single token can only be too wide when it is an unusually long
        # ASCII word. Split it safely rather than emitting an over-wide line.
        part = clip_text(token, max_units)
        lines.append(part)
        index += 1

    if current.strip() and len(lines) < max_lines:
        lines.append(current.strip())

    if index < len(tokens) and lines:
        remaining = "".join(tokens[index:]).strip()
        if remaining:
            lines[-1] = clip_text(lines[-1].rstrip("…") + "…", max_units)

    return lines or ["暂无临近预报"]


def _relative_minutes(match: re.Match[str]) -> int:
    if match.group("after_minutes") is not None:
        return int(match.group("after_minutes"))
    if match.group("duration_minutes") is not None:
        return int(match.group("duration_minutes"))
    return int(match.group("hours")) * 60 + int(match.group("hour_minutes") or 0)


def add_absolute_times(summary: str, base_time: dt.datetime) -> str:
    """Insert deterministic clock times after QWeather relative-time phrases."""

    def replacement(match: re.Match[str]) -> str:
        target = base_time + dt.timedelta(minutes=_relative_minutes(match))
        next_day = "次日" if target.date() > base_time.date() else ""
        return f"{match.group(0)}[{next_day}{target:%H:%M}]"

    return _RELATIVE_TIME.sub(replacement, summary or "")


def amount(value: float) -> str:
    if value < 0.005:
        return "0"
    return f"{value:.2f}".lstrip("0")


def precipitation_values(nowcast: dict[str, Any]) -> list[float]:
    values: list[float] = []
    for item in nowcast.get("minutely") or []:
        try:
            values.append(max(0.0, float(item.get("precip", 0) or 0)))
        except (TypeError, ValueError, AttributeError):
            values.append(0.0)
    return values


def resample_max(
    values: Iterable[float],
    points: int = TREND_POINTS,
) -> list[float | None]:
    """Compress a minutely series into `points` buckets of peak intensity.

    A shorter series is upsampled — each bucket falls back on the nearest
    sample — so it is never zero-padded. An entirely absent series yields None
    per bucket instead of 0.0, so the trend bar can say "no data" rather than
    drawing a full-width row of confident, dry-looking weather.
    """
    source = list(values)
    if not source:
        return [None] * points
    result: list[float | None] = []
    for index in range(points):
        start = int(index * len(source) / points)
        end = max(start + 1, int((index + 1) * len(source) / points))
        window = source[start:min(end, len(source))]
        result.append(max(window) if window else None)
    return result


def trend_text(values: Iterable[float]) -> str:
    levels = "·▁▂▃▄▅▆▇█"
    chars: list[str] = []
    for value in resample_max(values):
        if value is None:
            chars.append(NO_DATA_MARK)
            continue
        if value <= 0.001:
            chars.append(levels[0])
            continue
        level = max(1, min(8, round(value / FULL_SCALE_MM * 8)))
        chars.append(levels[level])
    return "".join(chars)


def update_time(nowcast: dict[str, Any]) -> dt.datetime:
    value = nowcast.get("updateTime")
    return value if isinstance(value, dt.datetime) else dt.datetime.now()


def card_lines(
    primary: dict[str, Any],
    primary_name: str,
    secondary: dict[str, Any] | None = None,
    secondary_name: str = "",
) -> list[str]:
    """Build at most eight pre-fitted lines for MacTR's 280 px card."""
    primary_values = precipitation_values(primary)
    primary_time = update_time(primary)
    summary = add_absolute_times(primary.get("summary") or "", primary_time)
    current = primary_values[0] if primary_values else 0.0
    peak = max(primary_values, default=0.0)
    total = sum(primary_values)

    lines = [
        clip_text(f"{primary_name} · {primary_time:%H:%M}"),
        *wrap_text(summary, max_lines=2),
        clip_text(f"当前 {amount(current)}  峰值 {amount(peak)}"),
        clip_text(f"2h累计 {amount(total)} mm"),
        # No separating space: "雨势" plus 12 full-width blocks is exactly the
        # card's 28-unit budget, so all two hours remain visible.
        clip_text(f"雨势{trend_text(primary_values)}"),
    ]

    if secondary is not None:
        secondary_values = precipitation_values(secondary)
        secondary_time = update_time(secondary)
        secondary_peak = max(secondary_values, default=0.0)
        secondary_total = sum(secondary_values)
        secondary_summary = add_absolute_times(
            secondary.get("summary") or "", secondary_time)
        lines.extend([
            clip_text(
                f"▸{secondary_name} 峰{amount(secondary_peak)} "
                f"累{amount(secondary_total)}"),
            *wrap_text(secondary_summary, max_lines=1),
        ])

    return [clip_text(line) for line in lines[:8]]


# --- Built-in fixtures -------------------------------------------------------
#
# Previously --sample imported sample_data from dot-weather_push, so the
# example could not be run at all without a copy of that separate, unpublished
# project — not even to preview the card layout.

SAMPLE_LOCATION = "示例城区"
SAMPLE_LOCATION_SECONDARY = "示例郊区"


def _sample_series(
    peak: float,
    centre: int,
    width: int,
    points: int = 120,
) -> list[float]:
    """One smooth rain burst across a two-hour minutely series."""
    values: list[float] = []
    for index in range(points):
        distance = abs(index - centre)
        values.append(round(peak * (1 - distance / width), 3)
                      if distance < width else 0.0)
    return values


def sample_nowcast() -> dict[str, Any]:
    return {
        "summary": "35分钟后雨渐停，当前为小雨",
        "updateTime": dt.datetime(2026, 7, 28, 12, 30),
        "minutely": [{"precip": v} for v in _sample_series(0.5, 10, 16)],
    }


def sample_nowcast_secondary() -> dict[str, Any]:
    return {
        "summary": "约1小时后转中雨",
        "updateTime": dt.datetime(2026, 7, 28, 12, 30),
        "minutely": [{"precip": v} for v in _sample_series(0.4, 70, 18)],
    }


# --- dot-weather_push integration -------------------------------------------


def locate_project(explicit: str | None) -> Path:
    script_dir = Path(__file__).resolve().parent
    candidates = [
        Path(explicit).expanduser() if explicit else None,
        Path(os.environ["DOT_WEATHER_DIR"]).expanduser()
        if os.environ.get("DOT_WEATHER_DIR") else None,
        script_dir,
    ]
    for candidate in candidates:
        if candidate and (candidate / "config.py").is_file() \
                and (candidate / "qweather.py").is_file():
            return candidate.resolve()
    raise FileNotFoundError(
        "找不到 dot-weather_push：请把本脚本复制进该目录，"
        "或通过 --project-dir / DOT_WEATHER_DIR 指定路径。"
        "（只想预览卡片排版的话，直接用 --sample，无需该项目。）")


def load_config(project: Path) -> Any:
    """Import the project's config, putting it on sys.path first."""
    if str(project) not in sys.path:
        sys.path.insert(0, str(project))
    import config  # type: ignore
    return config


def load_qweather(project: Path) -> Any:
    """Import the project's QWeather client.

    Takes `project` even though load_config has usually already extended
    sys.path: relying on that having happened first was an ordering dependency
    that nothing in the signatures revealed.
    """
    if str(project) not in sys.path:
        sys.path.insert(0, str(project))
    import qweather  # type: ignore
    return qweather


def wants_secondary(
    config: Any,
    force_dual: bool,
    force_single: bool,
) -> bool:
    return not force_single and (
        force_dual or bool(getattr(config, "HAS_SECONDARY", False)))


def refresh_interval_seconds(moment: dt.datetime) -> int:
    """Match dot-weather_push's commute-first request schedule."""
    hour = moment.hour
    if 7 <= hour <= 9 or 17 <= hour <= 20:
        return 5 * 60
    if 10 <= hour <= 16:
        return 10 * 60
    if 21 <= hour <= 23:
        return 20 * 60
    return 2 * 60 * 60


def cache_path(project: Path) -> Path:
    override = os.environ.get("MACTR_WEATHER_CACHE")
    if override:
        return Path(override).expanduser()
    return project / "out" / CACHE_FILE


def cache_fingerprint(config: Any, include_secondary: bool) -> str:
    values = [
        str(getattr(config, "LON", "")),
        str(getattr(config, "LAT", "")),
        str(getattr(config, "LOCATION_NAME", "")),
    ]
    if include_secondary:
        values.extend([
            str(getattr(config, "LON2", "")),
            str(getattr(config, "LAT2", "")),
            str(getattr(config, "LOCATION_NAME2", "")),
        ])
    return "|".join(values)


def read_cache(path: Path, fingerprint: str) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("fingerprint") != fingerprint:
            return None
        if not isinstance(value.get("output"), str) or not value["output"].strip():
            return None
        float(value["fetched_at"])
        return value
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None


def cache_age_seconds(cache: dict[str, Any], now: dt.datetime) -> float:
    return now.timestamp() - float(cache["fetched_at"])


def cache_is_fresh(
    cache: dict[str, Any],
    now: dt.datetime,
    interval_seconds: int,
) -> bool:
    age = cache_age_seconds(cache, now)
    # The same 30-second tolerance used by the original launchd wrapper avoids
    # skipping an entire boundary because timer delivery was slightly early.
    return 0 <= age < max(interval_seconds - 30, 1)


def cache_is_usable_fallback(cache: dict[str, Any], now: dt.datetime) -> bool:
    """Whether a failed refresh may fall back to this cache.

    Bounded so a broken setup surfaces as an error instead of leaving MacTR
    displaying a green, days-old card forever.
    """
    return 0 <= cache_age_seconds(cache, now) <= MAX_CACHE_AGE_SECONDS


def write_cache(
    path: Path,
    fingerprint: str,
    output: str,
    now: dt.datetime,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Unique per process: two overlapping runs (MacTR's timer plus a manual
    # "Run now") sharing one temp name could interleave their writes.
    temporary = path.with_suffix(f"{path.suffix}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(
                {
                    "fetched_at": now.timestamp(),
                    "fingerprint": fingerprint,
                    "output": output,
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _call_with_timeout(function: Any, args: tuple, timeout: float) -> Any:
    """Run `function` on a daemon thread and give up after `timeout`.

    A daemon thread rather than ThreadPoolExecutor: the executor's workers are
    joined during interpreter shutdown, so one hung HTTP call would keep this
    process alive past MacTR's kill deadline — exactly the case the cache
    fallback exists to cover.
    """
    outcome: dict[str, Any] = {}

    def run() -> None:
        try:
            outcome["value"] = function(*args)
        except BaseException as error:  # noqa: BLE001 - re-raised on the caller
            outcome["error"] = error

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    thread.join(timeout)
    if thread.is_alive():
        raise TimeoutError(f"天气接口 {timeout:.0f}s 内未返回")
    if "error" in outcome:
        raise outcome["error"]
    return outcome["value"]


def fetch_nowcasts(
    config: Any,
    qweather: Any,
    use_sample: bool,
    force_dual: bool,
    force_single: bool,
    timeout: float = REQUEST_TIMEOUT_SECONDS,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    want_secondary = wants_secondary(config, force_dual, force_single)
    if use_sample:
        primary = sample_nowcast()
        secondary = sample_nowcast_secondary() if want_secondary else None
        return primary, secondary

    if qweather is None:
        raise RuntimeError("未加载和风天气客户端")
    if not want_secondary:
        primary = _call_with_timeout(
            qweather.fetch_nowcast, (config.LON, config.LAT), timeout)
        return primary, None

    # Both locations share one deadline, so a slow first request cannot push
    # the pair past MacTR's timeout.
    results: dict[str, Any] = {}
    errors: dict[str, BaseException] = {}

    def fetch(key: str, lon: Any, lat: Any) -> None:
        try:
            results[key] = qweather.fetch_nowcast(lon, lat)
        except BaseException as error:  # noqa: BLE001 - reported below
            errors[key] = error

    threads = [
        threading.Thread(
            target=fetch, args=("primary", config.LON, config.LAT), daemon=True),
        threading.Thread(
            target=fetch, args=("secondary", config.LON2, config.LAT2), daemon=True),
    ]
    for thread in threads:
        thread.start()
    deadline = dt.datetime.now().timestamp() + timeout
    for thread in threads:
        thread.join(max(0.0, deadline - dt.datetime.now().timestamp()))

    if "primary" in errors:
        raise errors["primary"]
    if "primary" not in results:
        raise TimeoutError(f"天气接口 {timeout:.0f}s 内未返回")
    # A missing secondary degrades to a single-location card rather than
    # failing the whole run.
    return results["primary"], results.get("secondary")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="输出适合 MacTR 自定义卡片的分钟级降水信息")
    parser.add_argument(
        "--sample", action="store_true",
        help="使用内置样例数据，无需 dot-weather_push")
    parser.add_argument("--dual", action="store_true", help="强制显示双地点")
    parser.add_argument("--single", action="store_true", help="只显示主地点")
    parser.add_argument("--force", action="store_true", help="忽略缓存，立即请求")
    parser.add_argument("--project-dir", help="dot-weather_push 目录")
    return parser.parse_args(argv)


def run_sample(args: argparse.Namespace) -> int:
    """Render fixture data. Deliberately touches neither config nor the cache."""
    secondary = sample_nowcast_secondary() if not args.single else None
    lines = card_lines(
        sample_nowcast(),
        SAMPLE_LOCATION,
        secondary,
        SAMPLE_LOCATION_SECONDARY if secondary is not None else "",
    )
    print("\n".join(lines))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.sample:
        return run_sample(args)

    cached: dict[str, Any] | None = None
    now = dt.datetime.now().astimezone()

    def emit_cached_and_exit(_signum: int, _frame: Any) -> None:
        """Hand back the last good card when MacTR's timeout SIGTERMs us.

        Without this the process dies before the except branch below runs and
        MacTR shows its red error state even though a usable card was on disk.
        """
        if cached is not None and cache_is_usable_fallback(cached, now):
            sys.stdout.write(cached["output"] + "\n")
            sys.stdout.flush()
            os._exit(0)
        os._exit(1)

    signal.signal(signal.SIGTERM, emit_cached_and_exit)

    try:
        project = locate_project(args.project_dir)
        config = load_config(project)
        include_secondary = wants_secondary(config, args.dual, args.single)
        fingerprint = cache_fingerprint(config, include_secondary)
        destination = cache_path(project)
        cached = read_cache(destination, fingerprint)
        now = dt.datetime.now().astimezone()
        force = args.force or os.environ.get("MACTR_WEATHER_FORCE") == "1"

        if not force and cached is not None \
                and cache_is_fresh(
                    cached, now, refresh_interval_seconds(now)):
            print(cached["output"])
            return 0

        qweather = load_qweather(project)
        primary, secondary = fetch_nowcasts(
            config,
            qweather,
            use_sample=False,
            force_dual=args.dual,
            force_single=args.single,
        )
        lines = card_lines(
            primary,
            str(config.LOCATION_NAME),
            secondary,
            str(config.LOCATION_NAME2) if secondary is not None else "",
        )
        output = "\n".join(lines)
        write_cache(destination, fingerprint, output, now)
        print(output)
        return 0
    except Exception as error:
        # A stale real-weather card beats replacing the display with an error,
        # and its embedded update time makes the age visible — but only up to
        # MAX_CACHE_AGE_SECONDS. Beyond that, failing is the honest answer:
        # otherwise an expired API key leaves a green card from days ago.
        if cached is not None and cache_is_usable_fallback(cached, now):
            print(cached["output"])
            print(
                "天气刷新失败，正在显示缓存: "
                f"{type(error).__name__}: {redact(error)}",
                file=sys.stderr,
            )
            return 0
        print(
            f"天气获取失败: {type(error).__name__}: {redact(error)}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
