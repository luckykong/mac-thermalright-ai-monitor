# MacTR 天气自定义卡片

把 `dot-weather_push` 的和风天气临近预报，转成 MacTR 自定义卡片所需的纯文本：

- `mactr_weather.sh`：在 MacTR 中选择的入口。
- `mactr_weather.py`：读取天气、压缩趋势并排版。

## 先看效果（不需要任何外部项目）

```bash
python3 mactr_weather.py --sample --dual
```

样例数据内置在脚本里，从仓库直接 clone 出来就能预览卡片排版。

## 接真实数据

把两个文件复制到 `dot-weather_push` 根目录，与 `config.py`、`qweather.py`
放在一起（不再需要 `sample_data.py`）；也可以放在别处，用 `--project-dir`
或环境变量 `DOT_WEATHER_DIR` 指向该目录。脚本会复用原有地点、双地点设置
及和风认证，但不会生成 PNG、调用 DeepSeek 或向 Dot. 墨水屏推送。

```bash
./mactr_weather.sh          # MacTR 实际调用的方式
python3 mactr_weather.py --force   # 忽略缓存立刻请求
```

需要指定解释器（例如装了依赖的 conda 环境）时，设置
`MACTR_WEATHER_PYTHON=/path/to/python`。

## 刷新与容错

MacTR 每 5 分钟调用一次入口；脚本内部沿用原项目的时段节流：早晚高峰 5 分钟、
白天 10 分钟、夜间 20 分钟、凌晨 2 小时。未到刷新时间就直接输出
`out/mactr_weather_cache.json` 里的上次结果，不重复打接口。

请求失败时会退回缓存，**但最多 6 小时**。超过这个时长就返回非零退出码，让
MacTR 显示错误状态 —— 否则一个过期的 API key 会让屏幕一直挂着几天前的卡片，
而且状态还是绿色的。卡片首行的更新时间同样能看出数据新旧。

单次请求限时 10 秒，小于 MacTR 的 30 秒超时；即使 MacTR 抢先发来 SIGTERM，
脚本也会先把缓存内容输出再退出。

诊断信息一律走 stderr，不会混进卡片正文；异常消息里的 `key=` 等凭据会被打码，
避免出现在实体屏幕上。

## 在 MacTR 中启用

1. 进入“设置 → 自定义卡片”。
2. 开启“显示自定义脚本输出”。
3. 脚本选择 `mactr_weather.sh`。
4. 卡片名称填写“天气”。
5. 循环间隔建议填写 `300` 秒。
6. 点击“立即运行”检查输出。

MacTR 自己负责循环执行，不需要为这个入口另建 launchd 任务。

## 测试

```bash
python3 -m unittest test_mactr_weather
```
