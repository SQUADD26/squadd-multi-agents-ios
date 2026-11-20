# Taps the element whose label contains `label` (default: Allow on the notification permission alert), for up to
# `seconds` (default 40 minutes). The real-push run of scripts/pr-ios-push.yml.
import json, subprocess, sys, time

udid = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else "Allow"
end = time.time() + (float(sys.argv[3]) if len(sys.argv) > 3 else 2400)
last_log = 0
while time.time() < end:
    out = subprocess.run(["idb", "ui", "describe-all", "--udid", udid, "--json"], capture_output=True, text=True)
    try:
        items = json.loads(out.stdout or "[]")
    except json.JSONDecodeError:
        items = []
    if time.time() - last_log > 30:
        last_log = time.time()
        print("seen:", [item.get("AXLabel") for item in items][:12], out.stderr.strip()[:200], flush=True)
    for item in items:
        if label == (item.get("AXLabel") or "") or (label != "Allow" and label in (item.get("AXLabel") or "")):
            f = item["frame"]
            x, y = int(f["x"] + f["width"] / 2), int(f["y"] + f["height"] / 2)
            subprocess.run(["idb", "ui", "tap", "--udid", udid, str(x), str(y)])
            print("tapped", repr(item.get("AXLabel")), "at", x, y, flush=True)
            sys.exit(0)
    time.sleep(1)
print("no", repr(label), "seen", flush=True)
sys.exit(1)
