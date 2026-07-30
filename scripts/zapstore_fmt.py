import sys, json
n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    n += 1
    d = ver = size = ""
    urls = []
    for t in e.get("tags", []):
        key = t[0]
        val = t[1] if len(t) > 1 else ""
        if key == "d":
            d = val
        elif key == "version":
            ver = val
        elif key == "url":
            urls.append(val)
        elif key == "size":
            size = val
    eid = e.get("id", "")[:12]
    print("  id=%s created=%s d=%s version=%s size=%s" % (eid, e.get("created_at"), d, ver, size))
    for u in urls:
        print("    url: " + u)
if n == 0:
    print("  (nenhum evento)")
