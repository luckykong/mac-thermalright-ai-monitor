# MacTR 天气自定义卡片

这两个文件把现有 `dot-weather_push` 的和风天气临近预报改成 MacTR
自定义卡片所需的纯文本输出：

- `mactr_weather.sh`：在 MacTR 中选择的入口。
- `mactr_weather.py`：读取天气、压缩趋势并排版。

把两个文件复制到 `dot-weather_push` 根目录，与 `config.py`、`qweather.py`
和 `sample_data.py` 放在一起。脚本会复用原有地点、双地点设置及和风认证，
但不会生成 PNG、调用 DeepSeek 或向 Dot. 墨水屏推送。

MacTR 每 5 分钟调用入口；程序内部沿用原项目的时段节流：早晚高峰 5 分钟、
白天 10 分钟、夜间 20 分钟、凌晨 2 小时。未到刷新时间时直接输出
`out/mactr_weather_cache.json` 中的上次结果，不重复请求接口。真实请求失败时
也会保留缓存；卡片首行的更新时间可以看出数据是否陈旧。

先在终端测试：

```bash
./mactr_weather.sh
python3 mactr_weather.py --sample --dual
python3 mactr_weather.py --force
```

然后打开 MacTR：

1. 进入“设置 → 自定义卡片”。
2. 开启“显示自定义脚本输出”。
3. 脚本选择 `mactr_weather.sh`。
4. 卡片名称填写“天气”。
5. 循环间隔建议填写 `300` 秒。
6. 点击“立即运行”检查输出。

MacTR 自己负责循环执行，因此不需要为这个入口另建 launchd 任务。脚本执行失败
时返回非零状态，MacTR 会保留上一次成功的天气内容并显示错误状态。
