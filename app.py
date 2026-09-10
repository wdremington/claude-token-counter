from flask import Flask, jsonify, render_template
import json
import os
from pathlib import Path
from collections import defaultdict

app = Flask(__name__)

# Pricing per million tokens (Anthropic first-party rates)
PRICING = {
    "claude-fable-5-1":  {"input": 10.0, "output": 50.0},
    "claude-mythos-5-1": {"input": 10.0, "output": 50.0},
    "claude-fable-5":    {"input": 10.0, "output": 50.0},
    "claude-mythos-5":   {"input": 10.0, "output": 50.0},
    "claude-opus-5":     {"input": 5.0,  "output": 25.0},
    "claude-opus-4-8":   {"input": 5.0,  "output": 25.0},
    "claude-opus-4-7":   {"input": 5.0,  "output": 25.0},
    "claude-opus-4-6":   {"input": 5.0,  "output": 25.0},
    "claude-sonnet-5":   {"input": 2.0,  "output": 10.0},
    "claude-sonnet-4-6": {"input": 3.0,  "output": 15.0},
    "claude-haiku-4-5":  {"input": 1.0,  "output": 5.0},
    "claude-haiku-4-5-20251001": {"input": 1.0,  "output": 5.0},
}

# Cache pricing multipliers relative to base input price
CACHE_WRITE_MULT = 1.25
CACHE_READ_MULT  = 0.10


def model_pricing(model: str):
    if model in PRICING:
        return PRICING[model]
    for key in PRICING:
        if model.startswith(key):
            return PRICING[key]
    return None


def message_cost(usage: dict, pricing: dict) -> float:
    if not pricing:
        return 0.0
    per_m = pricing["input"] / 1_000_000
    cost = (
        usage.get("input_tokens", 0) * per_m +
        usage.get("cache_creation_input_tokens", 0) * per_m * CACHE_WRITE_MULT +
        usage.get("cache_read_input_tokens", 0) * per_m * CACHE_READ_MULT +
        usage.get("output_tokens", 0) * (pricing["output"] / 1_000_000)
    )
    return cost


def empty_model_bucket() -> dict:
    return {
        "input_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "output_tokens": 0,
        "thinking_tokens": 0,
        "cost": 0.0,
        "messages": 0,
    }


def project_label(cwd: str) -> str:
    """Return a readable label from a CWD string (last two path segments)."""
    if not cwd:
        return "unknown"
    parts = [p for p in cwd.rstrip("/").split("/") if p]
    return "/".join(parts[-2:]) if len(parts) >= 2 else parts[-1] if parts else cwd


def load_stats() -> dict:
    projects_dir = Path.home() / ".claude" / "projects"

    by_model: dict[str, dict] = defaultdict(empty_model_bucket)
    by_day: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    by_project: dict[str, dict[str, dict]] = defaultdict(lambda: defaultdict(empty_model_bucket))

    date_min = date_max = None
    total_messages = 0
    unknown_models: set[str] = set()

    if not projects_dir.exists():
        return _empty_response()

    for jsonl_path in projects_dir.rglob("*.jsonl"):
        try:
            with open(jsonl_path, encoding="utf-8") as fh:
                for raw in fh:
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        entry = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    if entry.get("type") != "assistant":
                        continue
                    if entry.get("isApiErrorMessage"):
                        continue

                    message = entry.get("message") or {}
                    model = message.get("model") or ""
                    if not model or model == "<synthetic>":
                        continue

                    usage = message.get("usage") or {}
                    total_tok = (
                        usage.get("input_tokens", 0) +
                        usage.get("output_tokens", 0) +
                        usage.get("cache_creation_input_tokens", 0) +
                        usage.get("cache_read_input_tokens", 0)
                    )
                    if total_tok == 0:
                        continue

                    pricing = model_pricing(model)
                    if pricing is None:
                        unknown_models.add(model)
                    cost = message_cost(usage, pricing) if pricing else 0.0

                    thinking = (usage.get("output_tokens_details") or {}).get("thinking_tokens") or 0

                    # --- by model ---
                    b = by_model[model]
                    b["input_tokens"]           += usage.get("input_tokens", 0)
                    b["cache_creation_tokens"]  += usage.get("cache_creation_input_tokens", 0)
                    b["cache_read_tokens"]      += usage.get("cache_read_input_tokens", 0)
                    b["output_tokens"]          += usage.get("output_tokens", 0)
                    b["thinking_tokens"]        += thinking
                    b["cost"]                   += cost
                    b["messages"]               += 1

                    # --- by project ---
                    cwd = entry.get("cwd") or ""
                    label = project_label(cwd)
                    pb = by_project[label][model]
                    pb["input_tokens"]          += usage.get("input_tokens", 0)
                    pb["cache_creation_tokens"] += usage.get("cache_creation_input_tokens", 0)
                    pb["cache_read_tokens"]     += usage.get("cache_read_input_tokens", 0)
                    pb["output_tokens"]         += usage.get("output_tokens", 0)
                    pb["cost"]                  += cost
                    pb["messages"]              += 1

                    # --- by day ---
                    ts = entry.get("timestamp") or ""
                    if ts:
                        day = ts[:10]
                        by_day[day][model] += cost
                        if date_min is None or day < date_min:
                            date_min = day
                        if date_max is None or day > date_max:
                            date_max = day

                    total_messages += 1

        except Exception:
            continue

    total_cost = sum(b["cost"] for b in by_model.values())

    return {
        "models": {k: dict(v) for k, v in by_model.items()},
        "daily": {day: dict(costs) for day, costs in sorted(by_day.items())},
        "projects": {proj: {m: dict(v) for m, v in models.items()} for proj, models in by_project.items()},
        "total_cost": round(total_cost, 6),
        "total_messages": total_messages,
        "date_range": [date_min, date_max],
        "unknown_models": sorted(unknown_models),
        "pricing": PRICING,
    }


def _empty_response() -> dict:
    return {
        "models": {},
        "daily": {},
        "projects": {},
        "total_cost": 0.0,
        "total_messages": 0,
        "date_range": [None, None],
        "unknown_models": [],
        "pricing": PRICING,
    }


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/stats")
def api_stats():
    return jsonify(load_stats())


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5123))
    print(f"  TokenCounter → http://localhost:{port}")
    app.run(debug=True, port=port)
