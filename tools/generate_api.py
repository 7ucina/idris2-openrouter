#!/usr/bin/env python3
"""Generate src/OpenRouter/API.idr: one function for every operation in
OpenRouter's OpenAPI description.

    tools/generate_api.py                 fetch the description and regenerate
    tools/generate_api.py openapi.json    use a local copy

The module this writes is checked in. Run this again when OpenRouter adds
endpoints; `git diff` then shows what changed in the API.
"""
import glob
import json
import re
import sys
import textwrap
import urllib.request

SPEC_URL = "https://openrouter.ai/openapi.json"
OUT = "src/OpenRouter/API.idr"
METHODS = ("get", "post", "put", "patch", "delete")

# operationIds that are not usable names as they stand
RENAME = {
    "list": "listKeys",
    "listCreditsPurchasesSKILL.md": "getCreditsPurchasesSkill",
}

# headers the client sends on every request, from its appUrl, appTitle and appCategories
APP_HEADERS = {"HTTP-Referer", "X-OpenRouter-Title", "X-OpenRouter-Categories"}

KEYWORDS = {"data", "total", "partial", "parameters", "open", "auto", "default", "record",
            "module", "import", "export", "public", "private", "where", "with", "of", "in",
            "let", "do", "if", "then", "else", "case", "using", "interface", "implementation",
            "namespace", "mutual", "covering", "forall", "rewrite", "impossible", "failing"}


