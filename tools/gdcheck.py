#!/usr/bin/env python3
"""
gdcheck.py — semantic gate for Shino & Bea's GDScript (Run 157).

WHY THIS EXISTS
---------------
`gdparse` (gdtoolkit) only validates SYNTAX. It happily accepts code that Godot's
analyzer rejects at load time, and when a *base* script fails to compile the error
Godot surfaces is the confusing:

    Shino.gd:1  Could not resolve class "HeroBase"

...which points at the extends line, not at the real mistake. That is exactly how a
one-line arity mismatch (a RunState facade still declared with 0 params while its
callers had been updated to pass `who`) took the whole game down in Run 157.

Run this after every edit batch, alongside gdparse:

    gdparse scripts/*.gd && python3 tools/gdcheck.py

Exit code 0 = clean. Non-zero = at least one finding.

CHECKS
------
1. arity        — every call site matches some definition's (required..total) params
2. facade       — RunState wrapper signatures match their BoonEffects targets
3. members      — every RunState./BoonEffects./BoonDB. reference actually exists
4. duplicates   — no duplicate func/var/const/signal in one script
5. overrides    — child override signatures match the HeroBase parent exactly
6. readonly     — no writes to getter-only computed properties
7. shadowing    — children don't redeclare a parent's var/const
8. base-uses-child — HeroBase doesn't reference members only its children declare
9. const-not-constant — no `const X = SomeHeapType(...)`; Godot's analyzer rejects
                   it ("isn't a constant expression") even though gdparse passes,
                   and in an autoload it stops the whole game booting

These are the error classes that produce "Could not resolve class" cascades.
"""
import re
import sys
import glob
import os
import collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")

KEYWORDS = {
    "if", "elif", "else", "while", "for", "return", "match", "not", "and", "or",
    "in", "func", "var", "const", "await", "assert", "pass", "break", "continue",
    "is", "as", "super", "range", "print",
}
OBJ_METHODS = {
    "get", "set", "call", "call_deferred", "set_deferred", "has_method",
    "has_signal", "connect", "disconnect", "emit_signal", "get_meta", "set_meta",
    "has_meta", "remove_meta", "duplicate", "free", "queue_free", "new",
    "is_inside_tree", "get_class", "get_instance_id", "resource_path",
}

findings = []


def report(kind, msg):
    findings.append((kind, msg))
    print("  [%s] %s" % (kind, msg))


def read(path):
    with open(path, encoding="utf-8", errors="ignore") as fh:
        return fh.read()


