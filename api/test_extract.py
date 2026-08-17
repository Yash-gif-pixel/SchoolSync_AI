r"""Run extraction + validation over sample forms and print a readable report.

    python test_extract.py                    # every sample, or a generated one
    python test_extract.py path\to\one.jpg    # a single file
    python test_extract.py --template "Medical / Leave Note"

Extraction is template-driven: the field list, the prompt and the response
schema all come from a row in `document_templates`, exactly as they do in the
API. This script therefore reads the same template the server would, rather
than a hardcoded admission-form schema, and reports against it.

If ../samples is empty — it is gitignored, because those scans are real
children's paperwork — a stand-in form is generated. See sample_forms.py.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from app.routers.documents import _load_template, _validation_context  # noqa: E402
from app.services.document_ai import extract  # noqa: E402
from app.services.validation import validate  # noqa: E402
from sample_forms import SAMPLES, admission_sample, mime_for, real_samples  # noqa: E402

GREEN, AMBER, RED, GREY, RESET = "\033[92m", "\033[93m", "\033[91m", "\033[90m", "\033[0m"


def _template_named(name: str | None) -> dict:
    """The template to read against: the named one, or the built-in default."""
    if not name:
        return _load_template(None)

    from app.db import admin

    rows = (admin().table("document_templates").select("*")
            .eq("name", name).limit(1).execute().data)
    if not rows:
        available = [
            t["name"] for t in
            admin().table("document_templates").select("name").execute().data
        ]
        raise SystemExit(
            f"No template called {name!r}. Available: {', '.join(available)}"
        )
    return rows[0]


def report(name: str, data: bytes, mime: str, template: dict,
           context: dict) -> dict:
    print(f"\n{'=' * 78}\n{name}\n{'=' * 78}")

    t0 = time.time()
    raw = extract(data, template, mime)
    result = validate(raw, template, context=context)
    elapsed = time.time() - t0

    specs = {f["key"]: f for f in template["fields"]}

    print(f"  template       : {template['name']} -> {template['target']}")
    print(f"  model          : {raw.get('_model')}")
    print(f"  right document : {result['matches_template']}")
    print(f"  image quality  : {result['document_quality']}"
          + (f" — {result['quality_note']}" if result.get("quality_note") else ""))
    print(f"  extracted in   : {elapsed:.1f}s\n")

    print(f"  {'field':<20} {'value':<30} {'conf':>5}  state")
    print(f"  {'-' * 70}")
    for f in result["fields"]:
        key = f["field"]
        if not f["present_on_form"]:
            state, colour = "absent from form", GREY
        elif f["value"] is None:
            state, colour = "ILLEGIBLE", RED
        elif f["confidence"] < 0.85:
            state, colour = "review", AMBER
        else:
            state, colour = "ok", GREEN
        label = specs.get(key, {}).get("label", key)
        val = (f["value"] or "—")[:29]
        print(f"  {colour}{label[:19]:<20} {val:<30} {f['confidence']:>5.2f}  {state}{RESET}")
        if f.get("note"):
            print(f"  {GREY}{'':<20} note: {f['note']}{RESET}")

    if result["issues"]:
        print(f"\n  {result['error_count']} error(s), {result['warning_count']} warning(s):")
        for i in result["issues"]:
            colour = RED if i["severity"] == "error" else AMBER
            print(f"    {colour}[{i['severity']:<7}] {i['field']}: {i['message']}{RESET}")
            if i.get("suggestion"):
                print(f"    {GREY}{'':<10}  -> {i['suggestion']}{RESET}")
    else:
        print(f"\n  {GREEN}clean — no issues{RESET}")

    print(f"\n  auto-committable: {result['can_auto_commit']}")
    return result


def _documents(paths: list[str]) -> list[tuple[str, bytes, str]]:
    """(name, bytes, mime) for everything this run should read."""
    if paths:
        out = []
        for p in paths:
            path = Path(p)
            if not path.is_file():
                raise SystemExit(f"No such file: {path}")
            out.append((path.name, path.read_bytes(), mime_for(path)))
        return out

    found = real_samples()
    if found:
        return [(p.name, p.read_bytes(), mime_for(p)) for p in found]

    print(f"{GREY}No images in {SAMPLES} — reading a generated form instead. "
          f"Drop real scans there to test handwriting.{RESET}")
    return [admission_sample()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("images", nargs="*", help="specific files to read")
    ap.add_argument("--template", help="template name (default: the built-in one)")
    args = ap.parse_args()

    template = _template_named(args.template)
    context = _validation_context(template)
    documents = _documents(args.images)

    results: list[tuple[str, dict]] = []
    for name, data, mime in documents:
        try:
            results.append((name, report(name, data, mime, template, context)))
        except Exception as e:
            print(f"\n{RED}FAILED on {name}: {type(e).__name__}: {e}{RESET}")

    print(f"\n{'=' * 78}\nSUMMARY — {len(results)}/{len(documents)} extracted")
    first_key = template["fields"][0]["key"]
    for name, r in results:
        headline = next(
            (f["value"] for f in r["fields"] if f["field"] == first_key), None)
        print(f"  {name[:44]:<46} {headline or '?':<18} "
              f"{r['error_count']}E {r['warning_count']}W")

    out = Path(__file__).with_name("last_extraction.json")
    out.write_text(
        json.dumps([r for _, r in results], indent=2), encoding="utf-8")
    print(f"\nFull JSON -> {out}")

    # A file that could not be read at all is a failure; issues found inside a
    # document are the point of the exercise and are not.
    return 0 if len(results) == len(documents) else 1


if __name__ == "__main__":
    sys.exit(main())
