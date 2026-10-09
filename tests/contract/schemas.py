#!/usr/bin/env python3
"""Contract tier: the JSON contracts in framework/schemas/ hold.

  1. every schema is valid Draft 2020-12, with the $id its file name implies, and
     every regex in it compiles;
  2. every fixture in fixtures/<kind>/ validates;
  3. every negative in negatives.json — a valid fixture with one invariant broken —
     is rejected (each encodes a way an unsafe result could pass for a safe one);
  4. with --captured DIR: every result a tool emitted during the integration suite
     validates, carries no $HOME path and no APEX session id, and there is at least one.

Exit 0 PASS, 1 FAIL, 2 BLOCKED (jsonschema missing). Runs with the jsonschema that
Ubuntu 24.04 ships (4.10, RefResolver) and with current releases (referencing).
"""
import argparse
import copy
import glob
import json
import os
import re
import sys

try:
    import jsonschema
    from jsonschema import Draft202012Validator
except ImportError:
    print("contract: BLOCKED — python3 jsonschema is required "
          "(apt install python3-jsonschema, or pip install jsonschema)", file=sys.stderr)
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SCHEMA_DIR = os.path.join(REPO, "framework", "schemas")
ID_BASE = "https://pp-py.github.io/apexlang-skills/schemas/1/"

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"ok   {msg}")


def bad(msg, detail=""):
    global failed
    failed += 1
    print(f"FAIL {msg}")
    if detail:
        print("     " + detail.replace("\n", "\n     "))


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


SCHEMAS = {}  # file name -> schema
for path in sorted(glob.glob(os.path.join(SCHEMA_DIR, "*.schema.json"))):
    SCHEMAS[os.path.basename(path)] = load(path)


def validator(name):
    """A validator for one schema that resolves $refs to its siblings offline."""
    schema = SCHEMAS[name]
    try:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT202012
        registry = Registry().with_resources(
            (s["$id"], Resource.from_contents(s, default_specification=DRAFT202012)) for s in SCHEMAS.values())
        return Draft202012Validator(schema, registry=registry)
    except ImportError:
        store = {s["$id"]: s for s in SCHEMAS.values()}
        return Draft202012Validator(schema, resolver=jsonschema.RefResolver.from_schema(schema, store=store))


def errors(name, doc):
    return sorted(validator(name).iter_errors(doc), key=lambda e: list(e.absolute_path))


def walk_patterns(node, where=""):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "pattern" and isinstance(v, str):
                yield where, v
            yield from walk_patterns(v, f"{where}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_patterns(v, f"{where}/{i}")


def kind_schema(kind):
    return f"{kind}.schema.json"


def set_path(doc, dotted, value, delete=False):
    keys = [int(k) if k.isdigit() else k for k in dotted.split(".")]
    node = doc
    for k in keys[:-1]:
        node = node[k]
    if delete:
        del node[keys[-1]]
    else:
        node[keys[-1]] = value


def check_schemas():
    if not SCHEMAS:
        bad("framework/schemas holds no *.schema.json")
        return
    for name, schema in SCHEMAS.items():
        try:
            Draft202012Validator.check_schema(schema)
            ok(f"schema {name} is valid Draft 2020-12")
        except jsonschema.exceptions.SchemaError as e:
            bad(f"schema {name} is not valid Draft 2020-12", str(e.message))
        if schema.get("$id") != ID_BASE + name:
            bad(f"schema {name}: $id must be {ID_BASE + name}", f"got {schema.get('$id')}")
        for where, pattern in walk_patterns(schema):
            try:
                re.compile(pattern)
            except re.error as e:
                bad(f"schema {name}: pattern at {where} does not compile", f"{pattern}: {e}")


def check_fixtures():
    fixtures = {}
    for path in sorted(glob.glob(os.path.join(HERE, "fixtures", "*", "*.json"))):
        kind = os.path.basename(os.path.dirname(path))
        rel = os.path.relpath(path, HERE)
        doc = load(path)
        fixtures[rel] = (kind, doc)
        errs = errors(kind_schema(kind), doc)
        if errs:
            bad(f"fixture {rel} validates", "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errs[:5]))
        else:
            ok(f"fixture {rel} validates")
    if not fixtures:
        bad("no fixtures found under tests/contract/fixtures/")
    for neg in load(os.path.join(HERE, "negatives.json")):
        kind, base = fixtures.get(neg["fixture"], (None, None))
        if base is None:
            bad(f"negative '{neg['name']}': no fixture {neg['fixture']}")
            continue
        doc = copy.deepcopy(base)
        try:
            for dotted, value in neg.get("set", {}).items():
                set_path(doc, dotted, value)
            for dotted in neg.get("unset", []):
                set_path(doc, dotted, None, delete=True)
        except (KeyError, IndexError, TypeError) as e:
            bad(f"negative '{neg['name']}': cannot apply its edit", repr(e))
            continue
        if errors(kind_schema(kind), doc):
            ok(f"rejected: {neg['name']}")
        else:
            bad(f"accepted, must be rejected: {neg['name']}", neg.get("why", ""))


def check_captured(directory):
    home = os.environ.get("HOME", "")
    files = sorted(glob.glob(os.path.join(directory, "*.json")))
    if not files:
        bad(f"no emitted results captured in {directory} — the integration suite wrote none")
        return
    counts, before = {}, failed
    for path in files:
        name = os.path.basename(path)
        try:
            doc = load(path)
            raw = open(path, encoding="utf-8").read()
        except (ValueError, UnicodeDecodeError) as e:
            bad(f"emitted {name} is not JSON", str(e))
            continue
        kind = doc.get("kind")
        if kind_schema(kind) not in SCHEMAS:
            bad(f"emitted {name}: unknown kind {kind!r}")
            continue
        errs = errors(kind_schema(kind), doc)
        if errs:
            bad(f"emitted {name} ({doc.get('operation')} {doc.get('status')}) validates",
                "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errs[:5]))
            continue
        if home and home != "/" and home + "/" in raw:
            bad(f"emitted {name} leaks the home path {home}/")
            continue
        if re.search(r"session=[0-9]", raw):
            bad(f"emitted {name} carries an APEX session id")
            continue
        key = f"{kind} {doc.get('operation', '')} {doc.get('status')}"
        counts[key] = counts.get(key, 0) + 1
    if failed == before:
        ok(f"{len(files)} emitted result(s) validate: " + ", ".join(f"{k} ×{n}" for k, n in sorted(counts.items())))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--captured", help="directory of results captured from the integration suite")
    args = ap.parse_args()
    check_schemas()
    check_fixtures()
    if args.captured:
        check_captured(args.captured)
    print()
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