# ⚠ Both helpers below are STRING-AWARE. They must be.
#
# The original versions ignored quoting, so a comma or paren inside a string
# literal was treated as syntax. That made a perfectly valid one-argument call
#
#     Log.dbg("[Bea] 2P swap — Shino dev=%d, Bea dev=%d" % [a, b])
#
# look like TWO arguments (the comma inside the message split it), and any
# ")" inside a message truncated the call early. Latent since the tool was
# written; it only produced visible false positives once the arity check was
# widened to autoload-qualified calls. Fixed 2026-08-01.
def _string_aware_scan(s, start=0):
    """Yield (index, char, depth, in_string) walking s, honouring quotes."""
    depth = 0
    quote = None
    i = start
    while i < len(s):
        ch = s[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
            yield i, ch, depth, True
            i += 1
            continue
        if ch in "\"'":
            quote = ch
            yield i, ch, depth, True
            i += 1
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        yield i, ch, depth, False
        i += 1


def split_args(s):
    out, cur = [], ""
    for _i, ch, depth, in_str in _string_aware_scan(s):
        if ch == "," and depth == 0 and not in_str:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def balanced(line, open_idx):
    for i, ch, depth, in_str in _string_aware_scan(line, open_idx):
        if in_str:
            continue
        if ch == ")" and depth == 0:
            return line[open_idx + 1:i]
    return None


def signatures(src):
    """name -> (required, total, raw_args, return_type)

    ⚠ Uses BALANCED paren matching, not `[^)]*`.

    The original regex stopped at the first ')', so any parameter with a default
    value containing parentheses was mis-parsed:

        func spawn_hit_particles(pos, color: Color = Color(1,1,1,1), count = 8)

    ...was read as ending inside `Color(1,1,1,1`, yielding a bogus 4-required /
    5-total signature for a function that actually takes 1 required and 4 total.
    Harmless while the arity check only looked at RunState./BoonEffects., but it
    produced 200+ false positives the moment autoload-qualified calls (FX.,
    Settings., ...) were included. Fixed 2026-08-01.

    Args are also split on TOP-LEVEL commas only, so commas inside a default
    value no longer inflate the parameter count.
    """
    out = {}
    for m in re.finditer(r"^(?:static )?func ([a-zA-Z_0-9]+)\s*\(", src, re.M):
        name = m.group(1)
        open_idx = m.end() - 1
        args = balanced(src, open_idx)
        if args is None:
            continue
        args = args.strip()
        params = [a.strip() for a in split_args(args)] if args.strip() else []
        # Return type sits just past the closing paren.
        close_idx = open_idx
        depth = 0
        for i in range(open_idx, len(src)):
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0:
                    close_idx = i
                    break
        tail = src[close_idx + 1:src.find("\n", close_idx) if src.find("\n", close_idx) != -1 else len(src)]
        rm = re.match(r"\s*(->\s*[A-Za-z_0-9\[\]]+)", tail)
        ret = rm.group(1).strip() if rm else ""
        out[name] = (sum(1 for p in params if "=" not in p), len(params), args, ret)
    return out


def members_of(src):
    out = set(re.findall(r"^(?:static )?func ([a-zA-Z_0-9]+)", src, re.M))
    out |= set(re.findall(r"^(?:@export(?:_[a-z]+)?(?:\([^)]*\))?\s+|@onready\s+)*var ([a-zA-Z_0-9]+)", src, re.M))
    out |= set(re.findall(r"^const ([A-Za-z_0-9]+)", src, re.M))
    out |= set(re.findall(r"^signal ([a-zA-Z_0-9]+)", src, re.M))
    out |= set(re.findall(r"^enum\s+([A-Za-z_0-9]+)", src, re.M))
    return out


# Recursive: scripts/ grew subfolders in Run N+1 (scripts/net/). A non-recursive
# glob silently skipped them, which meant the semantic gate was blind to the
# newest code — exactly the code most likely to be wrong.
files = sorted(glob.glob(os.path.join(SCRIPTS, "**", "*.gd"), recursive=True))
srcs = {os.path.basename(f): read(f) for f in files}

# ---------------------------------------------------------------- 1. arity
print("[1/10] arity of every call site")
defs = collections.defaultdict(list)
for name, src in srcs.items():
    for fn, (req, tot, _a, _r) in signatures(src).items():
        defs[fn].append((req, tot, name))

# AUTOLOAD-QUALIFIED CALLS (added 2026-08-01)
# The original pattern only understood `RunState.`, `BoonEffects.`, `self.` and
# bare calls, so EVERY other autoload-qualified call — FX.x(), Settings.x(),
# SFX.x(), Log.x(), InputRouter.x() — silently escaped the arity check. That is
# how 5 broken `Log.dbg(a, b, c)` calls shipped and stopped the game booting:
# print() takes varargs, Log.dbg() takes one, and nothing flagged it.
#
# The prefix list is read straight out of project.godot's [autoload] block, so
# it stays correct as autoloads are added or renamed.
def autoload_names():
    path = os.path.join(ROOT, "project.godot")
    if not os.path.exists(path):
        return []
    txt = read(path)
    if "[autoload]" not in txt:
        return []
    block = txt.split("[autoload]", 1)[1].split("\n[", 1)[0]
    return re.findall(r"^([A-Za-z_][A-Za-z_0-9]*)\s*=", block, re.M)

_PREFIXES = ["RunState", "BoonEffects", "self"] + autoload_names()
CALL_RE = re.compile(
    r"(?:(?:%s)\.|(?<![\w.]))([a-zA-Z_][a-zA-Z_0-9]*)\s*\("
    % "|".join(sorted(set(_PREFIXES), key=len, reverse=True))
)

for name, src in srcs.items():
    for ln, line in enumerate(src.split("\n"), 1):
        code = line.split("#")[0]
        stripped = code.strip()
        if stripped.startswith("func ") or stripped.startswith("static func "):
            continue
        for m in CALL_RE.finditer(code):
            fn = m.group(1)
            if fn in KEYWORDS or fn not in defs:
                continue
            inner = balanced(code, m.end() - 1)
            if inner is None:
                continue
            n = len(split_args(inner))
            if not any(req <= n <= tot for req, tot, _ in defs[fn]):
                report("arity", "%s:%d  %s() passed %d, definitions expect %s"
                       % (name, ln, fn, n, sorted((r, t) for r, t, _ in defs[fn])))

# ---------------------------------------------------------------- 2. facade
print("[2/10] RunState facade signatures vs BoonEffects")
be_sig = signatures(srcs.get("BoonEffects.gd", ""))
rs_sig = signatures(srcs.get("RunState.gd", ""))
for fn, (req, tot, args, _r) in be_sig.items():
    if fn in rs_sig:
        r2, t2, args2, _r2 = rs_sig[fn]
        if (req, tot) != (r2, t2):
            report("facade", "%s: BoonEffects(%s) vs RunState(%s)" % (fn, args, args2))

# ---------------------------------------------------------------- 3. members
print("[3/10] cross-script member references")
targets = {"RunState": "RunState.gd", "BoonEffects": "BoonEffects.gd",
           "BoonDB": "BoonDB.gd", "BoonDBClass": "BoonDB.gd"}
member_cache = {k: members_of(srcs.get(v, "")) for k, v in targets.items()}
for name, src in srcs.items():
    for ln, line in enumerate(src.split("\n"), 1):
        code = line.split("#")[0]
        code = re.sub(r'"[^"]*"', '""', code)
        for m in re.finditer(r"\b(RunState|BoonEffects|BoonDB|BoonDBClass)\.([a-zA-Z_][a-zA-Z_0-9]*)", code):
            owner, member = m.group(1), m.group(2)
            if member in member_cache[owner] or member in OBJ_METHODS:
                continue
            report("members", "%s:%d  %s.%s does not exist" % (name, ln, owner, member))

# ---------------------------------------------------------------- 4. duplicates
print("[4/10] duplicate declarations")
patterns = [
    ("func", r"^(?:static )?func ([a-zA-Z_0-9]+)\("),
    ("var", r"^(?:@export(?:_[a-z]+)?(?:\([^)]*\))?\s+|@onready\s+)*var ([a-zA-Z_0-9]+)"),
    ("const", r"^const ([A-Za-z_0-9]+)"),
    ("signal", r"^signal ([a-zA-Z_0-9]+)"),
]
for name, src in srcs.items():
    for kind, pat in patterns:
        counts = collections.Counter(re.findall(pat, src, re.M))
        for sym, c in counts.items():
            if c > 1:
                report("duplicate", "%s: %s %s declared %d times" % (name, kind, sym, c))

# ---------------------------------------------------------------- 5. overrides
print("[5/10] child override signatures vs HeroBase")
base = signatures(srcs.get("HeroBase.gd", ""))
for child in ("Shino.gd", "Bea.gd"):
    for fn, (req, tot, args, ret) in signatures(srcs.get(child, "")).items():
        if fn in base:
            breq, btot, bargs, bret = base[fn]
            if (req, tot) != (breq, btot) or ret.replace(" ", "") != bret.replace(" ", ""):
                report("override", "%s: %s(%s)->%s differs from HeroBase(%s)->%s"
                       % (child, fn, args, ret or "void", bargs, bret or "void"))

# ---------------------------------------------------------------- 6. readonly
print("[6/10] writes to getter-only properties")
for name, src in srcs.items():
    lines = src.split("\n")
    readonly = set()
    for i, l in enumerate(lines):
        m = re.match(r"^var ([a-zA-Z_0-9]+)\s*:\s*[A-Za-z_0-9\[\]]+\s*:\s*$", l)
        if not m:
            continue
        blk, j = [], i + 1
        while j < len(lines) and (lines[j].startswith("\t") or lines[j].strip() == ""):
            blk.append(lines[j])
            j += 1
        body = "\n".join(blk)
        if re.search(r"\bget\s*:", body) and not re.search(r"\bset\s*(\(|:)", body):
            readonly.add(m.group(1))
    for sym in readonly:
        for ln, l in enumerate(lines, 1):
            code = l.split("#")[0]
            if re.search(r"(?<![\w.])%s\s*(=[^=]|\+=|-=|\*=|/=)" % re.escape(sym), code) or \
               re.search(r"(?<![\w.])%s\s*\.\s*(append|clear|erase|push_back|remove_at)\s*\(" % re.escape(sym), code):
                report("readonly", "%s:%d  write to getter-only '%s'" % (name, ln, sym))

# ---------------------------------------------------------------- 7. shadowing
print("[7/10] child shadowing of parent members")
def decls(src):
    return (set(re.findall(r"^(?:@export(?:_[a-z]+)?(?:\([^)]*\))?\s+|@onready\s+)*var ([a-zA-Z_0-9]+)", src, re.M)),
            set(re.findall(r"^const ([A-Za-z_0-9]+)", src, re.M)))
bv, bc = decls(srcs.get("HeroBase.gd", ""))
for child in ("Shino.gd", "Bea.gd"):
    cv, cc = decls(srcs.get(child, ""))
    for sym in sorted(bv & cv):
        report("shadow", "%s: var %s also declared in HeroBase" % (child, sym))
    for sym in sorted(bc & cc):
        report("shadow", "%s: const %s also declared in HeroBase" % (child, sym))

# ------------------------------------------------- 8. base uses child-only member
# THE Run 157 CRASH. HeroBase.restore_move_speed_baseline() (added Run 155) read
# and wrote `move_speed`, which was declared only in Shino.gd / Bea.gd. A base
# class may not reference a member that exists only on its subclasses — Godot
# rejects the base with "Identifier not declared in the current scope", the
# class_name never registers, and every subclass reports the misleading
# "Could not resolve class 'HeroBase'" at its extends line. Costly to diagnose,
# trivial to detect.
print("[8/10] base class referencing child-only members")

GODOT_BUILTINS = set("""
self true false null PI INF NAN TAU
velocity global_position position rotation scale modulate visible name owner
z_index z_as_relative global_rotation global_scale top_level motion_mode
up_direction collision_layer collision_mask process_mode material light_mask
texture centered offset flip_h flip_v
add_child remove_child get_tree get_parent get_node get_node_or_null get_children
queue_free is_instance_valid move_and_slide move_and_collide look_at to_local
to_global create_tween add_to_group remove_from_group is_in_group find_child
add_collision_exception_with remove_collision_exception_with
min max abs round floor ceil clamp clampf clampi minf maxf mini maxi lerp lerpf
randf randi randf_range randi_range sign snapped pow sqrt sin cos atan2 fmod
deg_to_rad rad_to_deg move_toward str int float bool typeof len load preload
print push_error push_warning range is_equal_approx is_zero_approx
""".split()) | OBJ_METHODS | KEYWORDS

base_src = srcs.get("HeroBase.gd", "")
base_members = members_of(base_src)
child_only = {}
for child in ("Shino.gd", "Bea.gd"):
    child_only[child] = members_of(srcs.get(child, "")) - base_members

base_lines = base_src.split("\n")
func_spans = []
for i, l in enumerate(base_lines):
    m = re.match(r"^(?:static\s+)?func\s+([A-Za-z_]\w*)\(([^)]*)\)", l)
    if m:
        func_spans.append([i, m.group(2)])
for idx, fs in enumerate(func_spans):
    fs.append(func_spans[idx + 1][0] if idx + 1 < len(func_spans) else len(base_lines))

for start, params, end in func_spans:
    scope = set()
    for p in params.split(","):
        p = p.strip()
        if p:
            scope.add(re.split(r"[:=]", p)[0].strip())
    body = base_lines[start:end]
    for l in body:
        scope |= set(re.findall(r"\bvar\s+([A-Za-z_]\w*)", l))
        scope |= set(re.findall(r"\bfor\s+([A-Za-z_]\w*)\s+in\b", l))
        for lam in re.findall(r"func\s*\(([^)]*)\)", l):
            for p in lam.split(","):
                p = p.strip()
                if p:
                    scope.add(re.split(r"[:=]", p)[0].strip())
    for off, l in enumerate(body):
        code = l.split("#")[0]
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
        code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)
        for m in re.finditer(r"(?<![\w.])([a-z_][A-Za-z_0-9]*)\b", code):
            sym = m.group(1)
            if sym in base_members or sym in scope or sym in GODOT_BUILTINS:
                continue
            owners = [c for c, syms in child_only.items() if sym in syms]
            if owners:
                report("base-uses-child",
                       "HeroBase.gd:%d references '%s', which is declared only in %s"
                       % (start + off + 1, sym, ", ".join(owners)))

