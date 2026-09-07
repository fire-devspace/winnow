#!/usr/bin/env python3
"""Count committed files with one policy for both sides of a pull request."""

from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import io
import json
import pathlib
import subprocess
import tempfile

SCHEMA_VERSION = 1
POLICY_VERSION = 4
CLOC_VERSION = "2.10"
CLOC_SHA256 = "bf59272455172108072a0a106379f7509fd4349bdcfd85203bac038ccd286d83"
CATEGORIES = {
    "source": "App/library/CLI source",
    "tests": "Tests",
    "webpages": "Webpages",
    "tooling": "Tooling/infrastructure",
    "other": "Other text (nonblank lines)",
}
METRICS = ("files", "code", "comment", "blank", "nonblank", "lines", "source_loc")
GENERATED = {"Sources/BitcoinP2P/Protocol/FallbackPeersGenerated.swift"}
EXCLUDED_DIRS = {".build", ".swiftpm", "node_modules", "vendor", "vendored", "third_party", "build", "dist"}
TEST_DIRS = {"Tests", "AppTests", "UITests", "PlatformTests", "Fuzz", "tests"}
DATA_DIRS = {"vectors", "fixtures", "testdata", "corpus"}
SOURCE_EXTENSIONS = {".swift", ".c", ".h", ".m", ".mm", ".cc", ".cpp", ".rs", ".py", ".sh"}
TEXT_EXTENSIONS = {".md", ".txt", ".mediawiki", ".rst"}


def git(root: pathlib.Path, *arguments: str, **kwargs) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *arguments], **kwargs)


