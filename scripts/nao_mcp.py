#!/usr/bin/env python3
"""Client minimal du point d'entrée MCP de Nao (ask_nao / get_nao_answer / outils).

Identifiants hors dépôt : ~/.config/nao/mcp-url et ~/.config/nao/mcp-token
(ou variables NAO_MCP_URL / NAO_MCP_TOKEN).

Usage :
  nao_mcp.py tools                       # liste des outils exposés
  nao_mcp.py ask "question"              # pose la question, attend la réponse
  nao_mcp.py answer <chatId>             # relit une réponse en cours
  nao_mcp.py call <tool> '{"k": "v"}'    # appel brut d'un outil
Sortie : JSON sur stdout (réponse, requêtes exécutées, url du chat).
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

CFG = Path.home() / ".config" / "nao"


def _cfg(name: str, env: str) -> str:
    v = os.environ.get(env)
    if v:
        return v
    return (CFG / name).read_text().strip()


URL = _cfg("mcp-url", "NAO_MCP_URL")
TOKEN = _cfg("mcp-token", "NAO_MCP_TOKEN")


class Mcp:
    def __init__(self) -> None:
        self.session: str | None = None
        self.n = 0
        self._rpc("initialize", {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "nao-context-tests", "version": "1"},
        })
        self._notify("notifications/initialized")

    def _headers(self) -> dict[str, str]:
        h = {
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            h["Mcp-Session-Id"] = self.session
        return h

    def _post(self, body: dict, timeout: int = 600) -> dict | None:
        req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=self._headers())
        with urllib.request.urlopen(req, timeout=timeout) as r:
            sid = r.headers.get("Mcp-Session-Id")
            if sid:
                self.session = sid
            raw = r.read().decode()
        result = None
        for line in raw.splitlines():
            if line.startswith("data:"):
                result = json.loads(line[5:].strip())
        if result is None and raw.strip():
            result = json.loads(raw)
        return result

    def _notify(self, method: str) -> None:
        self._post({"jsonrpc": "2.0", "method": method})

    def _rpc(self, method: str, params: dict) -> dict:
        self.n += 1
        res = self._post({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        if res is None:
            return {}
        if "error" in res:
            raise RuntimeError(json.dumps(res["error"], ensure_ascii=False))
        return res.get("result", {})

    def tools(self) -> list[dict]:
        return self._rpc("tools/list", {}).get("tools", [])

    def call(self, name: str, args: dict) -> dict:
        res = self._rpc("tools/call", {"name": name, "arguments": args})
        out: dict = {"isError": res.get("isError", False)}
        texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
        if res.get("structuredContent"):
            out["data"] = res["structuredContent"]
        else:
            joined = "\n".join(texts)
            try:
                out["data"] = json.loads(joined)
            except json.JSONDecodeError:
                out["data"] = joined
        return out

    def ask(self, question: str, poll: int = 10, max_wait: int = 900) -> dict:
        out = self.call("ask_nao", {"question": question})
        data = out["data"] if isinstance(out["data"], dict) else {}
        t0 = time.time()
        while data.get("status") == "running" and data.get("chatId") and time.time() - t0 < max_wait:
            time.sleep(poll)
            out = self.call("get_nao_answer", {"chatId": data["chatId"]})
            data = out["data"] if isinstance(out["data"], dict) else {}
        return out


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    m = Mcp()
    cmd = argv[1]
    if cmd == "tools":
        out = [{"name": t["name"], "description": t.get("description", "")[:200]} for t in m.tools()]
    elif cmd == "ask":
        out = m.ask(argv[2])
    elif cmd == "answer":
        out = m.call("get_nao_answer", {"chatId": argv[2]})
    elif cmd == "call":
        out = m.call(argv[2], json.loads(argv[3]) if len(argv) > 3 else {})
    else:
        print(__doc__)
        return 2
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