# ---------------------------------------------------------------------------
# 9. const initialised with a non-constant expression
# ---------------------------------------------------------------------------
# WHY THIS CHECK EXISTS (added 2026-07-31)
# GDScript only folds VALUE types into constant expressions. Writing
#     const LABEL: PackedByteArray = PackedByteArray([83, 66, 45, 67])
# parses fine — gdparse accepts it happily — but Godot's ANALYZER rejects it at
# load time with "Assigned value for constant X isn't a constant expression."
# When that happens in an autoload dependency (it happened in NetSecurity.gd)
# the whole game refuses to boot, and the only clue is a red line in the editor.
#
# This is precisely the gdparse-passes-but-Godot-rejects class this tool exists
# to catch, so it belongs here rather than in the syntax gate.
#
# FIX: use `static var` instead of `const`. Its initialiser is evaluated at
# class-load time, so a constructor call is legal, and read syntax at every
# call site is unchanged.
print("[9/10] const initialisers that aren't constant expressions")

# Built-in VALUE types — GDScript folds these at compile time, so calling their
# constructor inside a const initialiser is legal.
CONST_SAFE_CTORS = {
    "Color", "Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i",
    "Rect2", "Rect2i", "Transform2D", "Transform3D", "Basis", "Quaternion",
    "Plane", "AABB", "Projection", "StringName", "NodePath",
}

