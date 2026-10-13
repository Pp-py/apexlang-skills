#!/usr/bin/env python3
"""Contract tier: the surface a reader or a consumer relies on has not drifted.

Static checks, no network, no database:
  * every relative Markdown link and #anchor resolves;
  * no citation by line number (`file.md:123`, `(line 12)`) — a line number comes to
    point at a different sentence when the file above it is edited;
  * each SKILL.md has the frontmatter the Agent Skills format needs;
  * the plugin manifests agree on the version; the Oracle lock is well-formed;
  * the patterns, constants and functions that are deliberately duplicated are still
    identical (alias and connection-name patterns, the marker TTL, json_flatten);
  * every runtime pass criterion has a unique ID with its check's prefix, and every ID
    a walkthrough cites exists;
  * every apex-ux criterion row is well-formed: a unique ID with its file's prefix, a
    severity, how it is verified (a FAIL never manual) and a source;
  * every KC-/UP-/GAP- reference names a row of framework/CAPABILITIES.md;
  * the frozen interface (framework/CONTRACTS.md) is what the scripts actually take.

Exit 0 PASS, 1 FAIL.
"""
import json
import os
import re
import subprocess
import sys
import unicodedata

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"ok   {msg}")


def bad(msg, details=()):
    global failed
    failed += 1
    print(f"FAIL {msg}")
    for d in list(details)[:12]:
        print(f"       | {d}")


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def tracked(pattern):
    """Files git knows or would add: committed, staged, or new and not ignored."""
    out = subprocess.run(["git", "-C", REPO, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                          "--", pattern], capture_output=True, check=True).stdout.decode()
    return sorted({p for p in out.split("\0") if p and os.path.exists(os.path.join(REPO, p))})


FENCE = re.compile(r"^(```|~~~)")


def prose_lines(text):
    """(line number, line) outside fenced code blocks, inline code removed."""
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line.lstrip()):
            fenced = not fenced
            continue
        if not fenced:
            yield n, re.sub(r"`[^`]*`", "", line)


def anchors(text):
    """GitHub's heading anchors for a Markdown file."""
    seen, out = {}, set()
    fenced = False
    for line in text.splitlines():
        if FENCE.match(line.lstrip()):
            fenced = not fenced
            continue
        m = None if fenced else re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        title = re.sub(r"`([^`]*)`", r"\1", m.group(1))
        title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", title)
        slug = "".join(c for c in title.lower()
                       if c in " -_" or unicodedata.category(c)[0] in "LN").replace(" ", "-")
        n = seen.get(slug, 0)
        seen[slug] = n + 1
        out.add(slug if n == 0 else f"{slug}-{n}")
    return out


def check_links():
    link = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
    broken = []
    files = tracked("*.md")
    for rel in files:
        text = read(rel)
        for n, line in prose_lines(text):
            for target in link.findall(line):
                if re.match(r"^[a-z][a-z0-9+.-]*:", target):      # http:, mailto:, …
                    continue
                path, _, frag = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(rel), path)) if path else rel
                full = os.path.join(REPO, dest)
                if not os.path.exists(full):
                    broken.append(f"{rel}:{n} → {target} (no such file)")
                elif frag and dest.endswith(".md") and frag not in anchors(read(dest)):
                    broken.append(f"{rel}:{n} → {target} (no such heading)")
    if broken:
        bad(f"Markdown links: {len(broken)} broken", broken)
    else:
        ok(f"Markdown links resolve, anchors included ({len(files)} files)")


def check_no_line_citations():
    pat = re.compile(r"[A-Za-z0-9._-]+\.md:[0-9]+|\(line [0-9]+\)")
    hits = []
    for rel in tracked("skills/*.md") + tracked("framework/*.md"):
        for n, line in enumerate(read(rel).splitlines(), 1):
            if pat.search(line):
                hits.append(f"{rel}:{n}: {line.strip()[:100]}")
    if hits:
        bad("citations by line number — anchor them by section + phrase instead", hits)
    else:
        ok("no citation by line number in skills/ or framework/")


