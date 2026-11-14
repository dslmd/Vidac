#!/usr/bin/env python3
"""测试用：冒充 bin/apple-translate（Swift 小工具），协议相同。

环境变量 FAKE_APPLE_MODE：
  ok（默认）  --check 返回 0；翻译时对每个带编号的行输出 `编号: 中文<原文>`
  disabled    一律返回 2，stderr 写原因（模拟没开 Apple Intelligence）
  legacy_not_ready / not_eligible   同上，另外两种原因
  refuse_big  一批超过 2 行时返回 3（模拟被拒绝或超长），用来测拆小重试
"""
import json
import os
import re
import sys

mode = os.environ.get("FAKE_APPLE_MODE", "ok")
if mode == "disabled":
    sys.stderr.write("[not-enabled] Apple Intelligence is turned off (enable it in System Settings)\n")
    sys.exit(2)
if mode == "legacy_not_ready":   # 0.5 的小工具：只有原因，没有代码
    sys.stderr.write("The Apple Intelligence model has not finished downloading\n")
    sys.exit(2)
if mode == "not_eligible":
    sys.stderr.write("[not-eligible] This Mac does not support Apple Intelligence\n")
    sys.exit(2)
if "--check" in sys.argv:
    print("ok")
    sys.exit(0)
try:
    req = json.loads(sys.stdin.read())
    prompt = req["prompt"]
    req["instructions"]
except (ValueError, KeyError):
    sys.stderr.write("输入不是合法的 JSON\n")
    sys.exit(4)
lines = re.findall(r"^(\d+): (.*)$", prompt, re.M)
if mode == "refuse_big" and len(lines) > 2:
    sys.stderr.write("生成失败：guardrailViolation\n")
    sys.exit(3)
log = os.environ.get("FAKE_APPLE_LOG")
if log:
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"n": len(lines), "instructions": req["instructions"]},
                            ensure_ascii=False) + "\n")
for num, text in lines:
    print(f"{num}: 中文{text}")
