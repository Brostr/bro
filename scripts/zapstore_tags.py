import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    print("--- event", e.get("id", "")[:12], "kind", e.get("kind"), "created", e.get("created_at"))
    for t in e.get("tags", []):
        print("   ", t)
