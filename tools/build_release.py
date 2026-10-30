"""Build the allowlisted Workshop folder, release ZIP and checksum."""
from pathlib import Path
import hashlib
import re
import shutil
import zipfile

source = Path(__file__).resolve().parents[1]
info = (source / "modinfo.lua").read_text(encoding="utf-8")
version = re.search(r'version\s*=\s*"([^"]+)"', info).group(1)
assert re.search(r"^forcemanifest\s*=\s*false\s*$", info, re.M)
dist = source / "dist"
payload = dist / source.name
files = [source / name for name in (
    "modinfo.lua", "modmain.lua", "README.md", "CHANGELOG.md", "DESIGN.md",
    "assets/workshop-preview.jpg")]
files += sorted((source / "scripts").rglob("*.lua"))
assert all(path.is_file() for path in files)
assert 0 < (source / "assets/workshop-preview.jpg").stat().st_size < 1000000
expected = {path.relative_to(source) for path in files}
assert payload.parent == dist and payload.name == source.name
if payload.exists():
    shutil.rmtree(payload)
for path in files:
    dest = payload / path.relative_to(source)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
    assert dest.read_bytes() == path.read_bytes()
archive = dist / f"{source.name}_v{version}.zip"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
    for path in files:
        package.write(path, f"{source.name}/" + path.relative_to(source).as_posix())
with zipfile.ZipFile(archive) as package:
    assert package.testzip() is None and len(package.namelist()) == len(files)
    for path in files:
        assert package.read(f"{source.name}/" + path.relative_to(source).as_posix()) == path.read_bytes()
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix(".zip.sha256").write_text(digest + "  " + archive.name + "\n", encoding="ascii")
print(f"WORKSHOP_FOLDER {payload}")
print(f"RELEASE_ZIP {archive}")
print(f"FILES {len(files)} SHA256 {digest}")