for path, src in srcs.items():
    for lineno, raw in enumerate(src.splitlines(), 1):
        stripped = raw.strip()
        if not stripped.startswith("const "):
            continue
        if "=" not in stripped:
            continue
        rhs = stripped.split("=", 1)[1]
        # Strip trailing comments and string literals so words inside them
        # (e.g. "# Run 49b — -20% per Bruno (was 420)") can't masquerade as calls.
        rhs = rhs.split("#")[0]
        rhs = re.sub(r'"(?:[^"\\]|\\.)*"', '""', rhs)
        rhs = re.sub(r"'(?:[^'\\]|\\.)*'", "''", rhs)
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\s*\(", rhs):
            ctor = m.group(1)
            if ctor in CONST_SAFE_CTORS:
                continue
            name = stripped.split()[1].split(":")[0].split("=")[0].strip()
            report("const-not-constant",
                   "%s:%d  const '%s' is initialised with %s(...) — not a constant "
                   "expression. Godot will refuse to load this script. Use "
                   "`static var` instead."
                   % (os.path.basename(path), lineno, name, ctor))
            break

# ---------------------------------------------------------------------------
# 10. script referenced by name but missing `class_name`
# ---------------------------------------------------------------------------
# WHY THIS CHECK EXISTS (added 2026-08-01)
# Shino.gd called `DeathScreen.show_for(self)` while DeathScreen.gd declared no
# `class_name`, so the identifier did not exist globally:
#     Identifier "DeathScreen" not declared in the current scope.
# gdparse accepts it (it is valid syntax), and it only surfaced at runtime when
# the player loaded a save — i.e. the worst possible time to find it.
#
# Deliberately NARROW to stay false-positive free: it only fires when
#   (a) something is used as `Foo.` in another script, AND
#   (b) a file named Foo.gd actually exists in scripts/, AND
#   (c) that file declares no `class_name`, AND
#   (d) Foo is not an autoload.
# That combination is always a bug. Unknown identifiers with no matching file
# are left alone — those are Godot builtins and not our business.
print("[10/10] scripts used by name but missing class_name")

_autoloads = set(autoload_names())
_file_stems = {}          # "DeathScreen" -> path
_declared = set()         # stems that DO declare class_name
for _f in files:
    stem = os.path.basename(_f)[:-3]
    _file_stems[stem] = _f
    if re.search(r"^class_name\s+", read(_f), re.M):
        _declared.add(stem)

for name, src in srcs.items():
    own_stem = name[:-3]
    # A file may bind the symbol locally instead of relying on a global
    # class_name — the common idiom being
    #     const NetSecurity := preload("res://scripts/net/NetSecurity.gd")
    # That is completely valid, so anything bound in THIS file is exempt.
    # (Missing this exemption produced 121 false positives on the netcode and
    # FamilySprites when the check was first written.)
    _local_binds = set(re.findall(
        r"^\s*(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)", src, re.M))
    for ln, line in enumerate(src.split("\n"), 1):
        code = line.split("#")[0]
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
        code = re.sub(r"'(?:[^'\\]|\\.)*'", "''", code)
        for m in re.finditer(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\s*\.", code):
            sym = m.group(1)
            if sym == own_stem or sym in _autoloads or sym in _declared:
                continue
            if sym in _local_binds:
                continue          # locally preloaded / assigned — valid
            if sym not in _file_stems:
                continue          # not one of ours — a Godot builtin
            report("missing-class-name",
                   "%s:%d  uses '%s.' but %s declares no `class_name %s`, is not "
                   "an autoload, and is not preloaded locally — the identifier "
                   "won't resolve at load time."
                   % (name, ln, sym, os.path.basename(_file_stems[sym]), sym))

print()
if findings:
    print("FAILED — %d finding(s)" % len(findings))
    sys.exit(1)
print("gdcheck: CLEAN (%d scripts)" % len(srcs))
sys.exit(0)
