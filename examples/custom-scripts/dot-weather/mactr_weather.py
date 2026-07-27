#!/usr/bin/env python3
"""Render dot-weather_push nowcast data as MacTR custom-card text.

The script deliberately writes only the final card to stdout. Diagnostics go to
stderr and return a non-zero status so MacTR can retain the last successful
output. It reuses the existing dot-weather_push configuration and QWeather
client, but does not render a PNG, call DeepSeek, or push to another device.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Iterable


CARD_UNITS = 28
TREND_POINTS = 12
FULL_SCALE_MM = 1.2
CACHE_FILE = "mactr_weather_cache.json"

_RELATIVE_TIME = re.compile(
    r"(?:(?P<hours>\d+)\s*小时(?:\s*(?P<hour_minutes>\d+)\s*分钟)?"
    r"|(?P<after_minutes>\d+)\s*分钟)后"
    r"|持续\s*(?P<duration_minutes>\d+)\s*分钟"
)


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


def resample_max(values: Iterable[float], points: int = TREND_POINTS) -> list[float]:
    source = list(values)
    if not source:
        return [0.0] * points
    result: list[float] = []
    for index in range(points):
        start = int(index * len(source) / points)
        end = max(start + 1, int((index + 1) * len(source) / points))
        result.append(max(source[start:min(end, len(source))], default=0.0))
    return result


def trend_text(values: Iterable[float]) -> str:
    levels = "·▁▂▃▄▅▆▇█"
    chars: list[str] = []
    for value in resample_max(values):
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


def locate_project(explicit: str | None) -> Path:
    script_dir = Path(__file__).resolve().parent
    home = Path.home()
    candidates = [
        Path(explicit).expanduser() if explicit else None,
        Path(os.environ["DOT_WEATHER_DIR"]).expanduser()
        if os.environ.get("DOT_WEATHER_DIR") else None,
        script_dir,
        home / "Downloads" / "dot-weather_push",
        home / "Softwares" / "有用的脚本" / "dot-weather_push",
    ]
    for candidate in candidates:
        if candidate and (candidate / "config.py").is_file() \
                and (candidate / "qweather.py").is_file():
            return candidate.resolve()
    raise FileNotFoundError(
        "找不到 dot-weather_push；请把本脚本放入该目录，"
        "或设置 DOT_WEATHER_DIR。")


def load_base_modules(project: Path) -> tuple[Any, Any]:
    sys.path.insert(0, str(project))
    import config  # type: ignore
    import sample_data  # type: ignore
    return config, sample_data


def load_qweather() -> Any:
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


def cache_is_fresh(
    cache: dict[str, Any],
    now: dt.datetime,
    interval_seconds: int,
) -> bool:
    age = now.timestamp() - float(cache["fetched_at"])
    # The same 30-second tolerance used by the original launchd wrapper avoids
    # skipping an entire boundary because timer delivery was slightly early.
    return 0 <= age < max(interval_seconds - 30, 1)


def write_cache(
    path: Path,
    fingerprint: str,
    output: str,
    now: dt.datetime,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
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


def fetch_nowcasts(
    config: Any,
    qweather: Any,
    sample_data: Any,
    use_sample: bool,
    force_dual: bool,
    force_single: bool,
) -> tuple[dict[str, Any], dict[str, Any] | None]:
    want_secondary = wants_secondary(config, force_dual, force_single)
    if use_sample:
        primary = sample_data.sample_nowcast()
        secondary = sample_data.sample_nowcast_secondary() if want_secondary else None
        return primary, secondary

    if qweather is None:
        raise RuntimeError("未加载和风天气客户端")
    if want_secondary:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            primary_future = executor.submit(
                qweather.fetch_nowcast, config.LON, config.LAT)
            secondary_future = executor.submit(
                qweather.fetch_nowcast, config.LON2, config.LAT2)
            return primary_future.result(), secondary_future.result()
    return qweather.fetch_nowcast(config.LON, config.LAT), None


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="输出适合 MacTR 自定义卡片的分钟级降水信息")
    parser.add_argument("--sample", action="store_true", help="使用原项目样例数据")
    parser.add_argument("--dual", action="store_true", help="强制显示双地点样例")
    parser.add_argument("--single", action="store_true", help="只显示主地点")
    parser.add_argument("--force", action="store_true", help="忽略缓存，立即请求")
    parser.add_argument("--project-dir", help="dot-weather_push 目录")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    cached: dict[str, Any] | None = None
    try:
        project = locate_project(args.project_dir)
        config, sample_data = load_base_modules(project)
        include_secondary = wants_secondary(config, args.dual, args.single)
        fingerprint = cache_fingerprint(config, include_secondary)
        destination = cache_path(project)
        cached = read_cache(destination, fingerprint)
        now = dt.datetime.now().astimezone()
        force = args.force or os.environ.get("MACTR_WEATHER_FORCE") == "1"

        if not args.sample and not force and cached is not None \
                and cache_is_fresh(
                    cached, now, refresh_interval_seconds(now)):
            print(cached["output"])
            return 0

        qweather = None if args.sample else load_qweather()
        primary, secondary = fetch_nowcasts(
            config,
            qweather,
            sample_data,
            use_sample=args.sample,
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
        if not args.sample:
            write_cache(destination, fingerprint, output, now)
        print(output)
        return 0
    except Exception as error:
        # A stale real-weather card is safer than replacing the display with an
        # error. Its embedded update time makes the age visible. With no cache,
        # return a failure so MacTR can show its normal red error state.
        if not args.sample and cached is not None:
            print(cached["output"])
            return 0
        print(
            f"天气获取失败: {type(error).__name__}: {error}",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
