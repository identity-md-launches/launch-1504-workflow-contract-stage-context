#!/usr/bin/env python3
"""Export or verify public contract ABIs using only Foundry and Python's standard library."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if a delivered ABI differs from the compiled ABI")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name in ("LaunchToken", "SorenVault"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(result.stdout)
        if not isinstance(abi, list):
            raise SystemExit(f"Unexpected ABI output for {name}")
        path = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not path.exists() or json.loads(path.read_text()) != abi:
                raise SystemExit(f"ABI differs from compiled contract: {path.relative_to(root)}")
            print(f"Verified {path.relative_to(root)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {path.relative_to(root)}")


if __name__ == "__main__":
    main()