def check_frontmatter():
    for rel in tracked("skills/*/SKILL.md"):
        text = read(rel)
        m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
        name = rel.split("/")[1]
        if not m:
            bad(f"{rel}: no frontmatter")
            continue
        fm = dict(re.findall(r"^([a-z-]+):\s*(.*)$", m.group(1), re.M))
        problems = []
        if fm.get("name") != name:
            problems.append(f"name is {fm.get('name')!r}, the directory is {name!r}")
        desc = fm.get("description", "")
        if not desc:
            problems.append("no description")
        elif len(desc) > 1024:
            problems.append(f"description is {len(desc)} characters (Agent Skills limit: 1024)")
        if problems:
            bad(f"{rel}: frontmatter", problems)
        else:
            ok(f"{rel}: frontmatter (name, description ≤ 1024)")


SKILL_BUDGET, AGENTS_BUDGET = 12288, 6144
CONTRACT_LABELS = ["Does", "Use when", "Decides", "Output", "Evidence", "Gate"]


def check_skill_shape():
    """Progressive disclosure: a SKILL.md opens with its Contract, stays within budget,
    and every references/ file it points to exists."""
    for rel in tracked("skills/*/SKILL.md"):
        text, problems = read(rel), []
        size = len(text.encode("utf-8"))
        if size > SKILL_BUDGET:
            problems.append(f"{size} bytes — over the {SKILL_BUDGET}-byte budget: move detail to references/")
        sections = re.findall(r"^## (.+)$", text, re.M)
        if not sections or sections[0] != "Contract":
            problems.append("the first section is not '## Contract'")
        else:
            block = re.search(r"^## Contract\n(.*?)(?=^## )", text, re.M | re.S).group(1).strip("\n")
            lines = block.splitlines()
            if len(lines) > 15:
                problems.append(f"the Contract block is {len(lines)} lines (at most 15)")
            for label in CONTRACT_LABELS:
                if not re.search(rf"^- \*\*{label}:\*\*", block, re.M):
                    problems.append(f"the Contract block has no '{label}:' line")
        skill_dir = os.path.dirname(rel)
        for ref in sorted(set(re.findall(r"`(references/[a-z0-9.-]+\.md)`", text))):
            if not os.path.exists(os.path.join(REPO, skill_dir, ref)):
                problems.append(f"points to {ref}, which does not exist")
        if problems:
            bad(f"{rel}: shape", problems)
        else:
            ok(f"{rel}: Contract first, {size} bytes ≤ {SKILL_BUDGET}, its references/ exist")
    size = len(read("AGENTS.md").encode("utf-8"))
    if size > AGENTS_BUDGET:
        bad(f"AGENTS.md is {size} bytes — over the {AGENTS_BUDGET}-byte budget")
    else:
        ok(f"AGENTS.md: {size} bytes ≤ {AGENTS_BUDGET}")


def check_versions_and_lock():
    plugin = json.loads(read(".claude-plugin/plugin.json"))
    market = json.loads(read(".claude-plugin/marketplace.json"))
    versions = {"plugin.json": plugin.get("version")}
    versions.update({f"marketplace.json:{p['name']}": p.get("version") for p in market.get("plugins", [])})
    m = re.search(r"^## (\d+\.\d+\.\d+)", read("CHANGELOG.md"), re.M)
    versions["CHANGELOG.md (latest entry)"] = m.group(1) if m else None
    fv = re.search(r'^FRAMEWORK_VERSION="([^"]+)"', read("skills/apex-sync-guard/scripts/apex-sync-check.sh"), re.M)
    versions["apex-sync-check.sh FRAMEWORK_VERSION"] = fv.group(1) if fv else None
    uv = re.search(r'^FRAMEWORK_VERSION = "([^"]+)"', read("framework/lib/result.py"), re.M)
    versions["framework/lib/result.py FRAMEWORK_VERSION"] = uv.group(1) if uv else None
    if len(set(versions.values())) == 1:
        ok(f"one version everywhere: {plugin.get('version')} (manifests, CHANGELOG, the version results report)")
    else:
        bad("the version differs between manifests, CHANGELOG and FRAMEWORK_VERSION", [f"{k}: {v}" for k, v in versions.items()])
    lock = json.loads(read("framework/oracle-skills.lock.json"))
    problems = []
    if lock.get("schemaVersion") != 1:
        problems.append("schemaVersion must be 1")
    if not re.fullmatch(r"[0-9a-f]{40}", str(lock.get("commit", ""))):
        problems.append("commit must be a full 40-hex sha")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(lock.get("verifiedAt", ""))):
        problems.append("verifiedAt must be a date")
    for k in ("source", "plugin", "commitDate", "verifiedWith"):
        if not lock.get(k):
            problems.append(f"{k} is missing")
    if problems:
        bad("framework/oracle-skills.lock.json", problems)
    else:
        ok(f"Oracle lock well-formed ({lock['commit'][:12]}, verified {lock['verifiedAt']})")


