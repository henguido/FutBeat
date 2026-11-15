"""Attribute golden failures without thresholds or changing the failed test result."""
import argparse
import hashlib
import json
from pathlib import Path


def collect(root):
    root = Path(root).resolve()
    if not root.is_dir():
        raise ValueError("missing render directory")
    tests = sorted(root.rglob("*_testImage.png"))
    if not tests:
        raise ValueError("no failed renders")
    for reference in root.rglob("*_masterImage.png"):
        if not reference.with_name(reference.name.replace("_masterImage.png", "_testImage.png")).is_file():
            raise ValueError("reference without failed render")
    files = {}
    for test in tests:
        for path in (test, test.with_name(test.name.replace("_testImage.png", "_masterImage.png"))):
            if path.is_symlink() or not path.resolve().is_relative_to(root):
                raise ValueError("unsafe render path")
            data = path.read_bytes()
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("missing or invalid PNG")
            relative = path.relative_to(root).as_posix()
            files[relative] = hashlib.sha256(data).hexdigest()
    return files


def compare(head, base):
    try:
        head_files, base_files = collect(head), collect(base)
    except (OSError, ValueError) as error:
        return {"status": "INCOMPLETE", "reason": str(error)}, 2
    missing = sorted(head_files.keys() - base_files.keys())
    extra = sorted(base_files.keys() - head_files.keys())
    changed = sorted(name for name in head_files.keys() & base_files.keys()
                     if head_files[name] != base_files[name])
    equivalent = not (missing or extra or changed)
    return {"status": "EXACT_RENDER_MATCH" if equivalent else "UNATTRIBUTED_DIFFERENCE",
            "head_png_count": len(head_files), "base_png_count": len(base_files),
            "missing_in_base": missing, "extra_in_base": extra, "changed_bytes": changed,
            "head_sha256": head_files, "base_sha256": base_files,
            "scope": "these failed renders and references only; golden tests remain failed"}, 0 if equivalent else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("head")
    parser.add_argument("base")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result, code = compare(args.head, args.base)
    rendered = json.dumps(result, indent=2)
    print(rendered)
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    raise SystemExit(code)
