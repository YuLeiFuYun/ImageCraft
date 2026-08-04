#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout.strip()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cjpeg", required=True)
    parser.add_argument("--djpeg", required=True)
    args = parser.parse_args()

    spec_root = args.spec_root.resolve()
    output = args.output.resolve()
    specification = json.loads((spec_root / "manifest.json").read_text(encoding="utf-8"))

    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    sources = specification["sources"]
    scripts = specification["scanScripts"]
    for source in sources:
        copy_file(spec_root / source["file"], output / source["file"])
    for script in scripts:
        copy_file(spec_root / script["file"], output / script["file"])

    variants = []
    final_ppm_hashes: dict[str, str] = {}
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        for source in sources:
            source_path = output / source["file"]
            ppm_path = temporary_root / f"{source['id']}.ppm"
            run([args.djpeg, "-rgb", "-outfile", str(ppm_path), str(source_path)])
            source_final_hash: str | None = None
            for script in scripts:
                variant_id = f"{source['id']}--{script['id']}"
                relative_path = f"encoded/{variant_id}.jpg"
                encoded_path = output / relative_path
                encoded_path.parent.mkdir(parents=True, exist_ok=True)
                run(
                    [
                        args.cjpeg,
                        "-quality",
                        str(specification["encoding"]["quality"]),
                        "-sample",
                        specification["encoding"]["sampleFactors"],
                        "-optimize",
                        "-scans",
                        str(output / script["file"]),
                        "-outfile",
                        str(encoded_path),
                        str(ppm_path),
                    ]
                )
                decoded_path = temporary_root / f"{variant_id}.ppm"
                run([args.djpeg, "-rgb", "-outfile", str(decoded_path), str(encoded_path)])
                decoded_hash = sha256(decoded_path)
                if source_final_hash is None:
                    source_final_hash = decoded_hash
                elif decoded_hash != source_final_hash:
                    raise RuntimeError(
                        f"scan scripts changed final decoded pixels for {source['id']}"
                    )
                variants.append(
                    {
                        "id": variant_id,
                        "sourceID": source["id"],
                        "scanScriptID": script["id"],
                        "file": relative_path,
                        "width": source["width"],
                        "height": source["height"],
                        "scanCount": script["scanCount"],
                        "byteCount": encoded_path.stat().st_size,
                        "sha256": sha256(encoded_path),
                    }
                )
            assert source_final_hash is not None
            final_ppm_hashes[source["id"]] = source_final_hash

    regenerated = dict(specification)
    regenerated["sources"] = []
    for source in sources:
        copied = dict(source)
        path = output / source["file"]
        copied["byteCount"] = path.stat().st_size
        copied["sha256"] = sha256(path)
        copied["referenceDecodedPPMSHA256"] = final_ppm_hashes[source["id"]]
        regenerated["sources"].append(copied)
    regenerated["scanScripts"] = []
    for script in scripts:
        copied = dict(script)
        path = output / script["file"]
        copied["byteCount"] = path.stat().st_size
        copied["sha256"] = sha256(path)
        regenerated["scanScripts"].append(copied)
    regenerated["variants"] = variants
    regenerated["encoding"] = dict(specification["encoding"])
    regenerated["encoding"]["cjpegVersion"] = run([args.cjpeg, "-version"]).splitlines()[0]
    regenerated["encoding"]["djpegVersion"] = run([args.djpeg, "-version"]).splitlines()[0]
    regenerated["encoding"].pop("encoder", None)
    regenerated["encoding"].pop("decoder", None)

    (output / "manifest.json").write_text(
        json.dumps(regenerated, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
