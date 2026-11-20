# Stand-in Squadd companion for the real-push run (scripts/pr-ios-push.yml): the agent and thread the recorded push names.
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BOTS = {"bots": [{"id": "c813261f-bd3e-4d86-909c-27416feff813", "name": "Finch",
                  "threadId": "6f85c7af-a71e-487f-8072-abd6b0765715",
                  "tasks": [{"threadId": "t-menu", "title": "Weekly menu", "updatedAt": 1795112300000}]}]}
# The thread the push names: the ask and the reply that made the computer send "Finch finished".
MESSAGES = {"hasMore": False, "messages": [
    {"id": "m1", "role": "user", "kind": "text", "text": "Plan next week's dinners, vegetarian, under 30 minutes each.",
     "at": 1795112000000},
    {"id": "m2", "role": "bot", "kind": "text", "at": 1795112300000,
     "text": "Done. Five dinners are in Weekly menu: lentil curry, halloumi wraps, mushroom risotto, "
             "chickpea shakshuka and pesto gnocchi, with one shopping list."}]}
with open("HermesMobileTests/Fixtures/Squadd/push-device-registered.json") as f:
    DEVICE = json.load(f)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'id: s:1\ndata: {"kind":"hello","cursor":"s:1","resumed":false,"seq":1}\n\n')
            return
        if path == "/api/threads/6f85c7af-a71e-487f-8072-abd6b0765715/messages":
            path = "messages"
        body = {"/api/bots": BOTS, "/api/push/device": DEVICE, "messages": MESSAGES}.get(path)
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body or {}).encode())

    do_PUT = do_POST = do_DELETE = do_GET


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
