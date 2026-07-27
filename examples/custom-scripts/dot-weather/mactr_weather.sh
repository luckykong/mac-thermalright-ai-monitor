#!/bin/zsh
# MacTR custom-card entry point for dot-weather_push.

set -eu

SCRIPT_DIR="${0:A:h}"
export DOT_WEATHER_DIR="${DOT_WEATHER_DIR:-${SCRIPT_DIR}}"

# Set MACTR_WEATHER_PYTHON to pick a specific interpreter, e.g. a virtualenv or
# conda environment that has the dot-weather_push dependencies installed.
if [[ -n "${MACTR_WEATHER_PYTHON:-}" ]]; then
  PYTHON="${MACTR_WEATHER_PYTHON}"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  print -u2 "天气获取失败: 找不到 Python 3（可用 MACTR_WEATHER_PYTHON 指定解释器）"
  exit 1
fi

exec "${PYTHON}" "${SCRIPT_DIR}/mactr_weather.py" "$@"
