r"""Run extraction + validation over the sample forms and print a readable report.

    python test_extract.py                  # all images in ../samples
    python test_extract.py path\to\one.jpg  # a single file
"""

from __future__ import annotations

import json
import mimetypes
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from app.services.document_ai import extract_admission_form  # noqa: E402
from app.services.validation import validate  # noqa: E402

SAMPLES = Path(__file__).resolve().parent.parent / "samples"

GREEN, AMBER, RED, GREY, RESET = "\033[92m", "\033[93m", "\033[91m", "\033[90m", "\033[0m"


def report(path: Path) -> dict:
    print(f"\n{'=' * 78}\n{path.name}\n{'=' * 78}")

    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    t0 = time.time()
    raw = extract_admission_form(path.read_bytes(), mime)
    result = validate(raw)
    elapsed = time.time() - t0

    print(f"  admission form : {result['is_admission_form']}")
    print(f"  image quality  : {result['document_quality']}"
          + (f" — {result['quality_note']}" if result.get("quality_note") else ""))
    print(f"  extracted in   : {elapsed:.1f}s\n")

    print(f"  {'field':<20} {'value':<30} {'conf':>5}  state")
    print(f"  {'-' * 70}")
    for f in result["fields"]:
        name = f["field"]
        if not f["present_on_form"]:
            state, colour = "absent from form", GREY
        elif f["value"] is None:
            state, colour = "ILLEGIBLE", RED
        elif f["confidence"] < 0.85:
            state, colour = "review", AMBER
        else:
            state, colour = "ok", GREEN
        val = (f["value"] or "—")[:29]
        print(f"  {colour}{name:<20} {val:<30} {f['confidence']:>5.2f}  {state}{RESET}")
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


def main() -> int:
    if len(sys.argv) > 1:
        paths = [Path(sys.argv[1])]
    else:
        paths = sorted(
            p for p in SAMPLES.iterdir()
            if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}
        )

    if not paths:
        print(f"No images found in {SAMPLES}")
        return 1

    results = []
    for p in paths:
        try:
            results.append(report(p))
        except Exception as e:
            print(f"\n{RED}FAILED on {p.name}: {type(e).__name__}: {e}{RESET}")

    print(f"\n{'=' * 78}\nSUMMARY — {len(results)}/{len(paths)} extracted")
    for p, r in zip(paths, results):
        name = next((f["value"] for f in r["fields"] if f["field"] == "full_name"), None)
        print(f"  {p.name[:44]:<46} {name or '?':<18} "
              f"{r['error_count']}E {r['warning_count']}W")

    out = SAMPLES.parent / "api" / "last_extraction.json"
    out.write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(f"\nFull JSON -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
