#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Stage 0A native diagnostics — crash report parser.

Reads a macOS crash report and extracts the SIGILL root-cause evidence the
diagnostic needs. It NEVER invents data: every field is taken from the report
itself. FRAME_OWNER is DERIVED FROM THE REPORT (the image a frame belongs to),
never inferred from the fact that the signal was SIGILL.

Supports both modern `.ips` (JSON, possibly with a prepended metadata object)
and legacy plain-text `.crash` reports.

Subcommands:
  latest <dir> <binary_basename>
        Scan <dir> for reports whose filename contains <binary_basename>,
        pick the NEWEST, print CRASH_REPORT_FOUND + parsed fields.
        The real (non-redacted) path is printed to STDERR as REALPATH= so the
        caller can re-parse it without leaking it into the user-facing report.
  one <path>
        Parse a single report file and print the parsed fields.

PRIVACY: every path printed on STDOUT is redacted to /Users/<redacted>/...
No HOME prefix, username, token, environment, or projects.json content is
ever emitted. The real path (STDERR only) is used internally for mtime/parsing.
"""
import json
import os
import sys
import glob

REDACT_USER = os.path.basename(os.path.expanduser("~"))


def redact(p):
    if not p:
        return p
    home = os.path.expanduser("~")
    if p.startswith(home):
        p = "/Users/<redacted>" + p[len(home):]
    p = p.replace("/" + REDACT_USER + "/", "/<redacted>/")
    return p


def classify_owner(name, path, bundle_id):
    """Map a loaded image to FRAME_OWNER enum, strictly from report data."""
    n = (name or "").lower()
    pa = (path or "").lower()
    b = (bundle_id or "").lower()
    if n == "stage0a-vz-tool":
        return "PROTOTYPE"
    if n == "hypervisor" or "hypervisor.framework" in pa or b == "com.apple.hypervisor":
        return "HYPERVISOR"
    if n == "virtualization" or "virtualization.framework" in pa or b == "com.apple.virtualization":
        return "VIRTUALIZATION"
    if n == "dyld":
        return "DYLD"
    if "libsystem" in n or "/usr/lib/system/" in pa:
        return "LIBSYSTEM"
    if ("amfi" in n or "security" in n or "sandbox" in n or "tcc" in n
            or b.startswith("com.apple.security") or b == "com.apple.sandbox"):
        return "AMFI_SECURITY"
    return "OTHER"


# --------------------------------------------------------------------------
# JSON (.ips) loading: tolerate a prepended metadata object.
# --------------------------------------------------------------------------
def load_json(path):
    text = open(path, "r", errors="replace").read()
    try:
        return json.loads(text)
    except Exception:
        pass
    # Extract all top-level JSON objects and prefer the one with "exception".
    candidates = []
    depth = 0
    in_str = False
    esc = False
    obj_start = -1
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                obj_start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and obj_start != -1:
                candidates.append(text[obj_start:i + 1])
                obj_start = -1
    for cand in candidates:
        try:
            obj = json.loads(cand)
        except Exception:
            continue
        if isinstance(obj, dict) and "exception" in obj:
            return obj
    if candidates:
        return json.loads(candidates[-1])
    raise ValueError("no JSON object found in report")


# --------------------------------------------------------------------------
# Plain-text (.crash) loading: defensive best-effort fallback.
# --------------------------------------------------------------------------
def load_text(path):
    text = open(path, "r", errors="replace").read()
    data = {}
    lines = text.splitlines()

    def grab(*keys):
        for line in lines:
            for k in keys:
                if line.startswith(k + ":"):
                    return line.split(":", 1)[1].strip()
        return None

    et = grab("Exception Type")
    codes = grab("Exception Codes")
    term = grab("Termination Reason", "Termination Signal")
    ft = grab("Triggered Thread")
    sig = (et or "").split()[0] if et else "UNKNOWN"
    data["exception"] = {
        "type": et or "UNKNOWN",
        "signal": sig,
        "codes": codes or "UNKNOWN",
    }
    ns = (term.split(":")[0] if term else "UNKNOWN")
    data["termination"] = {
        "indicator": term or "UNKNOWN",
        "namespace": ns,
        "code": "",
    }

    threads = []
    images = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # "Thread N Crashed:" block
        if line.startswith("Thread") and "Crashed:" in line:
            frames = []
            j = i + 1
            while j < len(lines):
                ls = lines[j]
                if not ls.strip():
                    break
                if not (ls.startswith(" ") or ls.startswith("\t")):
                    break
                parts = ls.split(None, 4)
                if len(parts) >= 4:
                    frames.append({
                        "imageIndex": -1,
                        "symbol": parts[4] if len(parts) > 4 else "",
                        "imageName": parts[1],
                    })
                j += 1
            threads.append({"frames": frames, "triggered": True})
            i = j
            continue
        # "Binary Images:" section
        if line.startswith("Binary Images:"):
            j = i + 1
            while j < len(lines) and lines[j].strip():
                m = __import__("re").match(r"\S+ - \S+ (.+?) @ (.+)", lines[j])
                if m:
                    images.append({"name": m.group(1), "path": m.group(2)})
                j += 1
            i = j
            continue
        i += 1

    data["threads"] = threads
    data["usedImages"] = images
    ft_i = None
    try:
        ft_i = int(ft)
    except Exception:
        ft_i = None
    if isinstance(ft_i, int) and 0 <= ft_i < len(threads):
        data["faultingThread"] = ft_i
    elif threads:
        data["faultingThread"] = 0
    return data


def load_report(path):
    try:
        return load_json(path)
    except Exception:
        pass
    try:
        return load_text(path)
    except Exception as e:
        raise ValueError("cannot parse report: %s" % e)


# --------------------------------------------------------------------------
# Field extraction (common to both formats).
# --------------------------------------------------------------------------
def extract_fields(data):
    out = {}
    exc = data.get("exception", {}) or {}
    out["EXCEPTION_TYPE"] = str(exc.get("type", "UNKNOWN"))
    raw = exc.get("codes", exc.get("rawCodes", "UNKNOWN"))
    if isinstance(raw, list):
        raw = ",".join(str(x) for x in raw)
    out["EXCEPTION_CODES"] = str(raw)
    term = data.get("termination", {}) or {}
    ns = term.get("namespace", "")
    code = term.get("code", "")
    ind = term.get("indicator", "")
    out["TERMINATION_REASON"] = ("%s/%s %s" % (ns, code, ind)).strip()
    ft = data.get("faultingThread", None)
    out["TRIGGERED_THREAD"] = str(ft) if ft is not None else "UNKNOWN"

    threads = data.get("threads", []) or []
    images = data.get("usedImages", []) or []

    def img_info(idx):
        if isinstance(idx, int) and 0 <= idx < len(images):
            im = images[idx]
            if isinstance(im, dict):
                return im.get("name"), im.get("path"), im.get("CFBundleIdentifier")
        return (None, None, None)

    tthread = None
    if isinstance(ft, int) and 0 <= ft < len(threads):
        tthread = threads[ft]
    elif threads:
        for t in threads:
            if t.get("triggered"):
                tthread = t
                break
        if tthread is None:
            tthread = threads[0]

    frames = (tthread or {}).get("frames", []) or []
    for n in range(10):
        if n < len(frames):
            f = frames[n]
            sym = f.get("symbol") or f.get("imageName") or ""
            nm, ph, bd = img_info(f.get("imageIndex"))
            if (nm is None) and f.get("imageName"):
                nm = f.get("imageName")
            owner = classify_owner(nm, ph, bd)
            label = sym if sym else "offset:%s" % f.get("imageOffset", "?")
            out["CRASH_FRAME_%d" % n] = "%s [%s]" % (label, owner)
        else:
            out["CRASH_FRAME_%d" % n] = "NONE"

    # FRAME_OWNER: among the triggered thread's frames, surface the VM-machinery
    # frame closest to the crash origin (leaf-ward first). Fall back to frame 0.
    owner_priority = {"PROTOTYPE": 3, "HYPERVISOR": 2, "VIRTUALIZATION": 1}
    fo = "UNKNOWN"
    if frames:
        nm0, ph0, bd0 = img_info(frames[0].get("imageIndex"))
        if (nm0 is None) and frames[0].get("imageName"):
            nm0 = frames[0].get("imageName")
        fo = classify_owner(nm0, ph0, bd0)
        best = None
        for f in frames:
            nm, ph, bd = img_info(f.get("imageIndex"))
            if (nm is None) and f.get("imageName"):
                nm = f.get("imageName")
            ow = classify_owner(nm, ph, bd)
            if ow in owner_priority and best is None:
                best = ow
        if best is not None:
            fo = best
    out["FRAME_OWNER"] = fo
    return out


FIELDS = (["EXCEPTION_TYPE", "EXCEPTION_CODES", "TERMINATION_REASON", "TRIGGERED_THREAD"]
          + ["CRASH_FRAME_%d" % n for n in range(10)]
          + ["FRAME_OWNER"])


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: parse_crash.py (latest <dir> <basename> | one <path>)\n")
        sys.exit(2)
    cmd = sys.argv[1]

    if cmd == "one":
        path = sys.argv[2]
        try:
            data = load_report(path)
        except Exception as e:
            print("CRASH_REPORT_PARSE=FAILED")
            print("CRASH_REPORT_PARSE_ERROR=" + redact(str(e)))
            sys.exit(0)
        for k in FIELDS:
            print("%s=%s" % (k, extract_fields(data).get(k, "UNKNOWN")))
        sys.exit(0)

    if cmd == "latest":
        d = sys.argv[2]
        base = sys.argv[3] if len(sys.argv) > 3 else "stage0a-vz-tool"
        files = []
        for pat in ("*.ips", "*.crash"):
            for fp in glob.glob(os.path.join(d, pat)):
                if base in os.path.basename(fp):
                    files.append(fp)
        if not files:
            print("CRASH_REPORT_FOUND=NO")
            sys.exit(0)
        files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
        latest = files[0]
        # REALPATH to STDERR only (kept out of the user-facing report)
        sys.stderr.write("REALPATH=%s\n" % latest)
        print("CRASH_REPORT_FOUND=YES")
        print("CRASH_REPORT_COUNT=%d" % len(files))
        print("CRASH_REPORT_PATH=%s" % redact(latest))
        print("CRASH_REPORT_MTIME=%d" % int(os.path.getmtime(latest)))
        try:
            data = load_report(latest)
        except Exception as e:
            print("CRASH_REPORT_PARSE=FAILED")
            print("CRASH_REPORT_PARSE_ERROR=" + redact(str(e)))
            sys.exit(0)
        for k in FIELDS:
            print("%s=%s" % (k, extract_fields(data).get(k, "UNKNOWN")))
        sys.exit(0)

    sys.stderr.write("unknown subcommand: %s\n" % cmd)
    sys.exit(2)


if __name__ == "__main__":
    main()