def shell_var(rel, name):
    m = re.search(rf"^{name}=(.+)$", read(rel), re.M)
    return m.group(1).strip() if m else None


def check_duplicates():
    lib = "skills/apex-sync-guard/scripts/lib/sync-config.sh"
    pw = "skills/apex-sentinel/scripts/pw.sh"
    chk = "skills/apex-sync-guard/scripts/apex-sync-check.sh"
    hook = "skills/apex-sync-guard/scripts/apex-sync-hook.sh"
    common = json.loads(read("framework/schemas/common.schema.json"))["$defs"]

    alias = {rel: shell_var(rel, "RE_APP_ALIAS") for rel in (lib, pw)}
    alias["common.schema.json appAlias"] = repr(common["appAlias"]["pattern"])
    norm = {k: (v or "").strip("'\"") for k, v in alias.items()}
    if len(set(norm.values())) == 1:
        ok(f"the app-alias pattern is one pattern everywhere: {next(iter(norm.values()))}")
    else:
        bad("the app-alias pattern differs", [f"{k}: {v}" for k, v in norm.items()])

    # The connection-name pattern is POSIX ERE in bash and ECMA/Python in the schema:
    # compare what they accept, not how they are spelled.
    samples = ["dev", "dev_hr", "DEV-1.x", "a" * 128, "a" * 129, "", "scott/tiger", "u@db",
               "two words", "q\"uote", "q'uote", "back\\slash", "tab\tbed", "ñandú"]
    bash = subprocess.run(
        ["bash", "-c", f'. "{os.path.join(REPO, lib)}"; while IFS= read -r -d "" s; do '
                       '[[ "$s" =~ $RE_CONNECTION ]] && echo 1 || echo 0; done'],
        input="\0".join(samples) + "\0", capture_output=True, text=True).stdout.split()
    py = ["1" if re.fullmatch(common["connectionName"]["pattern"], s) else "0" for s in samples]
    diff = [f"{s!r}: bash {b}, schema {p}" for s, b, p in zip(samples, bash, py) if b != p]
    if len(bash) == len(samples) and not diff:
        ok("the connection-name pattern accepts the same names in bash and in the schema")
    else:
        bad("the connection-name pattern disagrees between bash and the schema", diff or bash)

    ttl = {chk: shell_var(chk, "TTL_SECONDS"), hook: shell_var(hook, "TTL")}
    vals = {k: re.match(r"\d+", v or "").group(0) if re.match(r"\d+", v or "") else v for k, v in ttl.items()}
    if len(set(vals.values())) == 1 and None not in vals.values():
        ok(f"the marker TTL is the same in the check and the hook ({next(iter(vals.values()))} s)")
    else:
        bad("the marker TTL differs between the check and the hook", [f"{k}: {v}" for k, v in vals.items()])

    def body(rel, fn):
        m = re.search(rf"^{fn}\(\) \{{.*?^\}}$", read(rel), re.M | re.S)
        return m.group(0) if m else None
    keys = {rel: shell_var(rel, "APP_KEYS") for rel in (lib, pw)}
    if len(set(keys.values())) == 1 and None not in keys.values():
        ok(f"the keys an app takes are the same in the guard's lib and in pw.sh: {keys[lib]}")
    else:
        bad("APP_KEYS differs between the guard's lib and pw.sh (an app key one accepts, the other rejects)",
            [f"{k}: {v}" for k, v in keys.items()])

    a, b = body(lib, "json_flatten"), body(pw, "json_flatten")
    if a and a == b:
        ok("json_flatten is the same function in the guard's lib and in pw.sh")
    else:
        bad("json_flatten differs between the guard's lib and pw.sh (the two readers of apex-sync.json)")


CHECK_PREFIX = {"browse-search": "BROWSE", "dashboard-report": "DASH", "editable-ig": "IG",
                "form-page": "FORM", "modal-crud": "MODAL", "split-view": "SPLIT", "workflow-state": "WF"}
ID = re.compile(r"`([A-Z]{2,8}(?:-[A-Z0-9]{1,24}){1,4})`")
ID_PATTERN = json.loads(read("framework/schemas/common.schema.json"))["$defs"]["criterionId"]["pattern"]


