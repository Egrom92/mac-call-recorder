#!/usr/bin/env python3
"""Тестовый сервер CRM: имитирует прямой эфир (POST /api/live/chunk, /api/live/end — протокол docs/LIVE.md)
и приём записей (POST /api/inbox?folder=&file=, /api/inbox/done?folder= — протокол docs/INBOX.md).

Звук каждой дорожки дописывает в <out>/<track>.pcm, журнал запросов — в <out>/requests.log
(строки: путь track seq размер код). Нарочно отвечает 503 на первую попытку куска seq=2 дорожки me,
чтобы проверить повтор. С --close-after N отвечает 409 на куски с seq >= N (разговор закрыт). Записи сохраняет в <out>/inbox/<папка>/,
с --fail-inbox отвечает 503 на загрузку файлов.

Журнал ошибок (POST /api/logs — протокол docs/LOGS.md): принятые строки дописывает в <out>/logs.jsonl, повторы по id
не пишет второй раз, строки не JSON или без id называет в rejected. С --logs-fail N отвечает 503 на первые N пачек,
с --logs-max-lines K — 413 на пачки длиннее K строк, с --logs-garbage — 200 со страницей вместо JSON.
"""
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "test-token"

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--close-after", type=int)
parser.add_argument("--fail-inbox", action="store_true")
parser.add_argument("--logs-fail", type=int, default=0)
parser.add_argument("--logs-max-lines", type=int)
parser.add_argument("--logs-garbage", action="store_true")
args = parser.parse_args()
os.makedirs(args.out, exist_ok=True)
last = {"me": -1, "them": -1}
failed_once = False
# id уже принятых событий — и после перезапуска имитатора, как у настоящего сервера.
log_ids = {json.loads(l)["id"] for l in open(os.path.join(args.out, "logs.jsonl"), encoding="utf-8")} \
    if os.path.exists(os.path.join(args.out, "logs.jsonl")) else set()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        global failed_once
        url = urlparse(self.path)
        q = parse_qs(url.query)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if url.path == "/api/logs":
            return self.logs(body)
        track, seq = q.get("track", [""])[0], int(q.get("seq", ["-1"])[0])
        code = 200
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            code = 403
        elif url.path == "/api/live/end":
            code = 200
        elif url.path in ("/api/inbox", "/api/inbox/done"):
            folder = q.get("folder", [""])[0]
            target = os.path.join(args.out, "inbox", folder)
            if not folder or folder.startswith((".", "_")) or "/" in folder:
                code = 400
            elif url.path == "/api/inbox/done":
                os.makedirs(target, exist_ok=True)
                open(os.path.join(target, ".ready"), "w").close()
            elif args.fail_inbox:
                code = 503
            else:
                os.makedirs(target, exist_ok=True)
                with open(os.path.join(target, q.get("file", ["?"])[0]), "wb") as f:
                    f.write(body)
        elif url.path != "/api/live/chunk" or track not in last or seq < 0 or not body:
            code = 400
        elif track == "me" and seq == 2 and not failed_once:
            failed_once, code = True, 503
        elif args.close_after is not None and seq >= args.close_after:
            code = 409
        elif seq > last[track]:
            last[track] = seq
            with open(os.path.join(args.out, f"{track}.pcm"), "ab") as f:
                f.write(body)
        with open(os.path.join(args.out, "requests.log"), "a") as f:
            f.write(f"{url.path} {track or '-'} {seq} {len(body)} {code} {q.get('session', q.get('folder', ['']))[0]} {q.get('file', ['-'])[0]}\n")
        self.reply(code, {"ok": code == 200})

    def logs(self, body):
        lines = body.decode("utf-8", "replace").split("\n")
        count = len([l for l in lines if l.strip()])
        out = {"ok": True, "accepted": 0, "duplicates": 0, "rejected": []}
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            code, out = 403, {"ok": False}
        elif args.logs_fail > 0:
            args.logs_fail -= 1
            code, out = 503, {"ok": False}
        elif args.logs_max_lines is not None and count > args.logs_max_lines:
            code, out = 413, {"ok": False}
        else:
            code = 200
            for i, line in enumerate(lines, 1):
                if not line.strip():
                    continue
                try:
                    e = json.loads(line)
                    assert isinstance(e, dict) and isinstance(e.get("id"), str) and len(e["id"]) >= 8
                except Exception:
                    out["rejected"].append({"line": i, "error": "не JSON или нет id"})
                    continue
                if e["id"] in log_ids:
                    out["duplicates"] += 1
                    continue
                log_ids.add(e["id"])
                out["accepted"] += 1
                with open(os.path.join(args.out, "logs.jsonl"), "a", encoding="utf-8") as f:
                    f.write(line.strip() + "\n")
        with open(os.path.join(args.out, "requests.log"), "a") as f:
            f.write(f"/api/logs lines={count} bytes={len(body)} code={code} accepted={out.get('accepted', 0)} "
                    f"duplicates={out.get('duplicates', 0)} rejected={len(out.get('rejected', []))}\n")
        if code == 200 and args.logs_garbage:
            data = b"<html>CRM</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.reply(code, out)

    def log_message(self, *_):
        pass


ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
