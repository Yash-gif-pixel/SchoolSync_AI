"""Sample documents for the document-reader tests.

The forms this project was developed against are photographs of real
children's admission paperwork, so they are not in the repository and never
will be. Every test that needs a form asks for one here instead: a real scan
out of `../samples` if somebody has put one there, and otherwise a generated
stand-in, so a clean clone can exercise the whole upload -> extract -> review
-> commit path with no fixture the repository cannot ship.

The generated form is typed rather than handwritten. That is deliberate: it is
not a test of handwriting recognition — the real scans cover that — it is there
to prove the pipeline. It does reproduce the two awkward features of the
original scan, because those are what the assertions are about:

  * a struck-through year of birth with the correction written beside it, so
    the reader has to prefer the correction rather than the first thing it sees;
  * no address line at all, so `present_on_form` has to come back false rather
    than the model inventing a plausible street.
"""

from __future__ import annotations

import datetime as dt
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent / "samples"
GENERATED = SAMPLES / "_generated"

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp"}

MIME_BY_SUFFIX = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}

#: What the generated admission form says, so a test can assert against the
#: source of truth instead of repeating string literals that drift.
ADMISSION_ANSWERS = {
    "full_name": "Manjeet Singh",
    "date_of_birth": "2014-03-10",
    "struck_date_of_birth": "1979-03-10",
    "gender": "M",
    "class_applying_for": "8",
    "guardian_name": "Jagdarshan Lal",
    "guardian_phone": "9866421801",
    "address": None,  # deliberately not on the form
    "previous_school": "Daffodil High School",
    "admission_date": "2026-04-10",
}


def real_samples() -> list[Path]:
    """Photographs a human has dropped into ../samples, newest first.

    `_generated` is skipped: those are this module's own output, and feeding
    them back in as "real" scans would quietly turn an empty fixtures folder
    into a test that only ever reads its own handwriting.
    """
    if not SAMPLES.is_dir():
        return []
    return sorted(
        p for p in SAMPLES.iterdir()
        if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES
    )


def mime_for(path: Path | str) -> str:
    return MIME_BY_SUFFIX.get(Path(path).suffix.lower(), "image/jpeg")


# --------------------------------------------------------------- rendering
def _font(size: int, bold: bool = False):
    """A legible font at the size asked for, whatever the machine has.

    Pillow's built-in bitmap font is roughly 11px and cannot be scaled on
    older releases, which renders a 1000px form as an unreadable smudge and
    makes an extraction failure look like a model problem. Try real TrueType
    faces first and only fall back when there is nothing installed.
    """
    from PIL import ImageFont

    candidates = (
        ["arialbd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"]
        if bold else
        ["arial.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf"]
    )
    for name in candidates:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)  # Pillow >= 10.1
    except TypeError:
        return ImageFont.load_default()


def admission_form_png(answers: dict | None = None) -> bytes:
    """Render a filled-in admission form as a PNG.

    Field labels match the built-in "Example Admission Form" template in
    db/003_templates.sql, so the extraction has something to align to.
    """
    from PIL import Image, ImageDraw

    a = {**ADMISSION_ANSWERS, **(answers or {})}

    def as_ddmmyyyy(iso: str | None) -> str:
        if not iso:
            return ""
        return dt.date.fromisoformat(iso).strftime("%d/%m/%Y")

    W, H = 1000, 1320
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    title = _font(34, bold=True)
    subtitle = _font(20)
    label = _font(22)
    value = _font(24)
    small = _font(17)

    d.rectangle([28, 28, W - 28, H - 28], outline="black", width=3)

    d.text((60, 62), "SUNRISE PUBLIC SCHOOL", font=title, fill="black")
    d.text((60, 108), "Secunderabad  ·  Affiliated to CBSE", font=small, fill="black")
    d.line([(60, 146), (W - 60, 146)], fill="black", width=2)
    d.text((60, 166), "APPLICATION FOR ADMISSION", font=subtitle, fill="black")

    # (label, value, key) — address is absent from the form on purpose, so it
    # is simply not in this list.
    rows = [
        ("Student Name", a["full_name"], "full_name"),
        ("Date of Birth", as_ddmmyyyy(a["date_of_birth"]), "date_of_birth"),
        ("Gender", "M / F" if a["gender"] is None else a["gender"], "gender"),
        ("Class Applying For", a["class_applying_for"], "class_applying_for"),
        ("Guardian Name", a["guardian_name"], "guardian_name"),
        ("Guardian Phone", a["guardian_phone"], "guardian_phone"),
        ("Previous School", a["previous_school"], "previous_school"),
        ("Date of Admission", as_ddmmyyyy(a["admission_date"]), "admission_date"),
    ]

    y = 232
    for text, val, key in rows:
        d.text((70, y), f"{text}", font=label, fill="black")
        d.text((430, y), ":", font=label, fill="black")

        if key == "date_of_birth" and a.get("struck_date_of_birth"):
            # The correction the reader has to notice: the wrong year written
            # first, ruled through, and the right one added after it.
            wrong = as_ddmmyyyy(a["struck_date_of_birth"])
            d.text((460, y), wrong, font=value, fill="black")
            box = d.textbbox((460, y), wrong, font=value)
            mid = (box[1] + box[3]) // 2
            d.line([(box[0] - 4, mid), (box[2] + 4, mid)], fill="black", width=3)
            d.text((box[2] + 34, y), val, font=value, fill="black")
            d.text((box[2] + 34, y + 34), "(corrected)", font=small, fill="black")
        else:
            d.text((460, y), str(val), font=value, fill="black")

        d.line([(455, y + 34), (W - 80, y + 34)], fill="black", width=1)
        y += 96

    d.text((70, y + 30),
           "I declare that the information given above is true.",
           font=small, fill="black")
    d.text((70, y + 74), "Signature of Parent / Guardian: J. Lal",
           font=small, fill="black")

    GENERATED.mkdir(parents=True, exist_ok=True)
    path = GENERATED / "admission_form.png"
    img.save(path)
    return path.read_bytes()