def criteria_section(text):
    m = re.search(r"^## Pass criteria\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1) if m else ""


def check_criterion_ids():
    defined, problems = {}, []
    for rel in tracked("skills/apex-sentinel/checks/*.md"):
        name = os.path.basename(rel)[:-3]
        prefix = CHECK_PREFIX.get(name)
        if not prefix:
            problems.append(f"{rel}: no criterion prefix registered for this check")
            continue
        section = criteria_section(read(rel))
        if not re.search(r"^- `", section, re.M):
            problems.append(f"{rel}: no criterion with an ID — is its '## Pass criteria' section gone?")
        for line in section.splitlines():
            if not line.startswith("- ") or line.startswith("- (Not a runtime criterion"):
                continue
            m = re.match(r"^- `([^`]+)` — ", line)
            if not m:
                problems.append(f"{rel}: a criterion without an ID: {line[:70]}")
                continue
            cid = m.group(1)
            if not re.fullmatch(ID_PATTERN, cid) or not cid.startswith(prefix + "-"):
                problems.append(f"{rel}: {cid} is not {prefix}-<SLUG>")
            if cid in defined:
                problems.append(f"{rel}: {cid} already defined in {defined[cid]}")
            defined[cid] = rel
    for rel in tracked("skills/apex-sentinel/examples/*.md"):
        for cid in ID.findall(criteria_section(read(rel))):
            if cid not in defined:
                problems.append(f"{rel}: cites {cid}, which no check defines")
    if problems:
        bad("criterion IDs", problems)
    else:
        ok(f"{len(defined)} criterion IDs: one per pass criterion, unique, prefixed; walkthroughs cite existing ones")


UX_PREFIX = {"common": "UX", "dashboards": "UXDASH", "browse-search": "UXBRW", "item-details": "UXDET",
             "data-entry": "UXENT", "workflow": "UXWF"}


def check_ux_criteria():
    """The apex-ux and apex-security catalogs are what their scans and results key on: one
    table per file, every row ID | Criterion | Sev | By | Source, IDs unique and prefixed."""
    check_criteria_tables("apex-ux", [f for f in tracked("skills/apex-ux/criteria/*.md") if not f.endswith("/README.md")],
                          lambda rel: UX_PREFIX.get(os.path.basename(rel)[:-3]))
    check_criteria_tables("apex-security", tracked("skills/apex-security/criteria.md"), lambda rel: "SEC")


def check_criteria_tables(skill, files, prefix_of):
    defined, problems = {}, []
    for rel in files:
        prefix = prefix_of(rel)
        if not prefix:
            problems.append(f"{rel}: no criterion prefix registered for this file")
            continue
        rows = 0
        for line in read(rel).splitlines():
            if not line.startswith("| `"):
                continue
            cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
            if len(cells) != 5:
                problems.append(f"{rel}: a row without exactly 5 cells: {line[:70]}")
                continue
            rows += 1
            cid, text, sev, by, source = cells
            cid = cid.strip("`")
            if not re.fullmatch(ID_PATTERN, cid) or not cid.startswith(prefix + "-"):
                problems.append(f"{rel}: {cid} is not {prefix}-<SLUG>")
            if cid in defined:
                problems.append(f"{rel}: {cid} already defined in {defined[cid]}")
            defined[cid] = rel
            if sev not in ("FAIL", "ADVISE"):
                problems.append(f"{rel}: {cid} severity '{sev}' is not FAIL or ADVISE")
            methods = [m.strip() for m in by.split("+")]
            if not methods or any(m not in ("static", "runtime", "manual") for m in methods):
                problems.append(f"{rel}: {cid} 'By' '{by}' is not static/runtime/manual joined with +")
            if sev == "FAIL" and "manual" in methods:
                problems.append(f"{rel}: {cid} is FAIL but verified manually — a FAIL must be machine-checkable")
            if not text or not source:
                problems.append(f"{rel}: {cid} has an empty criterion or source")
        if not rows:
            problems.append(f"{rel}: no criterion rows — is its table gone?")
    if not files:
        problems.append(f"no criteria files for {skill}")
    if problems:
        bad(f"{skill} criteria", problems)
    else:
        ok(f"{len(defined)} {skill} criteria: unique, prefixed, with severity, method and source")


def check_capability_refs():
    rows = set(re.findall(r"^\| (KC-\d+|UP-\d+|GAP-\d+) \|", read("framework/CAPABILITIES.md"), re.M))
    missing = []
    for rel in tracked("*.md"):
        for n, line in enumerate(read(rel).splitlines(), 1):
            for ref in re.findall(r"\b(KC-\d+|UP-\d+|GAP-\d+)\b", line):
                if ref not in rows:
                    missing.append(f"{rel}:{n} → {ref}")
    if missing:
        bad("KC-/UP-/GAP- references with no row in framework/CAPABILITIES.md", missing)
    else:
        ok(f"every KC-/UP-/GAP- reference names a row of CAPABILITIES.md ({len(rows)} rows)")


def check_interface():
    chk = read("skills/apex-sync-guard/scripts/apex-sync-check.sh")
    usage = re.search(r'^USAGE="(.*)"$', chk, re.M)
    usage = usage.group(1) if usage else ""
    want = ["check-import", "check-export", "record-sync", "status", "doctor", "apps", "--app", "--env", "--task", "--force"]
    missing = [w for w in want if w not in usage]
    if "0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED" not in chk or "3 UNKNOWN" not in chk:
        missing.append("the exit-code line (0 PASS · 1 FAIL/CONFLICT · 2 BLOCKED · 3 UNKNOWN)")
    pw = read("skills/apex-sentinel/scripts/pw.sh")
    if "pw.sh [--app <alias>] [--env <name>] <subcommand>" not in pw:
        missing.append("pw.sh usage: [--app <alias>] [--env <name>] <subcommand>")
    for script, args in (("apexlang-architecture/scripts/arch-scan.py", "arch-scan.py <file-or-dir>..."),
                         ("apex-ux/scripts/ux-scan.py", "[--app <alias>] [--task <id>]"),
                         ("apex-ux/scripts/ux-check.py", "[--app <alias>] [--task <id>] [--dialog <selector>]..."),
                         ("apex-security/scripts/sec-scan.py", "[--app <alias>] [--task <id>]"),
                         ("apex-security/scripts/plsql-scan.py", "[--app <alias>] [--task <id>]"),
                         ("apex-security/scripts/sec-probe.py", "[--app <alias>] [--task <id>] [--anon <url>]... [--tamper]"),
                         ("apex-security/scripts/secrets-scan.py", "[--app <alias>] [--task <id>] [<path>...]")):
        if args not in read(f"skills/{script}"):
            missing.append(f"{script} usage: {args}")
    ev = read("framework/scripts/evidence.py")
    for args in ("capture --gate runtime|architecture [--app <alias>] [--env <name>] --task <id> <name> -- <command>...",
                 "write --kind runtime|architecture [--app <alias>] [--env <name>] --task <id> <draft.json>",
                 "fresh --task <id> <result.json>..."):
        if args not in ev:
            missing.append(f"framework/scripts/evidence.py usage: {args}")
    hooks = json.loads(read("hooks/hooks.json"))
    cmds = [h.get("command", "") for e in hooks.get("hooks", {}).get("PreToolUse", []) for h in e.get("hooks", [])]
    matchers = [e.get("matcher") for e in hooks.get("hooks", {}).get("PreToolUse", [])]
    if "Bash|PowerShell" not in matchers:
        missing.append("hooks.json: the PreToolUse matcher Bash|PowerShell")
    if not any("skills/apex-sync-guard/scripts/apex-sync-hook.sh" in c for c in cmds):
        missing.append("hooks.json: a command running skills/apex-sync-guard/scripts/apex-sync-hook.sh")
    contracts = read("framework/CONTRACTS.md")
    for path in re.findall(r"`(skills/[^`\s]+\.sh)", contracts):
        if not os.path.exists(os.path.join(REPO, path)):
            missing.append(f"CONTRACTS.md names {path}, which does not exist")
    if missing:
        bad("the frozen interface (framework/CONTRACTS.md)", missing)
    else:
        ok("the frozen interface matches the scripts, the hook registration and CONTRACTS.md")


def main():
    check_links()
    check_no_line_citations()
    check_frontmatter()
    check_skill_shape()
    check_versions_and_lock()
    check_duplicates()
    check_criterion_ids()
    check_ux_criteria()
    check_capability_refs()
    check_interface()
    print()
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
