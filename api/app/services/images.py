"""Turning a photograph from a phone into something a roster can display.

Three things happen here, and only one of them is about file size:

* **Metadata is discarded.** A photo taken on a phone carries EXIF, and EXIF
  routinely carries GPS coordinates. Storing a child's portrait with the
  location it was taken at is a thing to avoid on purpose, not by luck.
* **Orientation is applied, then dropped.** Phone cameras record the sensor
  image plus a rotation flag. Browsers respect that flag inconsistently, so
  the rotation is baked into the pixels and the flag removed. Without this,
  perfectly good portraits appear sideways in the register.
* **It is made small.** The roster shows a 38-pixel circle. Sending a 12 MB
  original for that, forty-five times a page, is what makes a register feel
  broken on school wifi.
"""

from __future__ import annotations

import io

from PIL import Image, ImageOps

#: Big enough for a detail view on a high-density screen, small enough that a
#: whole class of them is a few hundred kilobytes.
PORTRAIT_PX = 320

JPEG_QUALITY = 82


class NotAnImage(ValueError):
    """The upload could not be decoded as an image."""


def portrait_jpeg(data: bytes, size: int = PORTRAIT_PX) -> bytes:
    """A square, upright, metadata-free JPEG thumbnail.

    Cropped from the centre rather than squashed: a face squashed to a square
    is worse than a face with its shoulders trimmed, and the centre is where
    the subject of a portrait is.
    """
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except Exception as e:  # noqa: BLE001 — Pillow raises many types here
        raise NotAnImage(f"That file could not be read as an image ({e}).")

    # Applies the EXIF rotation to the pixels and removes the tag.
    img = ImageOps.exif_transpose(img)

    # Flatten transparency onto white; a PNG with an alpha channel cannot be
    # saved as JPEG, and a black background is not what anyone meant.
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        flat = Image.new("RGB", img.size, "white")
        flat.paste(img, mask=img.split()[-1])
        img = flat
    else:
        img = img.convert("RGB")

    img = ImageOps.fit(img, (size, size), method=Image.LANCZOS,
                       centering=(0.5, 0.4))

    out = io.BytesIO()
    # No exif= argument, so nothing from the original is carried over.
    img.save(out, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return out.getvalue()