# ------------------------------------------------------------------- pick
def admission_sample(prefer: str | None = None) -> tuple[str, bytes, str]:
    """(filename, bytes, mime) for one filled admission form.

    Prefers a real scan so the assertions still run against handwriting where
    a fixture exists; generates one when the folder is empty, which is the
    normal case for anybody who has just cloned this.

    `prefer` names the specific scan a caller's assertions were written about.
    When it is given, an unrelated photograph sitting in the folder does NOT
    count — it would fail those assertions and look like a model regression
    rather than the wrong fixture.
    """
    for p in real_samples():
        if prefer is None or prefer.lower() in p.name.lower():
            return p.name, p.read_bytes(), mime_for(p)
    return "admission_form.png", admission_form_png(), "image/png"


def leave_note_png(teacher_name: str, start: dt.date, end: dt.date,
                   reason: str) -> bytes:
    """Render a plausible medical certificate as a PNG.

    Typed rather than handwritten — this is about the pipeline, not about
    re-testing handwriting recognition, which the admission-form samples
    already cover.
    """
    from PIL import Image, ImageDraw

    W, H = 1000, 760
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    d.rectangle([30, 30, W - 30, H - 30], outline="black", width=3)

    heading = _font(30, bold=True)
    body = _font(23)
    small = _font(18)

    d.text((70, 62), "CITY CLINIC", font=heading, fill="black")
    d.text((70, 104), "12 MG Road, Secunderabad", font=small, fill="black")
    d.line([(70, 140), (W - 70, 140)], fill="black", width=2)
    d.text((70, 160), "MEDICAL CERTIFICATE", font=_font(24, bold=True), fill="black")

    rows = [
        ("Teacher Name", teacher_name),
        ("Leave From", start.strftime("%d/%m/%Y")),
        ("Leave To", end.strftime("%d/%m/%Y")),
        ("Reason", reason),
    ]
    y = 232
    for text, val in rows:
        d.text((70, y), text, font=body, fill="black")
        d.text((350, y), ":", font=body, fill="black")
        d.text((390, y), val, font=body, fill="black")
        y += 68

    d.text((70, y + 24),
           "The above named is advised rest for the period stated.",
           font=small, fill="black")
    d.text((70, y + 76), "Signed: Dr A. Kumar", font=small, fill="black")

    GENERATED.mkdir(parents=True, exist_ok=True)
    path = GENERATED / "leave_note.png"
    img.save(path)
    return path.read_bytes()


def portrait_png(label: str = "AB", size: tuple[int, int] = (900, 1200)) -> bytes:
    """A stand-in passport photo: a coloured card with initials on it.

    Deliberately not square and deliberately large, so a test can tell that
    the server really did crop and shrink it rather than storing the upload.
    """
    from PIL import Image, ImageDraw

    img = Image.new("RGB", size, (34, 84, 140))
    d = ImageDraw.Draw(img)
    d.ellipse(
        [size[0] * 0.2, size[1] * 0.15, size[0] * 0.8, size[1] * 0.6],
        fill=(232, 216, 198),
    )
    d.text((size[0] * 0.42, size[1] * 0.72), label, font=_font(90, bold=True),
           fill="white")

    GENERATED.mkdir(parents=True, exist_ok=True)
    path = GENERATED / "portrait.png"
    img.save(path)
    return path.read_bytes()


def all_admission_samples() -> list[tuple[str, bytes, str]]:
    """Every real scan available, or the one generated form if there are none."""
    found = [(p.name, p.read_bytes(), mime_for(p)) for p in real_samples()]
    return found or [admission_sample()]


if __name__ == "__main__":  # a quick look at what the tests will send
    name, data, mime = admission_sample()
    print(f"{name}  {len(data):,} bytes  {mime}")
    if not real_samples():
        print(f"generated -> {GENERATED / 'admission_form.png'}")
    else:
        print(f"using real scans from {SAMPLES}")