def resolve(root: pathlib.Path, ref: str) -> str:
    return git(root, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()


def category(path: str) -> str:
    item = pathlib.PurePosixPath(path)
    parts = item.parts
    is_test = any(part in TEST_DIRS for part in parts[:-1])
    if (is_test and any(part.lower() in DATA_DIRS for part in parts[:-1])) or parts[0].lower() in DATA_DIRS:
        return "other"
    if item.suffix.lower() in TEXT_EXTENSIONS or item.name in {"LICENSE", "Package.resolved"} or item.name.endswith(".lock"):
        return "other"
    if item.suffix.lower() in {".html", ".htm", ".css", ".js", ".mjs", ".jsx", ".tsx"}:
        return "webpages"
    if item.name in {"Package.swift", "project.yml", "Makefile", "Dockerfile", ".swiftlint.yml"}:
        return "tooling"
    if is_test:
        return "tests"
    if parts[0] in {"scripts", "infra", "libvirt"} or parts[:2] == (".github", "workflows"):
        return "tooling"
    if parts[:2] in {("Tools", "Debug"), ("Tools", "Generate")}:
        return "tooling"
    if item.suffix.lower() in SOURCE_EXTENSIONS:
        return "source"
    return "other"


def exclusion(path: str, mode: str) -> str:
    if mode == "120000":
        return "symlink"
    if mode == "160000":
        return "submodule"
    if path in GENERATED:
        return "generated source"
    if any(part.lower() in EXCLUDED_DIRS for part in pathlib.PurePosixPath(path).parts[:-1]):
        return "dependency/build output"
    return ""


def tracked_files(root: pathlib.Path, commit: str):
    entries = []
    for record in git(root, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if record:
            metadata, path = record.split(b"\t", 1)
            mode, _, oid = metadata.decode().split()
            entries.append((path.decode("utf-8"), mode, oid))
    entries.sort()
    objects = [oid for path, mode, oid in entries if not exclusion(path, mode)]
    stream = io.BytesIO(git(root, "cat-file", "--batch", input="".join(oid + "\n" for oid in objects).encode()))
    for path, mode, oid in entries:
        reason = exclusion(path, mode)
        if reason:
            yield path, reason, None
            continue
        actual_oid, kind, size = stream.readline().split()
        if actual_oid.decode() != oid or kind != b"blob":
            raise ValueError("Unexpected object in Git blob stream")
        content = stream.read(int(size))
        if len(content) != int(size) or stream.read(1) != b"\n":
            raise ValueError("Truncated Git blob stream")
        yield path, "", content


def blank_metrics() -> dict:
    return dict.fromkeys(METRICS, 0)


def aggregate(files: list[dict], key: str, names=()) -> dict:
    groups = {name: blank_metrics() for name in names}
    for file in files:
        if file["status"] == "excluded":
            continue
        total = groups.setdefault(file[key], blank_metrics())
        total["files"] += 1
        for metric in METRICS[1:]:
            total[metric] += file[metric]
    return dict(sorted(groups.items()))


def validate_counter(cloc: pathlib.Path) -> None:
    if hashlib.sha256(cloc.read_bytes()).hexdigest() != CLOC_SHA256:
        raise ValueError("cloc checksum mismatch; use the official cloc-2.10.pl release asset")
    version = subprocess.check_output(["perl", str(cloc), "--version"], text=True).strip()
    if version != CLOC_VERSION:
        raise ValueError("Unexpected cloc version: " + version)


def snapshot(root: pathlib.Path, commit: str, cloc: pathlib.Path) -> dict:
    files = []
    with tempfile.TemporaryDirectory(prefix="loc-") as directory:
        inputs = pathlib.Path(directory) / "inputs"
        inputs.mkdir()
        counters = {}
        for index, (path, reason, content) in enumerate(tracked_files(root, commit)):
            file = {"path": path, "category": category(path), "language": "Text", "status": "counted", "reason": "", **blank_metrics()}
            if content is not None:
                if content.split(b"\n", 1)[0].rstrip(b"\r") == b"version https://git-lfs.github.com/spec/v1":
                    reason = "LFS pointer"
                elif b"\0" in content:
                    reason = "binary/non-UTF-8"
                else:
                    try:
                        decoded = content.decode("utf-8")
                    except UnicodeDecodeError:
                        reason = "binary/non-UTF-8"
            if reason:
                file.update(status="excluded", reason=reason, language="")
            else:
                lines = decoded.split("\n")
                if lines[-1] == "":
                    lines.pop()
                file.update(files=1, lines=len(lines), nonblank=sum(bool(line.strip()) for line in lines))
                file["blank"] = file["lines"] - file["nonblank"]
                # Preserve language-significant basenames, but isolate every path.
                name = pathlib.PurePosixPath(path).name.replace("\n", "_").replace("\r", "_")
                target = inputs / str(index) / name
                target.parent.mkdir()
                target.write_bytes(content)
                counters[str(target)] = file
            files.append(file)
        if counters:
            result = json.loads(subprocess.check_output([
                "perl", str(cloc), "--config=/dev/null", "--by-file", "--json",
                "--quiet", "--hide-rate", "--skip-uniqueness", "--timeout=0", str(inputs),
            ], text=True))
            for path, file in counters.items():
                counted = result.get(path)
                if counted is None:
                    # Unknown text remains visible instead of silently disappearing.
                    file.update(category="other", language="Text")
                else:
                    for metric in ("code", "comment", "blank"):
                        file[metric] = counted[metric]
                    file["language"] = counted["language"]
                    if sum(file[metric] for metric in ("code", "comment", "blank")) != file["lines"]:
                        raise ValueError("Counter line total mismatch: " + file["path"])
                    file["source_loc"] = file["code"] if file["category"] != "other" else 0
    categories = aggregate(files, "category", CATEGORIES)
    return {
        "commit": commit,
        "categories": categories,
        "languages": aggregate(files, "language"),
        "source_loc": sum(group["source_loc"] for group in categories.values()),
        "other_nonblank": categories["other"]["nonblank"],
        "exclusions": dict(sorted(collections.Counter(file["reason"] for file in files if file["status"] == "excluded").items())),
        "files": files,
    }


def differences(head: dict, base: dict) -> dict:
    result = {metric: head[metric] - base[metric] for metric in ("source_loc", "other_nonblank")}
    for grouping in ("categories", "languages"):
        result[grouping] = {}
        for name in sorted(head[grouping].keys() | base[grouping].keys()):
            result[grouping][name] = {
                metric: head[grouping].get(name, blank_metrics())[metric] - base[grouping].get(name, blank_metrics())[metric]
                for metric in METRICS
            }
    return result


def report(root: pathlib.Path, ref: str, base_ref: str | None, cloc: pathlib.Path, repository: str) -> dict:
    validate_counter(cloc)
    head = resolve(root, ref)
    base = None
    base_tip = None
    if base_ref:
        base_tip = resolve(root, base_ref)
        base = git(root, "merge-base", head, base_tip).decode().strip()
    result = {
        "schema_version": SCHEMA_VERSION, "policy_version": POLICY_VERSION,
        "counter": {"name": "cloc", "version": CLOC_VERSION, "sha256": CLOC_SHA256},
        "repository": repository, "base_tip": base_tip,
        "head": snapshot(root, head, cloc),
        "base": snapshot(root, base, cloc) if base else None,
        "delta": None,
    }
    if result["base"]:
        result["delta"] = differences(result["head"], result["base"])
    return result


def markdown(result: dict) -> str:
    head, delta = result["head"], result["delta"]
    lines = ["# Lines of code", "", f"Repository: `{result['repository']}`", "", f"Commit: `{head['commit']}`", ""]
    if result["base"]:
        lines += [f"Compared with merge base `{result['base']['commit']}`.", ""]
    lines += ["| Category | Count | PR change |", "| --- | ---: | ---: |"]
    for name, label in CATEGORIES.items():
        metric = "nonblank" if name == "other" else "source_loc"
        change = f"{delta['categories'][name][metric]:+,}" if delta else "—"
        lines.append(f"| {label} | {head['categories'][name][metric]:,} | {change} |")
    change = f"{delta['source_loc']:+,}" if delta else "—"
    lines += [f"| **Total source** | **{head['source_loc']:,}** | **{change}** |", "",
              "Total source sums nonblank, noncomment lines in the first four categories. Other text is separate.", "",
              "| Language | Source LOC | Files |", "| --- | ---: | ---: |"]
    for language, metrics in head["languages"].items():
        lines.append(f"| {language} | {metrics['source_loc']:,} | {metrics['files']} |")
    lines += ["", "Excluded files: " + (", ".join(f"{reason}: {count}" for reason, count in head["exclusions"].items()) or "none") + ".", "",
              f"cloc {CLOC_VERSION}; counting policy {POLICY_VERSION}; report schema {SCHEMA_VERSION}.",
              "See loc.json and loc.csv for file details, blank/comment counts, exclusions, and comparison snapshots.", ""]
    return "\n".join(lines)


def write_reports(result: dict, output: pathlib.Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "loc.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    columns = ["snapshot", "repository", "commit", "path", "category", "language", "status", "reason", *METRICS]
    with (output / "loc.csv").open("w", newline="", encoding="utf-8") as destination:
        writer = csv.DictWriter(destination, fieldnames=columns)
        writer.writeheader()
        for role in ("head", "base"):
            if result[role]:
                for file in result[role]["files"]:
                    writer.writerow({"snapshot": role, "repository": result["repository"], "commit": result[role]["commit"], **file})
    (output / "loc.md").write_text(markdown(result), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--base-ref", help="Compare against the merge base with this commit")
    parser.add_argument("--repository", default="winnowwallet/winnow")
    parser.add_argument("--cloc", type=pathlib.Path, required=True, help="Official cloc-2.10.pl release asset")
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    args = parser.parse_args()
    write_reports(report(args.repo.resolve(), args.ref, args.base_ref, args.cloc.resolve(), args.repository), args.output_dir)


if __name__ == "__main__":
    main()
