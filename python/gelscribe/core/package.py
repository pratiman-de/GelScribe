"""A .gelscribe project: a folder holding project.json and a byte-for-byte copy of the original image, and of each
stacked gel's image (the Mac app shows it as one file). Images are written once, when added, and never rewritten.

Names of image files inside a project are unique ignoring case (and the way an accent is composed), because Mac and
Windows disks treat names that differ only like that as one file: a second gel stored as blot.png next to Blot.png would
be the same file, and taking it out again would delete the first gel's image."""
from __future__ import annotations

import hashlib
import json
import os
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

from . import ops
from .image import ImageError, SourceImage, WorkingImage, initial_display
from .model import GelProject, GelStrip

PROJECT_FILE = "project.json"
EXTENSION = ".gelscribe"
IMAGE_SUFFIXES = (".png", ".tif", ".tiff", ".jpg", ".jpeg", ".bmp", ".gif")


class ProjectError(Exception):
    pass


def is_project_path(p: Path) -> bool:
    p = Path(p)
    return p.name == PROJECT_FILE or p.suffix.lower() == EXTENSION


def is_image_path(p: Path) -> bool:
    return Path(p).suffix.lower() in IMAGE_SUFFIXES


def is_gelscribe_folder(folder: Path) -> bool:
    """Whether this is a .gelscribe package (the extension in any letter case), whose image copies GelScribe made
    itself. In any other folder that holds a project.json the images are the user's own: nothing in it is ever deleted."""
    return Path(folder).suffix.lower() == EXTENSION


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def name_key(name: str) -> str:
    """What file names inside a project are compared by: two names with the same key are one file on a Mac or PC."""
    return unicodedata.normalize("NFC", name).casefold()


def is_plain_name(name: str) -> bool:
    """A bare file name, which can only mean a file inside the project folder (never one somewhere else)."""
    return bool(name) and name not in (".", "..") and not any(c in name for c in "/\\\0")


def uses_image(project: GelProject, name: str) -> bool:
    """Whether the main image or any stacked gel is stored under this name (ignoring case)."""
    k = name_key(name)
    return name_key(project.image) == k or any(name_key(s.image) == k for s in project.strips)


def names_in(folder: Path) -> list[str]:
    """The file names already in a project folder (none if it isn't there yet), to keep new gels from clashing with them."""
    try:
        return [f.name for f in Path(folder).iterdir()]
    except OSError:
        return []


def exact_file(folder: Path, name: str) -> Optional[Path]:
    """The file in folder named exactly name: letter case counts (an accent composed either way doesn't). A disk that
    ignores case would hand folder / name the file blot.PNG for Blot.png, and the project would save as if it were fine;
    the Mac refuses it, so this does too."""
    key = unicodedata.normalize("NFC", name)
    for f in names_in(folder):
        if unicodedata.normalize("NFC", f) == key:
            return Path(folder) / f if (Path(folder) / f).is_file() else None
    return None


def _missing(folder: Path, name: str, what: str) -> ProjectError:
    like = [f for f in names_in(folder) if name_key(f) == name_key(name)]
    hint = f" (the folder has {like[0]}; names must match exactly, capital letters included)" if like else ""
    return ProjectError(f"Not a GelScribe project: the {what} {name} is missing from it{hint}")


def _unused_name(name: str, taken_keys: set) -> str:
    """name, or stem_1.ext, stem_2.ext … when its key is taken."""
    if name_key(name) not in taken_keys:
        return name
    stem, ext = Path(name).stem, Path(name).suffix
    n = 1
    while name_key(f"{stem}_{n}{ext}") in taken_keys:
        n += 1
    return f"{stem}_{n}{ext}"


def _has_content(path: Path, data: bytes) -> bool:
    try:
        return path.stat().st_size == len(data) and path.read_bytes() == data
    except OSError:
        return False