def load():
    if len(sys.argv) > 1:
        return json.load(open(sys.argv[1]))
    request = urllib.request.Request(SPEC_URL, headers={"User-Agent": "idris2-openrouter-generator"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def camel(name):
    parts = re.split(r"[^A-Za-z0-9]+", name)
    out = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    out = out[:1].lower() + out[1:]
    return out + "'" if out in KEYWORDS else out


def clean(text):
    """One paragraph of prose, fit for a doc comment."""
    text = (text or "").strip().split("\n\n")[0]
    text = re.sub(r"\s+", " ", text)
    text = text.replace(" — ", ": ").replace("—", ", ").replace("–", "-")
    text = text.replace("’", "'").replace("“", '"').replace("”", '"')
    return text


def sentence(text):
    text = clean(text)
    return text if not text or text[-1] in ".!?:`)" else text + "."


def comment(lines):
    out = []
    for line in lines:
        if line == "":
            out.append("|||")
        else:
            for wrapped in textwrap.wrap(line, 74, break_long_words=False, break_on_hyphens=False):
                out.append("||| " + wrapped)
    return out


def operations(spec):
    shared = spec["components"].get("parameters", {})

    def resolve(p):
        return shared[p["$ref"].split("/")[-1]] if "$ref" in p else p

    ops = []
    for path, item in spec["paths"].items():
        for method in METHODS:
            if method not in item:
                continue
            op = item[method]
            params = [resolve(p) for p in (item.get("parameters") or []) + (op.get("parameters") or [])]
            request = list((op.get("requestBody") or {}).get("content", {}).keys())
            produces = set()
            for code, response in op.get("responses", {}).items():
                if code.startswith("2"):
                    produces |= set((response.get("content") or {}).keys())
            ops.append({
                "tag": (op.get("tags") or ["Other"])[0],
                "method": method.upper(),
                "path": path,
                "name": camel(RENAME.get(op["operationId"], op["operationId"])),
                "summary": op.get("summary") or "",
                "description": op.get("description") or "",
                "deprecated": op.get("deprecated", False),
                "path_params": re.findall(r"\{([^}]+)\}", path),
                "required_query": [p["name"] for p in params if p["in"] == "query" and p.get("required")],
                "optional_query": [p["name"] for p in params if p["in"] == "query" and not p.get("required")],
                "headers": [p["name"] for p in params if p["in"] == "header" and p["name"] not in APP_HEADERS],
                "request": request,
                "produces": produces,
            })
    return ops


def body_kind(op):
    if "application/json" in op["request"]:
        return "json"
    if "multipart/form-data" in op["request"]:
        return "multipart"
    if "application/x-www-form-urlencoded" in op["request"]:
        return "form"
    return None


def result_kind(op):
    p = op["produces"]
    if "application/json" in p or not p:
        return "json"
    if any(t.startswith("text/") for t in p):
        return "text"
    return "file"


def path_expr(op):
    pieces = re.split(r"(\{[^}]+\})", op["path"])
    out = []
    for piece in pieces:
        if not piece:
            continue
        if piece.startswith("{"):
            out.append("urlEncode " + camel(piece[1:-1]))
        else:
            out.append(json.dumps(piece))
    return out[0] if len(out) == 1 else "(" + " ++ ".join(out) + ")"


def render(op):
    body, result = body_kind(op), result_kind(op)
    args = [(camel(p), "String") for p in op["path_params"]]
    args += [(camel(p), "String") for p in op["required_query"]]
    if op["optional_query"]:
        args.append(("query", "List (String, String)"))
    if body == "json":
        args.append(("body", "JSON"))
    elif body == "multipart":
        args.append(("parts", "List FormPart"))
    elif body == "form":
        args.append(("fields", "List (String, String)"))
    if result == "file":
        args.append(("file", "String"))
    returns = {"json": "JSON", "text": "String", "file": "Nat"}[result]

    doc = [sentence(op["summary"]) or op["name"]]
    description = sentence(op["description"])
    if description and description.rstrip(".").lower() != doc[0].rstrip(".").lower():
        doc += ["", description]
    doc += ["", "`%s %s`" % (op["method"], op["path"])]
    if op["optional_query"]:
        doc += ["", "Query parameters: " + ", ".join("`%s`" % q for q in op["optional_query"]) + "."]
    if op["headers"]:
        doc += ["", "Headers, set through the client's `headers`: "
                + ", ".join("`%s`" % h for h in op["headers"]) + "."]
    if "text/event-stream" in op["produces"]:
        doc += ["", "This returns the whole response. To stream it, see `openEventStream`."]
    if result == "file":
        doc += ["", "The response's bytes are written to `file`; the result is how many there were."]
    if op["deprecated"]:
        doc += ["", "Deprecated by OpenRouter."]

    query = " ++ ".join(
        ["[" + ", ".join('("%s", %s)' % (q, camel(q)) for q in op["required_query"]) + "]"]
        * bool(op["required_query"]) + ["query"] * bool(op["optional_query"])) or "[]"
    if " ++ " in query:
        query = "(" + query + ")"
    path = path_expr(op)
    names = " ".join(n for n, _ in args)
    if body == "multipart":
        call = "upload c %s %s parts" % (path, query)
    elif body == "form":
        call = "callForm c %s fields" % path
    elif result == "file":
        call = "download c %s %s %s %s file" % (op["method"], path, query, "(Just body)" if body else "Nothing")
    elif result == "text":
        call = "callText c %s %s %s" % (op["method"], path, query)
    else:
        call = "call c %s %s %s %s" % (op["method"], path, query, "(Just body)" if body else "Nothing")

    signature = ["%s : HasIO io => Client" % op["name"]]
    for n, t in args:
        piece = " -> (%s : %s)" % (n, t)
        if len(signature[-1]) + len(piece) > 96:
            signature.append("  " + piece.lstrip())
        else:
            signature[-1] += piece
    tail = " -> io (Either Error %s)" % returns
    if len(signature[-1]) + len(tail) > 96:
        signature.append("  " + tail.lstrip())
    else:
        signature[-1] += tail

    lines = comment(doc) + ["export covering"] + signature
    lines.append("%s c%s = %s" % (op["name"], " " + names if names else "", call))
    return "\n".join(lines)


def main():
    spec = load()
    ops = operations(spec)
    names = [op["name"] for op in ops]
    assert len(set(names)) == len(names), "duplicate names"

    # `import OpenRouter.API as API` still brings these names into scope
    # unqualified, so none may be the name of a typed function.
    typed = set()
    for source in glob.glob("src/OpenRouter/*.idr"):
        if not source.endswith("API.idr"):
            typed |= set(re.findall(r"^([a-z][A-Za-z0-9']*) :", open(source).read(), re.M))
    clashes = sorted(set(names) & typed)
    assert not clashes, "these operations share a name with a typed function: " + ", ".join(clashes)

    tags = []
    for op in ops:
        if op["tag"] not in tags:
            tags.append(op["tag"])
    tags.sort(key=str.lower)

    out = ['''||| Every endpoint of the OpenRouter API, one function each.
|||
||| This module is generated from OpenRouter's OpenAPI description by
||| `tools/generate_api.py`; do not edit it by hand. It covers %d operations.
|||
||| These functions are thin: path parameters and required query parameters
||| are arguments, optional query parameters go in a `query` list, and bodies
||| and results are `JSON`. They add what every call here has (the key,
||| retries, timeouts, errors as `Either Error`). For the endpoints most
||| programs use (chat, streaming, tools, images, audio, and so on) the
||| modules re-exported by `OpenRouter` have typed functions instead.
|||
||| The module is not re-exported by `OpenRouter`, since its names are the
||| API's own and overlap with the typed ones. Import it under a name:
|||
||| ```idris
||| import OpenRouter
||| import OpenRouter.API as API
|||
||| guardrails <- API.listGuardrails client [("limit", "20")]
||| ```
module OpenRouter.API

import OpenRouter.Client
import OpenRouter.JSON
import OpenRouter.Response

%%default total''' % len(ops)]

    for tag in tags:
        out.append("-" * 80 + "\n-- " + tag + "\n" + "-" * 80)
        for op in sorted((o for o in ops if o["tag"] == tag), key=lambda o: (o["path"], o["method"])):
            out.append(render(op))

    open(OUT, "w").write("\n\n".join(out) + "\n")
    print("wrote %s: %d operations in %d groups" % (OUT, len(ops), len(tags)))


if __name__ == "__main__":
    main()
