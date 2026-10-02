#!/usr/bin/env python3
"""Run existing tests with the CDPVault ABI changes, without editing test/ inputs.

Usage: python3 docs/tests/run-vault-checks.py [additional forge test arguments]
InHouse uses a local MockIMD runtime at its fixture address; this is not a fork test.
All generated fixtures, artifacts and caches stay in test/scratch/.
"""

import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / "test/scratch"
LEGACY = SCRATCH / "legacy"


def adapt(text):
    text = text.replace('"../src/', '"src/')
    # Extend constructor calls, including inheritance and CREATE2 expressions.
    # A CDPVault type cast has one argument and is left alone.
    additions = []
    for match in re.finditer(r"(?:new\s+CDPVault(?:\s*\{[^}]*\})?|\bCDPVault)\s*\(", text):
        index = start = match.end()
        depth = 1
        arguments = []
        while depth:
            char = text[index]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            elif char == "," and depth == 1:
                arguments.append(text[start:index].strip())
                start = index + 1
            index += 1
        arguments.append(text[start:index - 1].strip())
        if len(arguments) == 5:
            additions.append((index - 1, arguments[3]))
    for index, price in reversed(additions):
        text = text[:index] + ", " + price + ", 0, 0, 0" + text[index:]
    # Only a file that still used the five-word constructor destructures the three-field mark;
    # a migrated fixture already carries the trailing marker slot and must not get another.
    if additions:
        text = re.sub(
            r"\(([^;\n]*?)\)(\s*=\s*vault\.liquidationMarks\()",
            lambda match: "(" + match[1] + ",)" + match[2],
            text,
        )
    # The factory's CREATE2 prediction hashes the constructor words too.
    text = text.replace(
        "abi.encode(address(imd), address(0), address(0), address(priceFeed), address(nhiFeed))",
        "abi.encode(address(imd), address(0), address(0), address(priceFeed), address(nhiFeed), address(priceFeed), 0, 0, 0)",
    )
    return text


def main():
    for source in (ROOT / "test").rglob("*.sol"):
        relative = source.relative_to(ROOT / "test")
        if relative.parts[0] == "scratch":
            continue
        target = LEGACY / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        text = adapt(source.read_text())
        if relative.name == "InHouse.t.sol":
            text = text.replace(
                "imd = MockIMD(LIVE_MOCK_IMD);",
                "vm.etch(LIVE_MOCK_IMD, address(new MockIMD()).code);\n"
                "        imd = MockIMD(LIVE_MOCK_IMD);",
            )
        target.write_text(text)
    (SCRATCH / "empty-script").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        "FOUNDRY_TEST": "test/scratch/legacy",
        "FOUNDRY_SCRIPT": "test/scratch/empty-script",
        "FOUNDRY_OUT": "test/scratch/legacy-out",
        "FOUNDRY_CACHE_PATH": "test/scratch/legacy-cache",
    })
    print("Legacy fixtures: zero fees/shares, primary reused as spot; InHouse uses a local MockIMD runtime.", flush=True)
    return subprocess.call(["forge", "test", *sys.argv[1:]], cwd=ROOT, env=env)


if __name__ == "__main__":
    sys.exit(main())
