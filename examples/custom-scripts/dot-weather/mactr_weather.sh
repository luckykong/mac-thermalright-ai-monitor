#!/bin/zsh
# MacTR custom-card entry point for dot-weather_push.

set -eu

SCRIPT_DIR="${0:A:h}"
export DOT_WEATHER_DIR="${DOT_WEATHER_DIR:-${SCRIPT_DIR}}"

if [[ -n "${MACTR_WEATHER_PYTHON:-}" ]]; then
  PYTHON="${MACTR_WEATHER_PYTHON}"
elif [[ -x "${HOME}/Softwares/miniconda3/envs/smallProjects/bin/python" ]]; then
  PYTHON="${HOME}/Softwares/miniconda3/envs/smallProjects/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  print -u2 "天气获取失败: 找不到 Python 3"
  exit 1
fi

exec "${PYTHON}" "${SCRIPT_DIR}/mactr_weather.py" "$@"
