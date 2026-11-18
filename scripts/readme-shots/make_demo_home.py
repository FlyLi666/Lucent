#!/usr/bin/env python3
"""README 截图用的假家目录：Claude Code 150 天、Antigravity 40 天、Grok Build 25 天。
项目名全是通用名，路径用 /Users/demo。JSON 一律紧凑写（Lucent 按字节预筛）。
用法：make_demo_home.py <输出目录>
"""
import json, os, random, sys, uuid, shutil, urllib.parse
from datetime import datetime, timedelta, timezone

out = sys.argv[1]
shutil.rmtree(out, ignore_errors=True)
rng = random.Random(42)
now = datetime.now(timezone.utc)
dump = lambda o: json.dumps(o, separators=(",", ":"))
PROJECTS = ["web-app", "api-server", "lucent", "docs-site", "ml-pipeline", "mobile-app"]
PW = [30, 22, 18, 12, 10, 8]

def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"

def day_weight(d):
    # 越近越多，周末少；近 24 小时按「白天多、深夜少」分布
    age = (now - d).days
    w = 1.0 + max(0, 60 - age) / 40
    if d.weekday() >= 5:
        w *= 0.45
    return w

def sessions(days, per_day, active_hours=(9, 24)):
    """生成 (开始时间, 项目, 请求数) 的会话列表，覆盖最近 days 天（含刚过去的 24 小时）"""
    res = []
    for age in range(days, -1, -1):
        day = (now - timedelta(days=age)).replace(hour=0, minute=0, second=0, microsecond=0)
        if age > 3 and rng.random() < 0.12:
            continue  # 偶尔整天不用，热力图有空格
        n = int(per_day * day_weight(day) * rng.uniform(0.5, 1.4))
        while n > 0:
            k = min(n, rng.randint(15, 70))
            h = rng.uniform(*active_hours) if rng.random() < 0.9 else rng.uniform(0, 3)
            start = day + timedelta(hours=h)
            if start > now - timedelta(minutes=20):
                start = now - timedelta(minutes=rng.uniform(25, 600))
            res.append((start, rng.choices(PROJECTS, PW)[0], k))
            n -= k
    return res

# ---------- Claude Code ----------
cl_models = [("claude-opus-5-5", 70), ("claude-sonnet-5-5", 22), ("claude-haiku-5-5", 8)]
cl_count = 0
for start, proj, k in sessions(150, 140):
    cwd = f"/Users/demo/code/{proj}"
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    d = os.path.join(out, ".claude/projects", cwd.replace("/", "-"))
    os.makedirs(d, exist_ok=True)
    model = rng.choices([m for m, _ in cl_models], [w for _, w in cl_models])[0]
    t = start
    ctx = rng.randint(18000, 40000)
    with open(os.path.join(d, sid + ".jsonl"), "a") as f:
        for _ in range(k):
            out_tok = int(rng.lognormvariate(6.0, 0.8))
            t += timedelta(seconds=out_tok / rng.uniform(55, 95) + rng.uniform(2, 25))
            if t > now:
                break
            write = rng.randint(150, 2500)
            ctx = min(ctx + write, 190000)
            f.write(dump({
                "parentUuid": None, "isSidechain": False, "type": "assistant",
                "timestamp": iso(t), "sessionId": sid, "cwd": cwd, "version": "2.1.0",
                "requestId": "req_" + uuid.UUID(int=rng.getrandbits(128)).hex[:24],
                "uuid": str(uuid.UUID(int=rng.getrandbits(128))),
                "message": {
                    "id": "msg_" + uuid.UUID(int=rng.getrandbits(128)).hex[:24],
                    "type": "message", "role": "assistant", "model": model,
                    "stop_reason": "end_turn" if rng.random() < 0.3 else "tool_use",
                    "usage": {
                        "input_tokens": rng.randint(1, 8),
                        "cache_creation_input_tokens": write,
                        "cache_read_input_tokens": ctx,
                        "output_tokens": out_tok,
                        "cache_creation": {"ephemeral_5m_input_tokens": write, "ephemeral_1h_input_tokens": 0},
                    },
                },
            }) + "\n")
            cl_count += 1

# ---------- Antigravity (CLI) ----------
ag_models = [("gemini-4-carbon-high", 45), ("gemini-4-hydrogen-xhigh", 30), ("gemini-4-argon-high", 10), ("gemini-3.8-flash-high", 15)]
ag_count = 0
for start, proj, k in sessions(40, 40):
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    d = os.path.join(out, ".gemini/antigravity-cli/brain", sid, ".system_generated/logs")
    os.makedirs(d, exist_ok=True)
    model = rng.choices([m for m, _ in ag_models], [w for _, w in ag_models])[0]
    t = start
    step = 0
    with open(os.path.join(d, "transcript_full.jsonl"), "w") as f:
        f.write(dump({"step_index": step, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE",
                      "created_at": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "content": "demo"}) + "\n")
        ctx = rng.randint(9000, 20000)
        for _ in range(k):
            step += 1
            out_tok = int(rng.lognormvariate(5.6, 0.9))
            t += timedelta(seconds=out_tok / 60 + rng.uniform(3, 20))
            if t > now:
                break
            ctx = min(ctx + rng.randint(300, 2500), 400000)
            cached = int(ctx * rng.uniform(0.6, 0.9))
            f.write(dump({"step_index": step, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
                          "created_at": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "model": model,
                          "input_tokens": ctx - cached, "cache_read_tokens": cached, "output_tokens": out_tok}) + "\n")
            ag_count += 1

# ---------- Grok Build ----------
gk_count = 0
for start, proj, k in sessions(25, 60):
    cwd = f"/Users/demo/code/{proj}"
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    d = os.path.join(out, ".grok/sessions", urllib.parse.quote(cwd, safe=""), sid)
    os.makedirs(d, exist_ok=True)
    model = "grok-4.7-build-fast" if rng.random() < 0.7 else "grok-4.7-build"
    t = start
    with open(os.path.join(d, "updates.jsonl"), "w") as f:
        for i in range(max(1, k // 10)):
            calls = rng.randint(4, 20)
            inp = rng.randint(80000, 700000)
            cached = int(inp * rng.uniform(0.7, 0.9))
            outp = rng.randint(3000, 25000)
            ms = int(outp / rng.uniform(60, 110) * 1000)
            t += timedelta(milliseconds=ms + rng.randint(20000, 200000))
            if t > now:
                break
            u = {"inputTokens": inp, "outputTokens": outp, "totalTokens": inp + outp, "cachedReadTokens": cached,
                 "cacheCreationTokens": 0, "reasoningTokens": int(outp * 0.8), "modelCalls": calls, "apiDurationMs": ms,
                 "costUsdTicks": int(((inp - cached) * 2.0 + cached * 0.5 + outp * 10.0) * 1e4)}
            f.write(dump({"timestamp": int(t.timestamp()), "method": "_x.ai/session/update",
                          "params": {"sessionId": sid, "update": {"sessionUpdate": "turn_completed",
                                     "prompt_id": str(uuid.UUID(int=rng.getrandbits(128))), "stop_reason": "end_turn",
                                     "usage": dict(u, modelUsage={model: dict(u)}, numTurns=calls), "elapsed_ms": ms + 9000},
                                     "_meta": {"eventId": sid[:8] + str(i), "agentTimestampMs": int(t.timestamp() * 1000)}}}) + "\n")
            gk_count += 1

print(f"claude={cl_count} antigravity={ag_count} grok={gk_count} -> {out}")
