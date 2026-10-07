#!/usr/bin/env python3
"""Banc de tests Nao : pose chaque question du dossier tests/ à l'agent (ask_nao via
MCP), exécute le SQL de référence (execute_sql, rôle nao_ro) et compare.

Format d'un test (tests/<nom>.yml) :
  name: structures_par_region
  prompt: Combien de structures administratives actives par région ?
  sql: |
    SELECT r.nom AS region, count(*) AS n FROM ... GROUP BY 1
  kind: scalar | table        # scalar = un seul nombre ; table = libellé → nombre
  rtol: 0.01                  # tolérance relative (défaut 0.5 %)
  tags: [tableau-de-bord, coop]

Comparaison :
  scalar : le nombre de référence doit apparaître dans la réponse texte (±rtol).
  table  : chaque libellé de la référence doit apparaître dans la réponse avec un
           nombre à ±rtol ; les libellés sont rapprochés sans accents ni casse.

Usage :
  nao_eval.py [-k motif] [-t tag] [-o rapport.json] [--model NOM]
Le modèle n'est pas sélectionnable par l'API : --model ne sert qu'à l'étiquette du
rapport (changer le modèle dans Nao, Réglages → Agent).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import unicodedata
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nao_mcp import Mcp  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
DB_ID = "postgres-inclusion-numerique"

NUM = re.compile(r"(?<![\w,.])-?(?:\d{1,3}(?:[ \u202f\u00a0,]\d{3})+|\d+)(?:[.,]\d+)?(?![\w])")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", str(s)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "", s.lower())


def _nums(text: str) -> list[float]:
    out = []
    for m in NUM.finditer(text):
        v = m.group(0).replace(" ", "").replace(" ", "").replace(" ", "")
        v = v.replace(",", ".") if v.count(",") == 1 and "." not in v else v.replace(",", "")
        try:
            out.append(float(v))
        except ValueError:
            pass
    return out


def _close(a: float, b: float, rtol: float) -> bool:
    return abs(a - b) <= max(rtol * abs(b), 0.5)


def _lines_with_label(text: str, label: str) -> list[str]:
    key = _norm(label)
    return [ln for ln in text.splitlines() if key and key in _norm(ln)]


def charger_tests(motif: str | None, tag: str | None, dossier: Path = TESTS) -> list[dict]:
    tests = []
    for p in sorted(Path(dossier).glob("*.y*ml")):
        t = yaml.safe_load(p.read_text())
        t.setdefault("name", p.stem)
        t.setdefault("kind", "scalar")
        t.setdefault("rtol", 0.005)
        if motif and motif not in t["name"]:
            continue
        if tag and tag not in (t.get("tags") or []):
            continue
        tests.append(t)
    return tests


def reference(m: Mcp, t: dict) -> list[dict]:
    r = m.call("execute_sql", {"sql_query": t["sql"], "database_id": DB_ID, "name": f"ref {t['name']}"})
    if r["isError"]:
        raise RuntimeError(f"SQL de référence en échec : {r['data']}")
    return r["data"]["data"]


def comparer(t: dict, ref: list[dict], texte: str) -> tuple[bool, list[str]]:
    rtol = float(t["rtol"])
    details: list[str] = []
    if t["kind"] == "scalar":
        if not ref or not ref[0]:
            return False, ["référence vide"]
        attendu = float(list(ref[0].values())[0])
        trouve = any(_close(x, attendu, rtol) for x in _nums(texte))
        details.append(f"attendu {attendu:g} — {'présent' if trouve else 'ABSENT'} dans la réponse")
        return trouve, details
    ok = True
    for row in ref:
        vals = list(row.values())
        label, attendu = vals[0], float(vals[1])
        lignes = _lines_with_label(texte, label)
        hit = any(_close(x, attendu, rtol) for ln in lignes for x in _nums(ln))
        if not hit:
            ok = False
            details.append(f"{label}: attendu {attendu:g}, {'ligne absente' if not lignes else 'valeur différente'}")
    if ok:
        details.append(f"{len(ref)} libellés concordants")
    return ok, details


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", dest="motif")
    ap.add_argument("-t", dest="tag")
    ap.add_argument("-x", dest="exclure", help="tag à exclure (ex. lourd)")
    ap.add_argument("-d", dest="dossier", default=str(TESTS), help="dossier de tests (défaut : tests/)")
    ap.add_argument("-o", dest="out", default="rapport_eval.json")
    ap.add_argument("--model", default="(modèle configuré dans Nao)")
    a = ap.parse_args()

    tests = [t for t in charger_tests(a.motif, a.tag, Path(a.dossier)) if not (a.exclure and a.exclure in (t.get("tags") or []))]
    if not tests:
        print("aucun test")
        return 2
    resultats = []
    for t in tests:
        t0 = time.time()
        try:
            rep = None
            for essai in range(3):
                try:
                    m = Mcp()  # session neuve : une session abîmée ne contamine pas la suite
                    ref = reference(m, t)
                    rep = m.ask(t["prompt"], max_wait=int(t.get("max_wait", 600)))
                    break
                except Exception as e:  # noqa: BLE001 — réseau, HTTP (IncompleteRead), MCP
                    if essai == 2:
                        raise
                    print(f"    relance {essai + 1} ({t['name']}) : {str(e)[:80]}", flush=True)
                    time.sleep(30)
            data = rep["data"] if isinstance(rep["data"], dict) else {}
            texte = data.get("text", "") if not rep["isError"] else str(rep["data"])
            ok, details = comparer(t, ref, texte)
            res = {
                "name": t["name"], "ok": ok, "details": details,
                "queries": len(data.get("queries", [])), "chatUrl": data.get("chatUrl"),
                "secondes": round(time.time() - t0), "texte": texte[:3000],
            }
        except Exception as e:  # noqa: BLE001
            res = {"name": t["name"], "ok": False, "details": [f"erreur : {e}"], "secondes": round(time.time() - t0)}
        resultats.append(res)
        print(f"{'OK ' if res['ok'] else 'KO '} {res['name']:40s} {res['secondes']:4d}s  {' | '.join(res['details'])[:160]}", flush=True)

    n_ok = sum(r["ok"] for r in resultats)
    print(f"\n{n_ok}/{len(resultats)} tests OK — modèle : {a.model}")
    Path(a.out).write_text(json.dumps({"model": a.model, "date": time.strftime("%Y-%m-%d %H:%M"),
                                       "ok": n_ok, "total": len(resultats), "tests": resultats},
                                      ensure_ascii=False, indent=2))
    return 0 if n_ok == len(resultats) else 1


if __name__ == "__main__":
    sys.exit(main())
