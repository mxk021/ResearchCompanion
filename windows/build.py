#!/usr/bin/env python3
"""Cross-package the Windows x64 candidate from reviewed local inputs."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from xml.etree import ElementTree
import zipfile


ROOT = Path(__file__).resolve().parent.parent
WINDOWS = ROOT / "windows"
APP = WINDOWS / "ResearchCompanion.Windows"
PROJECT = APP / "ResearchCompanion.Windows.csproj"
VERSION = ElementTree.parse(PROJECT).findtext("./PropertyGroup/Version")
PDFIUM_SHA256 = "ca7338ae7779b8b1b82f4580305c4d762d214f8df1d54b47647fe3cc75989ded"
RUNTIME_LICENSES = {
    "Microsoft.NETCore.App.Runtime.win-x64": ("LICENSE.TXT", "THIRD-PARTY-NOTICES.TXT"),
    "Microsoft.WindowsDesktop.App.Runtime.win-x64": ("LICENSE",),
    "Microsoft.Web.WebView2": ("LICENSE.txt", "NOTICE.txt"),
}


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True, **kwargs)


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def build_brand(destination):
    from PIL import Image, ImageChops

    destination.mkdir(parents=True, exist_ok=True)
    with Image.open(ROOT / "Resources" / "AppIcon.png") as source:
        master = source.convert("RGBA")
    if master.size != (1024, 1024):
        raise ValueError("Expected the checked-in 1024px icon master.")
    icon_sizes = [(size, size) for size in (16, 24, 32, 40, 48, 64, 96, 128, 256)]
    icon_name = destination / "ResearchCompanion.ico"
    master.save(icon_name, sizes=icon_sizes)
    with Image.open(icon_name) as icon:
        if set(icon.ico.sizes()) != set(icon_sizes):
            raise ValueError("The Windows app icon is missing a requested size.")

    # Follow the macOS template's white-tile removal and small-size stroke.
    coverage = []
    for red, green, blue, opacity in master.getdata():
        luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        ink = opacity * (1 - luminance) / 255
        t = min(1, max(0, (ink - 0.04) / 0.55))
        coverage.append(round(255 * t * t * (3 - 2 * t)))
    opacity = Image.frombytes("L", master.size, bytes(coverage))
    ink_box = opacity.getbbox()
    if not ink_box:
        raise ValueError("Could not derive the app's chrome mark.")
    glyph = opacity.crop(ink_box)
    scale = 200 / max(glyph.size)
    glyph = glyph.resize(tuple(round(side * scale) for side in glyph.size), Image.Resampling.LANCZOS)
    mask = Image.new("L", (256, 256))
    mask.paste(glyph, ((256 - glyph.width) // 2, (256 - glyph.height) // 2))
    expanded = mask
    for y in range(-5, 6):
        radius = math.isqrt(25 - y * y)
        for x in range(-radius, radius + 1):
            expanded = ImageChops.lighter(expanded, ImageChops.offset(mask, x, y))
    mark = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    mark.putalpha(expanded)
    mark.save(destination / "ResearchCompanionMark.png")

    # WPF maps local transcript files to an isolated HTTPS origin.
    entry = (ROOT / "Resources" / "Transcript" / "index.html").read_text(encoding="utf-8")
    if entry.count("img-src file:;") != 1:
        raise ValueError("The shared transcript image policy changed.")
    entry = entry.replace("img-src file:;", "img-src 'self';")
    font_style = '<style>:root { font-family: "Segoe UI", "Microsoft YaHei UI", sans-serif; }</style>'
    (destination / "index.html").write_text(entry.replace("</head>", f"  {font_style}\n</head>"), encoding="utf-8")


def pe_machine(path):
    with path.open("rb") as file:
        if file.read(2) != b"MZ":
            raise ValueError(f"{path.name} is not a PE executable.")
        file.seek(0x3c)
        pointer = struct.unpack("<I", file.read(4))[0]
        file.seek(pointer)
        if file.read(4) != b"PE\x00\x00":
            raise ValueError(f"{path.name} has an invalid PE signature.")
        return struct.unpack("<H", file.read(2))[0]


def copy_pdfium(source, payload):
    if digest(source) != PDFIUM_SHA256:
        raise ValueError("The SHA-256 of the Windows x64 PDFium 8165 input did not match.")
    notices = payload / "LicenseNotices" / "PDFium"
    notices.mkdir(parents=True, exist_ok=True)
    with tarfile.open(source, mode="r:gz") as archive:
        copies = {"bin/pdfium.dll": payload / "pdfium.dll", "LICENSE": notices / "distribution-MIT.txt"}
        for item in archive.getmembers():
            if item.name.startswith("licenses/") and item.isfile():
                copies[item.name] = notices / Path(item.name).name
        for filename, target in copies.items():
            member = archive.getmember(filename)
            if not member.isfile() or not 0 < member.size < 32 * 1024 * 1024:
                raise ValueError(f"Unexpected PDFium member {filename}.")
            with archive.extractfile(member) as data, target.open("xb") as out:
                shutil.copyfileobj(data, out)
    if pe_machine(payload / "pdfium.dll") != 0x8664:
        raise ValueError("Expected an x64 PDFium DLL.")


def copy_bridge(source, payload):
    bridge = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
    name, version = bridge["name"], bridge["version"]
    if not 0 < source.stat().st_size < 20 * 1024 * 1024:
        raise ValueError("Invalid public bridge archive size.")
    runtime_files = set()
    with tarfile.open(source, mode="r:gz") as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            if (not member.isfile() or not path.parts or path.parts[0] != "package" or
                    any(part.startswith(".") for part in path.parts)):
                raise ValueError(f"Unexpected public bridge entry {member.name}.")
            runtime_files.add(member.name)
        manifest = json.load(archive.extractfile("package/package.json"))
    if manifest["name"] != name or manifest["version"] != version or "package/lib/index.js" not in runtime_files:
        raise ValueError("Bridge archive did not match the public project manifest.")
    shutil.copyfile(source, payload / f"{name}-{version}.tgz")


def copy_runtime_notices(cache, payload):
    libraries = json.loads((payload / "ResearchCompanion.deps.json").read_text(encoding="utf-8"))["libraries"]
    by_name = {library.removeprefix("runtimepack.").rsplit("/", 1)[0].lower(): library.rsplit("/", 1)[1]
               for library in libraries}
    for package, notices in RUNTIME_LICENSES.items():
        key = package.lower()
        version = by_name.get(key)
        if not version:
            raise ValueError(f"Missing the pinned dependency {package} in the published manifest.")
        target = payload / "LicenseNotices" / package
        target.mkdir(parents=True)
        for notice in notices:
            shutil.copyfile(cache / key / version / notice, target / notice)


def verify_payload(payload):
    for entry in payload.rglob("*"):
        relative = entry.relative_to(payload)
        if entry.is_symlink() or any(part.startswith(".") for part in relative.parts):
            raise ValueError(f"Unexpected link or hidden file in package: {relative}")
        if entry.is_file() and entry.suffix.lower() in (".pdb", ".pem", ".key", ".pdf", ".sqlite", ".pfx"):
            raise ValueError(f"Unexpected data or debug artifact in package: {relative}")
    if pe_machine(payload / "ResearchCompanion.exe") != 0x8664:
        raise ValueError("The app executable is not Windows x64.")
    for relative in ("Transcript/ResearchCompanionMark.png", "Transcript/index.html", "WebView2Loader.dll"):
        if not (payload / relative).is_file():
            raise ValueError(f"Missing application payload: {relative}")
    if pe_machine(payload / "WebView2Loader.dll") != 0x8664:
        raise ValueError("The WebView2 loader is not Windows x64.")


def package(args):
    if VERSION is None or not re.fullmatch(r"\d+\.\d+\.\d+(?:\.\d+)?", VERSION):
        raise ValueError("Expected a Windows application version in the project file.")
    file_version = VERSION if VERSION.count(".") == 3 else f"{VERSION}.0"
    brand = args.brand_dir.resolve()
    build_brand(brand)
    if args.brand_only:
        print(brand)
        return
    if not args.pdfium_archive or not args.bridge_archive or not args.nuget_cache:
        raise ValueError("Provide --pdfium-archive, --bridge-archive and --nuget-cache to package.")
    assets = args.output.resolve()
    assets.mkdir(parents=True, exist_ok=True)
    name = f"ResearchCompanion-{VERSION}-win-x64-candidate-setup.exe"
    target = assets / name
    checksum = assets / (name + ".sha256")
    if target.exists() or checksum.exists():
        raise ValueError("Select an output directory without existing candidate artifacts.")

    with tempfile.TemporaryDirectory(prefix="rc-win-package-") as temp:
        scratch = Path(temp).resolve()
        payload = scratch / "payload"
        installer = scratch / name
        env = {**os.environ, "NUGET_PACKAGES": str(args.nuget_cache.resolve())}
        run(args.dotnet, "publish", PROJECT, "--self-contained", "--no-restore", "--disable-build-servers",
            "-c", "Release", "-r", "win-x64", "-o", payload, f"-p:BrandDir={brand}",
            "-p:DebugType=None", "-p:DebugSymbols=false", env=env)
        shutil.copytree(ROOT / "Resources" / "LicenseNotices", payload / "LicenseNotices", dirs_exist_ok=True)
        shutil.copyfile(ROOT / "Resources" / "ThirdPartyNotices.txt", payload / "ThirdPartyNotices.txt")
        shutil.copyfile(ROOT / "LICENSE", payload / "LICENSE")
        copy_runtime_notices(args.nuget_cache.resolve(), payload)
        copy_pdfium(args.pdfium_archive.resolve(), payload)
        copy_bridge(args.bridge_archive.resolve(), payload)
        addon = json.loads((ROOT / "zotero-context-bridge" / "manifest.json").read_text(encoding="utf-8"))
        xpi = payload / f"research-companion-context-{addon['version']}.xpi"
        run(sys.executable, "-X", "utf8", ROOT / "zotero-context-bridge" / "build.py", "--output", xpi)
        with zipfile.ZipFile(xpi) as distribution:
            if sorted(distribution.namelist()) != ["LICENSE", "bootstrap.js", "core.js", "manifest.json"] or distribution.testzip():
                raise ValueError("Unexpected Zotero extension packaging.")
        if (WINDOWS / "README.md").is_file():
            shutil.copyfile(WINDOWS / "README.md", payload / "Windows-README.md")
        (payload / "InstallReceipt.txt").write_text("Research Companion per-user payload\n", encoding="ascii")
        verify_payload(payload)
        run(
            args.makensis, "-V2", "-WX", "-INPUTCHARSET", "UTF8",
            f"-DVERSION={VERSION}",
            f"-DFILE_VERSION={file_version}",
            f"-DPAYLOAD_RECEIPT={payload / 'InstallReceipt.txt'}",
            f"-DPAYLOAD_FILES={payload / '*'}", f"-DOUTPUT={installer}",
            f"-DICON={brand / 'ResearchCompanion.ico'}", f"-DLICENSE={ROOT / 'LICENSE'}",
            WINDOWS / "installer" / "ResearchCompanion.nsi",
        )
        if pe_machine(installer) not in (0x014c, 0x8664):
            raise ValueError("Unexpected NSIS installer architecture.")
        with target.open("xb") as out, installer.open("rb") as source:
            shutil.copyfileobj(source, out)
        checksum.write_text(f"{digest(target)}  {name}\n", encoding="ascii")
    print(target)
    print(checksum)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--brand-only", action="store_true")
    parser.add_argument("--brand-dir", type=Path, default=APP / "obj" / "brand")
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--makensis", default="makensis")
    parser.add_argument("--nuget-cache", type=Path)
    parser.add_argument("--pdfium-archive", type=Path)
    parser.add_argument("--bridge-archive", type=Path)
    parser.add_argument("--output", type=Path, default=WINDOWS / "dist")
    package(parser.parse_args())
