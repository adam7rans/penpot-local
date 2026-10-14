"""Regenerate frontend/src/app/render_wasm/api/shared.js from Rust ToJs enums.

Usage: gen-shared-js.py <penpot-checkout>

Replicates render-wasm/macros/src/lib.rs generate_js_for_enum plus the
heck case conversions, without needing cargo or emsdk. Only enums whose
derive contains ToJs are included (pub or private). The file is gitignored
upstream, so a source build needs this step before shadow-cljs.
"""
import re
import sys
from pathlib import Path

REPO = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
SRC = REPO / "render-wasm" / "src"
OUT = REPO / "frontend" / "src" / "app" / "render_wasm" / "api" / "shared.js"


def kebab(s: str) -> str:
    # Match heck's ToKebabCase for these identifiers: split acronym boundaries
    # (ABCDef -> ABC-Def) and lowerCamel boundaries (aB -> a-B), then lowercase.
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", s)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", s)
    s = s.replace("_", "-").replace(" ", "-")
    return s.lower()


def pascal(s: str) -> str:
    # Enum ids are already PascalCase without separators; keep as-is.
    if "_" in s or "-" in s or " " in s:
        parts = re.split(r"[_\-\s]+", s)
        return "".join(p[:1].upper() + p[1:] for p in parts if p)
    return s


ENUM_RE = re.compile(
    r"#\[derive\((?P<derive>[^\]]*?)\)\]"      # derive attribute
    r"(?:\s*#\[[^\]]*?\])*"                    # following attrs (repr, allow...)
    r"\s*(?:pub\s+)?enum\s+(?P<name>\w+)"      # enum Name
    r"\s*\{(?P<body>.*?)\}",                   # { variants }
    re.DOTALL,
)

VARIANT_RE = re.compile(
    r"^\s*(?P<variant>[A-Z]\w*)"               # VariantName
    r"(?:\s*\([^)]*\))?"                       # optional (Payload)
    r"(?:\s*\[[^\]]*\])?"                      # optional [ Payload ] (unlikely)
    r"\s*=\s*(?P<value>0[xX][0-9a-fA-F]+|\d+)"  # = 3 or = 0x01
    r"\s*,?\s*$"
)


def main() -> None:
    enums: dict[str, list[tuple[str, int]]] = {}
    files = sorted(SRC.rglob("*.rs"))
    for path in files:
        text = path.read_text()
        for m in ENUM_RE.finditer(text):
            if "ToJs" not in m.group("derive"):
                continue
            name = m.group("name")
            body = m.group("body")
            variants: list[tuple[str, int]] = []
            for line in body.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or stripped.startswith("//"):
                    continue
                vm = VARIANT_RE.match(line)
                if not vm:
                    code = line.split("//")[0]
                    vm = VARIANT_RE.match(code)
                if not vm:
                    print(f"WARN: {path.name} enum {name}: cannot parse line: {line.strip()!r}",
                          file=sys.stderr)
                    continue
                variants.append((vm.group("variant"), int(vm.group("value"), 0)))
            if not variants:
                print(f"WARN: {path.name} enum {name}: no variants parsed", file=sys.stderr)
                continue
            if name in enums:
                print(f"WARN: duplicate enum {name} (also in {path.name}), merging",
                      file=sys.stderr)
                enums[name].extend(variants)
            else:
                enums[name] = variants

    if not enums:
        print("ERROR: no ToJs enums found", file=sys.stderr)
        sys.exit(1)

    blocks: list[str] = []
    for name in sorted(enums):
        variants = sorted(enums[name], key=lambda kv: kv[1])
        lines = [f'  "{kebab(v)}": {n},' for v, n in variants]
        blocks.append(f"export const {pascal(name)} = {{\n" + "\n".join(lines) + "\n};")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n\n".join(blocks) + "\n")
    print(f"Wrote {len(enums)} enums to {OUT}")


if __name__ == "__main__":
    main()
