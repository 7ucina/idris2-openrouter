"""A stand-in for OpenRouter on http://127.0.0.1:8787/api/v1, for the client tests.
The model name picks the behavior. Run: python3 test/mock.py [port]"""
import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

seen = {}
lock = threading.Lock()
KEYS, FILES, BATCHES, VIDEOS = {}, {}, {}, {}   # what the management endpoints remember

def nth(key):
    with lock:
        seen[key] = seen.get(key, 0) + 1
        return seen[key]

def reply(model, text, finish="stop", calls=None):
    msg = {"role": "assistant", "content": text if calls is None else None}
    if calls: msg["tool_calls"] = calls
    return {"id": "gen-mock-1", "provider": "Mock", "model": model, "object": "chat.completion", "created": 1,
            "choices": [{"index": 0, "finish_reason": finish, "native_finish_reason": finish, "message": msg}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10, "cost": 0.000012}}

def err(code, message, kind=None):
    e = {"code": code, "message": message}
    if kind: e["metadata"] = {"error_type": kind, "provider_name": "Mock"}
    return {"error": e}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def send_json(self, status, obj, headers=()):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        for k, v in headers: self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)

    def chunk(self, data):
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n"); self.wfile.flush()

    def sse(self, pieces):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for p in pieces:
            self.chunk(p); time.sleep(0.02)
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()

    def echo(self):
        """With an X-Echo header, any request is answered with a description of itself: for testing the
        functions that are made from OpenRouter's API description. The header's value picks the kind of answer."""
        kind = self.headers.get("X-Echo")
        if not kind: return False
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        ctype = self.headers.get("Content-Type", "")
        what = {"method": self.command, "path": self.path, "type": ctype.split(";")[0], "auth": self.headers.get("Authorization")}
        if ctype.startswith("application/json"): what["body"] = json.loads(raw)
        elif ctype.startswith("multipart/"):
            import re
            what["parts"] = [m.decode() for m in re.findall(rb' name="([^"]*)"', raw)]
            what["files"] = [m.decode() for m in re.findall(rb'filename="([^"]*)"', raw)]
            what["types"] = [m.decode() for m in re.findall(rb'Content-Type: ([^\r\n]*)', raw)]
            what["size"] = len(raw)
        elif raw: what["body"] = raw.decode()
        if kind == "bytes":
            b = bytes([0, 255, 254, 1]) + self.path.encode()
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)
        elif kind == "text":
            b = ("# " + self.path).encode()
            self.send_response(200); self.send_header("Content-Type", "text/markdown"); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)
        elif kind == "empty":
            self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()
        else: self.send_json(200, what)
        return True

    def do_DELETE(self):
        if self.echo(): return
        if not self.authed(): return self.send_json(401, err(401, "No auth credentials found"))
        kind, _, ident = self.path[len("/api/v1/"):].partition("/")
        store = {"keys": KEYS, "files": FILES, "batches": BATCHES}.get(kind)
        if store is None or ident not in store: return self.send_json(404, err(404, "Not found"))
        del store[ident]
        self.send_response(204); self.send_header("Content-Length", "0"); self.end_headers()

    def do_PATCH(self):
        if self.echo(): return
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        h = self.path.rsplit("/", 1)[1]
        if not self.path.startswith("/api/v1/keys/") or h not in KEYS: return self.send_json(404, err(404, "Key not found"))
        KEYS[h].update(req)
        self.send_json(200, {"data": KEYS[h]})

    def do_PUT(self):
        if not self.echo(): self.send_json(404, err(404, "Not found"))

    def events(self, items, named=False):
        """Send JSON events as a stream. named: also write each event's type on an event: line, as Anthropic does."""
        self.sse([(("event: %s\n" % o["type"] if named else "") + "data: " + json.dumps(o) + "\n\n").encode() for o in items])

    def responses_api(self, req):
        """The Responses API. The model name picks the behavior."""
        m = req.get("model"); stream = req.get("stream") is True
        last = req["input"][-1] if isinstance(req["input"], list) else {"type": "message", "content": req["input"]}
        usage = {"input_tokens": 12, "output_tokens": 6, "total_tokens": 18, "input_tokens_details": {"cached_tokens": 4, "cache_write_tokens": 2},
                 "output_tokens_details": {"reasoning_tokens": 3}, "cost": 0.00003}
        def result(output, status="completed"):
            return {"id": "resp-mock-1", "object": "response", "model": m, "status": status, "output": output, "usage": usage, "error": None}
        def message(text, annotations=()):
            return {"type": "message", "id": "msg_1", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": text, "annotations": list(annotations)}]}
        if m == "mock/r-echo": return self.send_json(200, result([message(json.dumps(req))]))
        if m == "mock/r-fail":
            if stream: return self.events([{"type": "response.created", "response": {}}, {"type": "response.failed", "response": {"error": {"code": 502, "message": "Upstream failed"}}}])
            return self.send_json(502, err(502, "Upstream failed"))
        if m == "mock/r-tools":
            if last.get("type") == "function_call_output":
                kept = [i for i in req["input"] if i.get("type") in ("reasoning", "function_call")]
                return self.send_json(200, result([message("The sum is %s (%d items came back)." % (last["output"], len(kept)))]))
            tool = req["tools"][0]
            if "function" in tool or "parameters" not in tool: return self.send_json(400, err(400, "Tools must be flat in the Responses API"))
            return self.send_json(200, result([{"type": "reasoning", "id": "rs_1", "summary": [{"type": "summary_text", "text": "I should add."}]},
                {"type": "function_call", "id": "fc_1", "call_id": "call_r1", "name": tool["name"], "arguments": "{\"numbers\": [1, 2, 3.5]}", "status": "completed"}]))
        if m == "mock/r-json":
            f = req.get("text", {}).get("format", {})
            return self.send_json(200, result([message(json.dumps({"city": "Oslo", "celsius": -3.5, "advice": f.get("name"), "tags": [f.get("type"), str(f.get("strict"))]}))]))
        text = "Hello from the Responses API."
        cite = {"type": "url_citation", "url": "https://example.com/a", "title": "A", "start_index": 0, "end_index": 5}
        output = [{"type": "reasoning", "id": "rs_1", "summary": [{"type": "summary_text", "text": "Greeting."}]}, message(text, [cite]),
                  {"type": "web_search_call", "id": "ws_1", "status": "completed"}]
        if not stream: return self.send_json(200, result(output))
        self.events([{"type": "response.created", "response": {"id": "resp-mock-1"}},
            {"type": "response.reasoning_summary_text.delta", "delta": "Greeting."},
            {"type": "response.output_item.done", "item": output[0]},
            {"type": "response.output_text.delta", "delta": "Hello from "}, {"type": "response.output_text.delta", "delta": "the Responses API."},
            {"type": "response.output_item.done", "item": output[1]},
            {"type": "response.function_call_arguments.delta", "delta": "{}"},
            {"type": "response.completed", "response": result(output)}])

    def anthropic(self, req):
        """The Anthropic Messages API."""
        m = req.get("model"); stream = req.get("stream") is True
        last = req["messages"][-1]["content"]
        usage = {"input_tokens": 9, "output_tokens": 5, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 1}
        def result(content, stop="end_turn"):
            return {"id": "msg-mock-1", "type": "message", "role": "assistant", "model": m, "content": content, "stop_reason": stop, "stop_sequence": None, "usage": usage}
        if m == "mock/a-echo": return self.send_json(200, result([{"type": "text", "text": json.dumps(req)}]))
        if m == "mock/a-tools":
            if isinstance(last, list) and last[-1].get("type") == "tool_result":
                return self.send_json(200, result([{"type": "text", "text": "It is %s." % last[-1]["content"]}]))
            return self.send_json(200, result([{"type": "thinking", "thinking": "I need the time.", "signature": "sig1"}, {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "id": "toolu_1", "name": req["tools"][0]["name"], "input": {"city": "Paris"}}], "tool_use"))
        if m == "mock/a-overloaded" and stream:
            return self.events([{"type": "message_start", "message": {"id": "msg-mock-2", "model": m, "usage": {"input_tokens": 1}}},
                {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}}], named=True)
        if not stream: return self.send_json(200, result([{"type": "text", "text": "Hello from the Messages API."}]))
        self.events([{"type": "message_start", "message": {"id": "msg-mock-1", "type": "message", "role": "assistant", "model": m, "content": [], "usage": {"input_tokens": 9, "output_tokens": 1}}},
            {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "Greet "}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "them."}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig9"}},
            {"type": "content_block_stop", "index": 0},
            {"type": "ping"},
            {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Hello from "}},
            {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "the Messages API."}},
            {"type": "content_block_stop", "index": 1},
            {"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "toolu_2", "name": "lookup", "input": {}}},
            {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "{\"q\": "}},
            {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "\"x\"}"}},
            {"type": "content_block_stop", "index": 2},
            {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 5}},
            {"type": "message_stop"}], named=True)

    def authed(self):
        return self.headers.get("Authorization") == "Bearer test-key"

    def do_GET(self):
        if self.echo(): return
        p = self.path
        if p == "/_seen": return self.send_json(200, seen)   # how many requests each stateful model got
        if p == "/_reset":
            with lock: seen.clear(); KEYS.clear(); FILES.clear(); BATCHES.clear(); VIDEOS.clear()
            return self.send_json(200, {})
        if not self.authed() and not p.startswith("/api/v1/models"):
            return self.send_json(401, err(401, "No auth credentials found"))
        if p == "/api/v1/models/count": return self.send_json(200, {"data": {"count": 2}})
        if p == "/api/v1/model/mock/plain":
            return self.send_json(200, {"data": {"id": "mock/plain", "name": "Mock Plain", "context_length": 128000, "supported_voices": ["ada", "bo"]}})
        if p.startswith("/api/v1/models/user"): return self.send_json(200, {"data": [{"id": "mock/allowed", "name": "Allowed"}]})
        if p == "/api/v1/endpoints/zdr":
            return self.send_json(200, {"data": [{"name": "Mock | mock/plain", "provider_name": "Mock", "tag": "mock", "context_length": 1000, "pricing": {"prompt": "0.000001"}}]})
        if p.startswith("/api/v1/tools"):
            return self.send_json(200, {"data": [{"name": "web_search", "type": "openrouter:web_search"}, {"name": "datetime", "type": "openrouter:datetime"}]})
        if p.startswith("/api/v1/models"):
            return self.send_json(200, {"data": [
                {"id": "mock/plain", "name": "Mock Plain", "created": 5, "context_length": 128000,
                 "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
                 "pricing": {"prompt": "0.000001", "completion": "0.000002"},
                 "top_provider": {"max_completion_tokens": 4096, "is_moderated": False},
                 "supported_parameters": ["tools", "temperature"], "description": "query=" + p.partition("?")[2]},
                {"id": "mock/tiny", "name": "Tiny", "supported_parameters": []}]})
        if p == "/api/v1/key":
            return self.send_json(200, {"data": {"label": "sk-or-v1-abc...xyz", "limit": 10, "limit_remaining": 7.5, "usage": 2.5, "is_free_tier": False}})
        if p.startswith("/api/v1/generation/content?id=gen-mock-1"):
            return self.send_json(200, {"data": {"input": {"messages": [{"role": "user", "content": "hi"}]}, "output": {"completion": "You said: hi"}}})
        if p.startswith("/api/v1/activity"):
            return self.send_json(200, {"data": [{"date": "2026-01-01", "model": "mock/plain", "usage": 0.5, "requests": 3, "query": p.partition("?")[2]}]})
        if p.startswith("/api/v1/keys/"):
            h = p.rsplit("/", 1)[1]
            return self.send_json(200, {"data": KEYS[h]}) if h in KEYS else self.send_json(404, err(404, "Key not found"))
        if p.startswith("/api/v1/keys"): return self.send_json(200, {"data": list(KEYS.values())})
        if p.startswith("/api/v1/videos/"):
            parts = p.split("?")[0].split("/")
            job = parts[4]
            if job not in VIDEOS: return self.send_json(404, err(404, "Job not found"))
            if len(parts) > 5 and parts[5] == "content":
                b = b"\x00\x00\x00\x18ftypmp42" + p.partition("?")[2].encode()
                self.send_response(200); self.send_header("Content-Type", "video/mp4"); self.send_header("Content-Length", str(len(b))); self.end_headers()
                return self.wfile.write(b)
            VIDEOS[job] += 1
            if job == "job-bad" and VIDEOS[job] >= 2:
                return self.send_json(200, {"id": job, "status": "failed", "polling_url": "", "error": "Prompt was refused"})
            done = VIDEOS[job] >= 3
            return self.send_json(200, {"id": job, "status": "completed" if done else "in_progress", "polling_url": "",
                **({"unsigned_urls": ["http://127.0.0.1/v/%s/0.mp4" % job], "usage": {"cost": 0.25}} if done else {})})
        if p.startswith("/api/v1/files/"):
            parts = p.split("?")[0].split("/")
            f = parts[4]
            if f not in FILES: return self.send_json(404, err(404, "File not found"))
            if len(parts) > 5 and parts[5] == "content":
                if not FILES[f]["downloadable"]: return self.send_json(400, err(400, "Uploaded files cannot be downloaded"))
                b = bytes([0, 1, 2, 255])
                self.send_response(200); self.send_header("Content-Type", "application/octet-stream"); self.send_header("Content-Length", str(len(b))); self.end_headers()
                return self.wfile.write(b)
            return self.send_json(200, FILES[f])
        if p.startswith("/api/v1/files"):
            return self.send_json(200, {"_shape": "openrouter", "data": list(FILES.values()), "has_more": False, "first_id": None, "last_id": None, "cursor": None})
        if p.startswith("/api/v1/batches/"):
            b = p.rsplit("/", 1)[1]
            if b not in BATCHES: return self.send_json(404, err(404, "Batch not found"))
            batch = BATCHES[b]; batch["_polls"] = batch.get("_polls", 0) + 1
            if batch["_polls"] >= 2 and batch["status"] == "validating":
                n = batch["request_counts"]["total"]
                batch.update({"status": "completed", "request_counts": {"total": n, "completed": n - 1, "failed": 1},
                    "results": [{"id": "r%d" % i, "custom_id": r["custom_id"],
                                 "response": {"status_code": 200, "body": reply(batch["model"], "batched: " + r["body"]["messages"][-1]["content"])}, "error": None}
                                for i, r in enumerate(batch["_requests"][:-1])]
                             + [{"id": "rx", "custom_id": batch["_requests"][-1]["custom_id"], "response": None,
                                 "error": {"type": "invalid_request", "message": "Bad request in batch", "param": None}}]})
            return self.send_json(200, {k: v for k, v in batch.items() if not k.startswith("_")})
        if p.startswith("/api/v1/batches"):
            return self.send_json(200, {"data": [{k: v for k, v in b.items() if not k.startswith("_")} for b in BATCHES.values()], "has_more": False})
        if p == "/api/v1/credits": return self.send_json(200, {"data": {"total_credits": 25, "total_usage": 3.25}})
        if p.startswith("/api/v1/generation?id=gen-mock-1"):
            return self.send_json(200, {"data": {"id": "gen-mock-1", "model": "mock/plain", "provider_name": "Mock", "total_cost": 0.000012,
                "tokens_prompt": 7, "tokens_completion": 3, "latency": 120, "finish_reason": "stop", "streamed": False, "cancelled": False}})
        self.send_json(404, err(404, "Not found"))

    def do_POST(self):
        if self.echo(): return
        n = int(self.headers.get("Content-Length", "0"))
        if self.path.startswith("/api/v1/files"):
            import re
            raw = self.rfile.read(n)
            if not self.authed(): return self.send_json(401, err(401, "No auth credentials found"))
            name = re.search(rb'filename="([^"]*)"', raw).group(1).decode()
            content = raw.split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n--", 1)[0]
            f = {"_shape": "openrouter", "id": "file-%d" % (len(FILES) + 1), "type": "file", "filename": name, "mime_type": "application/pdf" if content.startswith(b"%PDF") else "text/plain",
                 "size_bytes": len(content), "created_at": "2026-01-01T00:00:00Z", "downloadable": False}
            FILES[f["id"]] = f
            return self.send_json(200, f)
        try: req = json.loads(self.rfile.read(n))
        except Exception: return self.send_json(400, err(400, "body is not JSON"))
        if self.path == "/api/v1/auth/keys":      # needs no key
            if req.get("code") != "good-code": return self.send_json(403, err(403, "Invalid code"))
            return self.send_json(200, {"key": "sk-or-v1-user-" + str(req.get("code_verifier")) + "-" + str(req.get("code_challenge_method")), "user_id": "u1"})
        if not self.authed(): return self.send_json(401, err(401, "No auth credentials found"))
        if self.path == "/api/v1/keys":
            if not self.authed(): return self.send_json(401, err(401, "No auth credentials found"))
            h = "hash%d" % (len(KEYS) + 1)
            KEYS[h] = {"hash": h, "name": req.get("name"), "label": "sk-or-v1-new...%d" % len(KEYS), "disabled": False, "limit": req.get("limit"), "limit_remaining": req.get("limit"), "usage": 0}
            return self.send_json(201, {"data": KEYS[h], "key": "sk-or-v1-secret-" + h})
        if self.path == "/api/v1/generation/feedback":
            return self.send_json(200, {"data": {"ok": True, "echo": req}}) if req.get("generation_id") == "gen-mock-1" else self.send_json(404, err(404, "Generation not found"))
        if self.path == "/api/v1/rerank":
            words = set(req["query"].lower().split())
            scored = sorted(((len(words & set(d.lower().replace(".", "").split())) / max(1, len(words)), i, d) for i, d in enumerate(req["documents"])), key=lambda x: (-x[0], x[1]))
            return self.send_json(200, {"id": "gen-rerank-1", "model": req["model"], "provider": "Mock",
                "results": [{"index": i, "relevance_score": sc, "document": {"text": d}} for sc, i, d in scored[:req.get("top_n", len(scored))]],
                "usage": {"search_units": 1, "total_tokens": 10, "cost": 0.002}})
        if self.path == "/api/v1/videos":
            if req.get("model") == "mock/no-video": return self.send_json(400, err(400, "Model cannot make videos"))
            job = "job-bad" if "refuse" in req.get("prompt", "") else "job-%d" % (len(VIDEOS) + 1)
            VIDEOS[job] = 0
            return self.send_json(202, {"id": job, "status": "pending", "polling_url": "/api/v1/videos/" + job})
        if self.path == "/api/v1/batches":
            if list(req.keys())[-1] != "requests": return self.send_json(400, err(400, "requests must be the last field"))
            b = "batch-%d" % (len(BATCHES) + 1)
            BATCHES[b] = {"id": b, "object": "batch", "endpoint": req["endpoint"], "model": req["model"], "completion_window": "24h", "status": "validating",
                "created_at": 1, "finalized_at": None, "provider": None, "expires_at": None,
                "request_counts": {"total": len(req["requests"]), "completed": 0, "failed": 0}, "usage": None, "results": None, "error": None, "_requests": req["requests"]}
            return self.send_json(202, {k: v for k, v in BATCHES[b].items() if not k.startswith("_")})
        if self.path == "/api/v1/responses": return self.responses_api(req)
        if self.path == "/api/v1/messages": return self.anthropic(req)
        if self.path == "/api/v1/images":
            if req.get("model") == "mock/no-image": return self.send_json(400, err(400, "Model cannot make images"))
            import base64
            png = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 255, 254]) + req.get("prompt", "").encode()
            return self.send_json(200, {"created": 1, "data": [{"b64_json": base64.b64encode(png).decode(), "media_type": "image/png"}] * req.get("n", 1),
                "usage": {"prompt_tokens": 0, "completion_tokens": 40, "total_tokens": 40, "cost": 0.04}})
        if self.path == "/api/v1/audio/speech":
            if req.get("model") == "mock/mute": return self.send_json(402, err(402, "Insufficient credits"))
            b = bytes(range(256)) * 3 + (req.get("voice", "") + "|" + req.get("response_format", "pcm") + "|" + req.get("input", "")).encode()   # every byte value: not text
            self.send_response(200); self.send_header("Content-Type", "audio/mpeg"); self.send_header("Content-Length", str(len(b))); self.end_headers()
            return self.wfile.write(b)
        if self.path == "/api/v1/audio/transcriptions":
            import base64
            a = req.get("input_audio", {})
            raw = base64.b64decode(a["data"]) if "data" in a else a.get("url", "").encode()
            out = {"text": "heard %d bytes of %s in %s" % (len(raw), a.get("format"), req.get("language")), "usage": {"seconds": 1.5, "cost": 0.0002}}
            if req.get("response_format") == "verbose_json":
                out.update({"language": "english", "duration": 1.5, "segments": [{"id": 0, "start": 0.0, "end": 1.5, "text": "heard"}]})
            return self.send_json(200, out)
        if self.path == "/api/v1/embeddings":
            vecs = [{"object": "embedding", "index": i, "embedding": [float(len(t)), 0.5, -1e-3]} for i, t in enumerate(req.get("input", []))]
            return self.send_json(200, {"object": "list", "model": req.get("model"), "data": vecs[::-1],   # out of order on purpose
                "usage": {"prompt_tokens": 5, "total_tokens": 5, "cost": 0.0000001}})
        if self.path == "/api/v1/completions" and req.get("stream") is True:
            ev = lambda o: ("data: " + json.dumps(o) + "\n\n").encode()
            c = lambda text, fin=None: {"id": "gen-mock-5", "model": req.get("model"), "choices": [{"index": 0, "text": text, "finish_reason": fin}]}
            return self.sse([ev(c(" is")), ev(c(" blue")), ev(c("", "stop")), b"data: [DONE]\n\n"])
        if self.path == "/api/v1/completions":
            return self.send_json(200, {"id": "gen-mock-4", "model": req.get("model"), "provider": "Mock",
                "choices": [{"text": req.get("prompt", "") + " blue", "finish_reason": "length", "logprobs": {
                    "tokens": ["The", " sky", " is", " blue"], "token_logprobs": [None, -2.5, -0.31, -0.9],
                    "top_logprobs": [None, {" sky": -2.5}, {" is": -0.31}, {" blue": -0.9, " falling": -2.2}]}}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4}})
        if self.path != "/api/v1/chat/completions": return self.send_json(404, err(404, "Not found"))
        m = req.get("model", ""); stream = req.get("stream") is True
        said = req["messages"][-1].get("content")
        if m == "mock/plain":
            return self.send_json(200, reply(m, "You said: %s | title=%s | temp=%s" % (said, self.headers.get("X-Title"), req.get("temperature"))))
        if m == "openai/gpt-4o-mini":   # the model the examples use: enough of a model to run them offline
            if "response_format" in req:
                return self.send_json(200, reply(m, json.dumps({"planets": [
                    {"name": "Mercury", "moons": 0, "year": 88.0, "discovery": None},
                    {"name": "Uranus", "moons": 28, "year": 30687.0, "discovery": 1781}]})))
            if "tools" in req and req["messages"][-1]["role"] != "tool":
                call = lambda i, name, args: {"id": "call_%d" % i, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
                return self.send_json(200, reply(m, None, "tool_calls", [call(1, "get_weather", {"city": "Oslo"}),
                    call(2, "get_weather", {"city": "Lima", "unit": "fahrenheit"}), call(3, "add", {"numbers": [12.5, 30, 0.25]})]))
            if "tools" in req:
                return self.send_json(200, reply(m, " / ".join(x["content"] for x in req["messages"] if x["role"] == "tool")))
            words = "Types that depend on / values, proofs that run as programs: / the compiler nods.".split(" ")
            if stream:
                ev = lambda o: ("data: " + json.dumps(o) + "\n\n").encode()
                c = lambda delta, fin=None: {"id": "gen-mock-8", "model": m, "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
                return self.sse([ev(c({"content": w + " "})) for w in words] + [ev(c({"content": ""}, "stop")), b"data: [DONE]\n\n"])
            return self.send_json(200, reply(m, "Sunlight scatters off air molecules, and blue light scatters the most."))
        if m == "mock/echo":       # the request, as the server saw it
            return self.send_json(200, reply(m, json.dumps({"body": req, "referer": self.headers.get("HTTP-Referer"),
                "agent": self.headers.get("User-Agent"), "extra": self.headers.get("X-Extra")})))
        if m == "mock/typed":      # a tool call with bad arguments, then a good one, then an answer
            last = req["messages"][-1]
            call = lambda i, args: reply(m, None, "tool_calls", [{"id": i, "type": "function", "function": {"name": "get_weather", "arguments": args}}])
            if last["role"] != "tool": return self.send_json(200, call("call_a", "{\"city\": 5}"))
            if last["content"].startswith("Error"): return self.send_json(200, call("call_b", "{\"city\": \"Paris\", \"days\": 2}"))
            return self.send_json(200, reply(m, "Forecast: " + last["content"]))
        if m == "mock/loop":       # never stops calling
            return self.send_json(200, reply(m, None, "tool_calls", [{"id": "call_%d" % nth(m), "type": "function", "function": {"name": "nope", "arguments": ""}}]))
        if m == "mock/structured": # fenced JSON that fits the test's schema
            fmt = req.get("response_format", {})
            return self.send_json(200, reply(m, "```json\n{\"city\": \"Oslo\", \"celsius\": -3.5, \"advice\": null, \"tags\": [\"cold\", \"%s\"]}\n```" % fmt.get("json_schema", {}).get("name")))
        if m == "mock/structured-bad":
            return self.send_json(200, reply(m, "{\"city\": \"Oslo\", \"celsius\": \"cold\"}"))
        if m == "mock/wait":       # a second's work; reports how many were in flight with it
            with lock: seen["_now"] = seen.get("_now", 0) + 1; seen["_peak"] = max(seen.get("_peak", 0), seen["_now"])
            time.sleep(1)
            with lock: seen["_now"] -= 1
            return self.send_json(200, reply(m, "waited for " + str(said)))
        if m == "mock/slow":
            time.sleep(3); return self.send_json(200, reply(m, "late"))
        if m == "mock/stream-stall" and stream:
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            self.chunk(b'data: {"id":"gen-mock-6","choices":[{"index":0,"delta":{"content":"one "}}]}\n\n')
            time.sleep(6); return
        if m == "mock/media" and stream:       # a reply with a picture, spoken in base64 pieces
            import base64
            ev = lambda o: ("data: " + json.dumps(o) + "\n\n").encode()
            c = lambda delta, fin=None: {"id": "gen-mock-9", "model": m, "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
            a = req.get("audio", {})
            say = lambda b, t: {"audio": {"data": base64.b64encode(b).decode(), "transcript": t}}
            return self.sse([ev(c({"content": "Here. "})), ev(c(say(b"RIFF\x00", "Hello "))), ev(c(say(b"\xff\xfe" + a.get("voice", "").encode(), "there"))),
                ev(c({"images": [{"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(b"\x89PNG\x00pic").decode()}}]})),
                ev(c({"content": ""}, "stop")), b"data: [DONE]\n\n"])
        if m == "mock/media":
            return self.send_json(200, {"id": "gen-mock-9", "model": m, "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "A cat.",
                "images": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,iVBORw0KGgo="}}, {"type": "image_url", "image_url": {"url": "https://example.com/cat.png"}}]}}]})
        if m == "mock/stream-n2" and stream:   # two choices, interleaved, CRLF line ends, no [DONE]
            ev = lambda o: ("data: " + json.dumps(o) + "\r\n\r\n").encode()
            c = lambda i, delta, fin=None: {"id": "gen-mock-7", "model": m, "choices": [{"index": i, "delta": delta, "finish_reason": fin}]}
            return self.sse([ev(c(1, {"content": "B1"})), ev(c(0, {"content": "A1"})), ev(c(1, {"content": "B2"}, "length")),
                ev(c(0, {"content": "A2"}, "stop"))])
        if m == "mock/tools":
            if req["messages"][-1]["role"] == "tool":
                return self.send_json(200, reply(m, "It is %s in Paris." % req["messages"][-1]["content"]))
            return self.send_json(200, reply(m, None, "tool_calls", [{"id": "call_1", "type": "function", "function": {"name": req["tools"][0]["function"]["name"], "arguments": "{\"city\":\"Paris\"}"}}]))
        if m == "mock/429":
            if nth(m) == 1: return self.send_json(429, err(429, "Rate limit exceeded", "rate_limit_exceeded"), [("Retry-After", "1")])
            return self.send_json(200, reply(m, "ok after 429, attempt %d" % seen[m]))
        if m == "mock/200err":
            if nth(m) == 1: return self.send_json(200, err(502, "Provider returned error", "provider_unavailable"))
            return self.send_json(200, reply(m, "ok after hidden 502, attempt %d" % seen[m]))
        if m == "mock/down":
            nth(m); return self.send_json(503, err(503, "No provider available", "provider_overloaded"))
        if m == "mock/402": return self.send_json(402, err(402, "Insufficient credits", "payment_required"))
        if m == "mock/garbage":
            b = b"<html>bad gateway</html>"; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); return self.wfile.write(b)
        if m == "mock/stream" and stream:
            def ev(o): return ("data: " + json.dumps(o) + "\n\n").encode()
            c = lambda delta, fin=None: {"id": "gen-mock-2", "provider": "Mock", "model": m, "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
            body = b": OPENROUTER PROCESSING\n\n" + ev(c({"role": "assistant", "content": "", "reasoning": "thinking. "})) + ev(c({"content": "Str"})) \
                + b": OPENROUTER PROCESSING\n\n" + ev(c({"content": "eamed héllo \U0001F600"})) + ev(c({"content": " done"})) \
                + ev(c({"tool_calls": [{"index": 0, "id": "call_s", "type": "function", "function": {"name": "lookup", "arguments": "{\"q\":"}}]})) \
                + ev(c({"tool_calls": [{"index": 0, "function": {"arguments": "\"x\"}"}}]})) \
                + ev(c({"content": ""}, "stop")) \
                + ev({**c({"content": "", "role": "assistant"}, "stop"), "usage": {"prompt_tokens": 9, "completion_tokens": 4, "total_tokens": 13, "cost": 0.00002}}) \
                + b"data: [DONE]\n\n"
            cuts = [0, 5, 31, 32, 90, 91, 200, 207, 333, len(body) - 20, len(body)]   # split mid-line and mid-character
            return self.sse([body[a:b] for a, b in zip(cuts, cuts[1:]) if b > a])
        if m == "mock/stream-err" and stream:
            return self.sse([b'data: {"id":"gen-mock-3","model":"m","choices":[{"index":0,"delta":{"content":"partial "}}]}\n\n',
                b'data: {"id":"gen-mock-3","error":{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}\n\n'])
        if m == "mock/stream-402" and stream: return self.send_json(402, err(402, "Insufficient credits", "payment_required"))
        self.send_json(400, err(400, "unknown mock model " + m))

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    print("mock OpenRouter on http://127.0.0.1:%d/api/v1" % port, flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
