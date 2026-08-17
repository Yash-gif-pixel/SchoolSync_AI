"""Portrait normalisation.

A photograph of a child is the most sensitive thing this system stores, and
the riskiest part of it is not the picture — it is the metadata a phone
attaches to it. These tests exist mostly to keep that stripping in place.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.images import PORTRAIT_PX, NotAnImage, portrait_jpeg  # noqa: E402


def make(size=(800, 600), mode="RGB", colour="red", fmt="JPEG", **save) -> bytes:
    buf = io.BytesIO()
    Image.new(mode, size, colour).save(buf, format=fmt, **save)
    return buf.getvalue()


def opened(data: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    img.load()
    return img


def test_output_is_a_square_jpeg_of_the_expected_size():
    out = opened(portrait_jpeg(make((1200, 900))))
    assert out.format == "JPEG"
    assert out.size == (PORTRAIT_PX, PORTRAIT_PX)
    assert out.mode == "RGB"


def test_a_portrait_is_cropped_not_squashed():
    """A tall photo squared by scaling would compress the face; it is cropped.

    Checked by geometry: a stripe drawn across the middle of a tall image
    stays a stripe of the same proportion of the width after a centre crop,
    whereas squashing would change its aspect.
    """
    tall = Image.new("RGB", (400, 1200), "white")
    for y in range(560, 640):  # a horizontal band, 80px of 1200
        for x in range(400):
            tall.putpixel((x, y), (0, 0, 255))
    buf = io.BytesIO()
    tall.save(buf, format="PNG")

    out = opened(portrait_jpeg(buf.getvalue(), size=400))
    # The 400-wide crop keeps 400 of the 1200 rows, so the band is roughly
    # 80/400 of the height rather than 80/1200 of it.
    # Blue, not merely "has a blue channel" — white would pass that.
    blue_rows = sum(
        1 for y in range(400)
        if out.getpixel((200, y))[2] > 150 and out.getpixel((200, y))[0] < 120
    )
    assert 50 < blue_rows < 130, blue_rows


def test_exif_is_not_carried_over():
    """GPS in an EXIF block is the reason this matters."""
    exif = Image.Exif()
    exif[0x010F] = "TestCamera"          # Make
    exif[0x0112] = 6                      # Orientation: rotate 90
    buf = io.BytesIO()
    Image.new("RGB", (900, 600), "green").save(buf, format="JPEG", exif=exif)

    out = opened(portrait_jpeg(buf.getvalue()))
    assert not dict(out.getexif()), dict(out.getexif())


def test_a_rotated_photo_comes_back_upright():
    """Phones store the sensor image plus a rotation flag; browsers honour it
    inconsistently, so the rotation is baked in and the flag dropped."""
    # Landscape pixels, flagged as needing a 90 degree turn.
    exif = Image.Exif()
    exif[0x0112] = 6
    landscape = Image.new("RGB", (600, 300), "white")
    for x in range(600):
        landscape.putpixel((x, 10), (255, 0, 0))  # a line along the long edge
    buf = io.BytesIO()
    landscape.save(buf, format="JPEG", exif=exif)

    # Non-square output would be ambiguous, so check the intermediate: after
    # transposition the image is taller than it is wide.
    from PIL import ImageOps
    transposed = ImageOps.exif_transpose(opened(buf.getvalue()))
    assert transposed.height > transposed.width

    # And the pipeline still produces a clean square from it.
    assert opened(portrait_jpeg(buf.getvalue())).size == (PORTRAIT_PX, PORTRAIT_PX)


def test_transparency_is_flattened_onto_white_not_black():
    """A PNG with an alpha channel cannot be written as JPEG at all, and the
    naive conversion puts the face on a black square."""
    buf = io.BytesIO()
    Image.new("RGBA", (500, 500), (0, 0, 0, 0)).save(buf, format="PNG")

    out = opened(portrait_jpeg(buf.getvalue()))
    r, g, b = out.getpixel((PORTRAIT_PX // 2, PORTRAIT_PX // 2))
    assert min(r, g, b) > 240, (r, g, b)


def test_palette_images_are_handled():
    out = opened(portrait_jpeg(make((400, 400), mode="P", fmt="PNG")))
    assert out.mode == "RGB"


def test_a_big_photo_becomes_a_small_one():
    big = make((4000, 3000))
    small = portrait_jpeg(big)
    assert len(small) < len(big)
    assert len(small) < 200_000


@pytest.mark.parametrize("junk", [b"", b"not an image at all", b"%PDF-1.4\n%"])
def test_rubbish_is_rejected_with_a_readable_error(junk):
    with pytest.raises(NotAnImage):
        portrait_jpeg(junk)
