#!/usr/bin/env python3
"""Grade erlexec skill eval outputs by pattern-matching assertions."""
import json, re, pathlib
ROOT = pathlib.Path(__file__).parent

def read_code(d):
    return "\n".join(p.read_text() for p in d.glob("*.ex"))

def read_text(d):
    return "\n".join(p.read_text() for p in list(d.glob("approach.md")) + list(d.glob("answer.md")))

def grade_assertion(a, code, text):
    kind, pat = a["type"], a["pattern"]
    if kind == "regex_in_code":
        m = re.search(pat, code, re.IGNORECASE)
        return {"text": a["text"], "passed": bool(m),
                "evidence": (m.group(0)[:200] if m else "not found in code")}
    if kind == "regex_not_in_code":
        ms = re.findall(pat, code, re.IGNORECASE)
        return {"text": a["text"], "passed": len(ms) == 0,
                "evidence": "no match (good)" if not ms else f"found: {ms[:3]}"}
    if kind == "substring_in_answer":
        ok = pat.lower() in text.lower()
        return {"text": a["text"], "passed": ok,
                "evidence": "substring present" if ok else "substring missing"}
    if kind == "regex_not_in_answer":
        ms = re.findall(pat, text, re.IGNORECASE)
        return {"text": a["text"], "passed": len(ms) == 0,
                "evidence": "no match (good)" if not ms else f"found: {ms[:3]}"}
    return {"text": a["text"], "passed": False, "evidence": f"unknown assertion kind {kind}"}

def grade_run(ed, cfg):
    meta = json.loads((ed / "eval_metadata.json").read_text())
    out = ed / cfg / "outputs"
    code = read_code(out)
    text = read_text(out)
    exps = [grade_assertion(a, code, text) for a in meta["assertions"]]
    g = {"eval_id": meta["eval_id"], "eval_name": meta["eval_name"], "config": cfg,
         "expectations": exps,
         "passed": sum(1 for e in exps if e["passed"]), "total": len(exps)}
    (ed / cfg / "grading.json").write_text(json.dumps(g, indent=2))
    return g

def main():
    results = []
    for ed in sorted(ROOT.iterdir()):
        if not ed.is_dir() or not ed.name.startswith("eval-"):
            continue
        for cfg in ("with_skill", "without_skill"):
            if (ed / cfg / "outputs").exists():
                r = grade_run(ed, cfg)
                results.append(r)
                print(f"{ed.name}/{cfg}: {r['passed']}/{r['total']}")
    (ROOT / "grading_summary.json").write_text(json.dumps(results, indent=2))

if __name__ == "__main__":
    main()