@dataclass
class GelPackage:
    project: GelProject
    image_data: bytes
    #: the stacked gels' images by file name (GelStrip.image), byte-for-byte
    strip_images: dict = field(default_factory=dict)

    def strip_data(self, k: int) -> Optional[bytes]:
        """Gel k's image bytes (its number in project.strips)."""
        if not 1 <= k <= len(self.project.strips):
            return None
        return self.strip_images.get(self.project.strips[k - 1].image)

    def add_strip(self, data: bytes, image_name: str, taken: Iterable[str] = (), strict: Optional[bool] = False) -> int:
        """Adds another gel at the bottom of the stack: its image copied in byte-for-byte under a name of its own,
        lined up at first with no shift. taken: other names to keep clear of, such as the files already in the project
        folder. strict: its own Keep original pixels setting, which is off for a new gel so that Auto-align can stretch it
        into line (None: the same as the gel with the lanes). Returns its number in strips."""
        source = SourceImage(data)   # refuses non-images up front
        name = Path(image_name).name
        if not name or name_key(name) == name_key(PROJECT_FILE):
            name = "gel.png"
        keys = {name_key(n) for n in [self.project.image, PROJECT_FILE, *(s.image for s in self.project.strips), *taken]}
        name = _unused_name(name, keys)
        strip = GelStrip(image=name, image_sha256=_sha(data), strict=strict)
        strip.display.bands_dark = self.project.display.bands_dark   # the same kind of scan: bands the same way round
        self.project.strips.append(strip)
        k = len(self.project.strips)
        strip.display = initial_display(WorkingImage(source, self.project.strip_project(k)))
        strip.display.bands_dark = self.project.display.bands_dark
        self.strip_images[name] = bytes(data)
        return k

    def remove_strip(self, k: int) -> Optional[str]:
        """Takes gel k out, with its ticks and names (ops.remove_strip). Returns the name of its copy to delete from the
        project folder, or None when nothing should be deleted: another gel (or the main image) is stored under that
        name, ignoring case. The original file the gel came from is never touched."""
        if not 1 <= k <= len(self.project.strips):
            return None
        name = self.project.strips[k - 1].image
        ops.remove_strip(self.project, k)
        if all(s.image != name for s in self.project.strips):
            self.strip_images.pop(name, None)
        return None if uses_image(self.project, name) or not is_plain_name(name) else name

    def strip_intact(self, k: int) -> Optional[bool]:
        """Like image_intact, for gel k."""
        if not 1 <= k <= len(self.project.strips) or self.project.strips[k - 1].image_sha256 is None:
            return None
        d = self.strip_data(k)
        return d is not None and _sha(d) == self.project.strips[k - 1].image_sha256

    @staticmethod
    def create(image_data: bytes, image_name: str) -> "GelPackage":
        """A new, empty project around an image. Nothing is detected: the user places lanes and bands."""
        source = SourceImage(image_data)   # refuses non-images up front
        name = Path(image_name).name
        if not name or name_key(name) == name_key(PROJECT_FILE):
            name = "image" + (Path(image_name).suffix or ".png")
        project = GelProject(image=name, image_sha256=hashlib.sha256(image_data).hexdigest(), title=Path(name).stem)
        # like ImageJ, open 16-bit scans with a usable contrast (screen only while Strict is on)
        project.display = initial_display(WorkingImage(source, project))
        return GelPackage(project, image_data)

    @staticmethod
    def create_from(path: Path) -> "GelPackage":
        return GelPackage.create(Path(path).read_bytes(), Path(path).name)

    @staticmethod
    def read(path: Path) -> "GelPackage":
        """A .gelscribe folder, its project.json, or a bare JSON config whose image path is relative to it."""
        path = Path(path)
        folder = path if path.is_dir() else path.parent if path.name == PROJECT_FILE else None
        where = PROJECT_FILE if folder is not None else path.name
        try:
            if folder is not None:
                pj = folder / PROJECT_FILE
                if not pj.is_file():
                    raise ProjectError("Not a GelScribe project: no project.json")
                project = GelProject.loads(pj.read_text(encoding="utf-8"))
                if not project.image:
                    raise ProjectError("Not a GelScribe project: it names no image")
                for n in [project.image] + [s.image for s in project.strips]:
                    if not is_plain_name(n):
                        raise ProjectError(f"Not a GelScribe project: {n or 'an image'} isn't a plain file name; "
                                           "a project's images sit in its folder")
                img = exact_file(folder, project.image)
                if img is None:
                    raise _missing(folder, project.image, "image")
                return GelPackage(project, img.read_bytes(), GelPackage._strips_in(project, folder))
            project = GelProject.loads(path.read_text(encoding="utf-8"))
            if not project.image:
                raise ProjectError("Not a GelScribe project: it names no image")
            img = exact_file(path.parent, project.image)
            if img is None:
                raise _missing(path.parent, project.image, "image")
            return GelPackage(project, img.read_bytes(), GelPackage._strips_in(project, path.parent))
        except json.JSONDecodeError as e:
            raise ProjectError(f"Not a GelScribe project: {where} isn't valid JSON ({e.msg}, line {e.lineno})") from e
        except UnicodeDecodeError as e:
            raise ProjectError(f"Not a GelScribe project: {where} isn't a text file") from e
        except (ValueError, KeyError, TypeError, AttributeError, IndexError, RecursionError) as e:
            raise ProjectError(f"Not a GelScribe project: {e}") from e

    @staticmethod
    def _strips_in(project: GelProject, folder: Path) -> dict:
        out = {}
        for s in project.strips:
            f = exact_file(folder, s.image)
            if f is None:
                raise _missing(folder, s.image, "gel image")
            out[s.image] = f.read_bytes()
        return out

    @staticmethod
    def project_folder(path: Path) -> Path:
        path = Path(path)
        return path.parent if path.name == PROJECT_FILE else path

    def write(self, folder: Path) -> None:
        """Writes project.json atomically. An image is copied in only if the folder doesn't have it yet. Everything is
        checked before anything is written, and a failure part way leaves no image copies behind."""
        folder = Path(folder)
        p = self.project
        names = [p.image] + [s.image for s in p.strips]
        for n in names:
            if not is_plain_name(n):
                raise ProjectError(f"{n or 'An image'} isn't a plain file name; a project's images sit in its folder")
        keys = {name_key(PROJECT_FILE): PROJECT_FILE}
        for n in names:
            other = keys.setdefault(name_key(n), n)
            if other != n:
                raise ProjectError(f"{n} and {other} differ only in capital letters, so on a Mac or PC they are one file; "
                                   "remove one gel and add it again")
        if folder.exists() and not folder.is_dir():
            raise ProjectError(f"{folder} is a file, not a project folder")
        present = names_in(folder)
        todo: list[tuple[str, bytes]] = []
        for n, data in [(p.image, self.image_data)] + [(s.image, self.strip_images.get(s.image)) for s in p.strips]:
            if data is None or any(n == t for t, _ in todo):
                continue
            like = [f for f in present if name_key(f) == name_key(n)]
            if n in like or (like and (folder / n).exists()):
                # already there, and a disk that ignores case sees a differently capitalised name as this same file: it
                # must be this image, never a leftover of another one with the same name
                if not _has_content(folder / n, data):
                    raise ProjectError(f"{n} in the project is a different image; add the gel under another name")
            elif like:
                raise ProjectError(f"{like[0]} in the project folder differs from {n} only in capital letters; "
                                   "add the gel under another name")
            else:
                todo.append((n, data))
        made_folder = not folder.exists()
        created: list[Path] = []
        try:
            folder.mkdir(parents=True, exist_ok=True)
            for n, data in todo:
                tmp = folder / (n + ".tmp")
                tmp.write_bytes(data)
                os.replace(tmp, folder / n)
                created.append(folder / n)
            tmp = folder / (PROJECT_FILE + ".tmp")
            tmp.write_text(self.project.dumps() + "\n", encoding="utf-8")
            os.replace(tmp, folder / PROJECT_FILE)
        except BaseException:
            for f in [folder / (n + ".tmp") for n, _ in todo] + [folder / (PROJECT_FILE + ".tmp")] + created:
                try:
                    f.unlink()
                except OSError:
                    pass
            if made_folder:
                try:
                    folder.rmdir()
                except OSError:
                    pass
            raise

    @property
    def image_intact(self) -> Optional[bool]:
        """True when the image bytes still hash to what was recorded on import (None if nothing was recorded)."""
        if self.project.image_sha256 is None:
            return None
        return hashlib.sha256(self.image_data).hexdigest() == self.project.image_sha256


__all__ = ["GelPackage", "ProjectError", "ImageError", "PROJECT_FILE", "EXTENSION", "is_project_path", "is_image_path",
           "is_gelscribe_folder", "name_key", "is_plain_name", "uses_image", "names_in"]
