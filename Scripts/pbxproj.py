#!/usr/bin/env python3
"""Minimal, dependency-free editor for SequelPG.xcodeproj/project.pbxproj.

The project uses explicit file references (objectVersion 56), so every new
.swift file must be registered by hand. This script does that surgically —
it only inserts lines, never reformats the file.

Usage:
  Scripts/pbxproj.py add-file <repo-relative path> --targets T1[,T2...]
  Scripts/pbxproj.py add-test-target --name N --kind unit|ui --folder DIR --bundle-id ID
  Scripts/pbxproj.py list-targets

Examples:
  Scripts/pbxproj.py add-file SequelPGUITests/QueryUITests.swift --targets SequelPGUITests
  Scripts/pbxproj.py add-file SequelPGApp/Utilities/AccessibilityIDs.swift --targets SequelPG,SequelPGUITests
"""
import argparse
import os
import re
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "SequelPG.xcodeproj", "project.pbxproj")
APP_TARGET = "SequelPG"


def new_id():
    return uuid.uuid4().hex[:24].upper()


def load():
    with open(PBX, encoding="utf-8") as f:
        return f.read()


def save(text):
    with open(PBX, "w", encoding="utf-8") as f:
        f.write(text)


def insert_before(text, marker, block):
    idx = text.index(marker)
    return text[:idx] + block + text[idx:]


def object_block(text, obj_id):
    """Returns (start, end) of `\t\tID /* … */ = { … };` for obj_id."""
    m = re.search(r"\n\t\t" + re.escape(obj_id) + r" (/\*.*?\*/ )?= \{", text)
    if not m:
        raise SystemExit(f"object {obj_id} not found")
    start = m.start() + 1
    end = text.index("\n\t\t};", start) + len("\n\t\t};")
    return start, end


def append_to_list(text, obj_id, key, entry):
    """Appends `entry,` to the `key = ( … );` list inside object obj_id."""
    start, end = object_block(text, obj_id)
    block = text[start:end]
    m = re.search(r"(\n(\t+)" + key + r" = \()(.*?)(\n\t+\);)", block, re.S)
    if not m:
        raise SystemExit(f"{key} list not found in {obj_id}")
    indent = m.group(2) + "\t"
    body = m.group(3)
    if entry.split(" ")[0] in body:
        return text
    new_body = body + f"\n{indent}{entry},"
    block = block[: m.start(3)] + new_body + block[m.end(3):]
    return text[:start] + block + text[end:]


def targets(text):
    """name -> (target id, sources phase id)."""
    out = {}
    for m in re.finditer(r"\n\t\t(\w+) /\* ([^\n]*?) \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};", text, re.S):
        tid, name, body = m.group(1), m.group(2), m.group(3)
        sm = re.search(r"(\w+) /\* Sources \*/", body)
        out[name] = (tid, sm.group(1) if sm else None)
    return out


def groups(text):
    """Returns {full folder path: group id} for groups with a `path`."""
    info = {}
    for m in re.finditer(r"\n\t\t(\w+) /\* ([^\n]*?) \*/ = \{\n\t\t\tisa = PBXGroup;(.*?)\n\t\t\};", text, re.S):
        gid, body = m.group(1), m.group(3)
        children = re.findall(r"\n\t\t\t\t(\w+) /\*", body)
        pm = re.search(r"\n\t\t\tpath = (.*?);", body)
        path = pm.group(1).strip('"') if pm else None
        info[gid] = (path, children)
    parent = {c: g for g, (_, ch) in info.items() for c in ch}

    def full(gid):
        parts = []
        while gid in info:
            if info[gid][0]:
                parts.append(info[gid][0])
            gid = parent.get(gid)
        return "/".join(reversed(parts))

    return {full(g): g for g, (p, _) in info.items() if p}


def root_group(text):
    return re.search(r"mainGroup = (\w+)", text).group(1)


def ensure_group(text, folder):
    gmap = groups(text)
    if folder in gmap:
        return text, gmap[folder]
    parent_folder, name = os.path.split(folder)
    if parent_folder:
        text, parent_id = ensure_group(text, parent_folder)
    else:
        parent_id = root_group(text)
    gid = new_id()
    block = (
        f"\t\t{gid} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n"
        f"\t\t\tpath = {name};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
    )
    text = insert_before(text, "/* End PBXGroup section */", block)
    text = append_to_list(text, parent_id, "children", f"{gid} /* {name} */")
    return text, gid


def add_file(text, relpath, target_names):
    name = os.path.basename(relpath)
    folder = os.path.dirname(relpath)
    if re.search(r"/\* " + re.escape(name) + r" \*/ = \{isa = PBXFileReference", text):
        raise SystemExit(f"{name} is already registered")
    text, gid = ensure_group(text, folder)
    ref = new_id()
    ftype = "sourcecode.swift" if name.endswith(".swift") else "text"
    text = insert_before(
        text,
        "/* End PBXFileReference section */",
        f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {name}; sourceTree = \"<group>\"; }};\n",
    )
    text = append_to_list(text, gid, "children", f"{ref} /* {name} */")
    tmap = targets(text)
    for t in target_names:
        if t not in tmap:
            raise SystemExit(f"unknown target {t}; known: {', '.join(tmap)}")
        bid = new_id()
        text = insert_before(
            text,
            "/* End PBXBuildFile section */",
            f"\t\t{bid} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n",
        )
        text = append_to_list(text, tmap[t][1], "files", f"{bid} /* {name} in Sources */")
    return text


def project_id(text):
    return re.search(r"rootObject = (\w+)", text).group(1)


def build_settings(kind, bundle_id, version, build, config):
    common = {
        "CODE_SIGN_IDENTITY": '"-"',
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": build,
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": version,
        "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_VERSION": "5.0",
    }
    if kind == "unit":
        common["BUNDLE_LOADER"] = '"$(TEST_HOST)"'
        common["TEST_HOST"] = '"$(BUILT_PRODUCTS_DIR)/SequelPG.app/Contents/MacOS/SequelPG"'
    else:
        common["TEST_TARGET_NAME"] = APP_TARGET
    lines = "".join(f"\t\t\t\t{k} = {v};\n" for k, v in sorted(common.items()))
    return lines


def add_test_target(text, name, kind, folder, bundle_id):
    if name in targets(text):
        raise SystemExit(f"target {name} already exists")
    app_id = targets(text)[APP_TARGET][0]
    proj = project_id(text)
    version = re.search(r"MARKETING_VERSION = (.*?);", text).group(1)
    build = re.search(r"CURRENT_PROJECT_VERSION = (.*?);", text).group(1)
    ids = {k: new_id() for k in ("target", "sources", "frameworks", "product", "proxy", "dep", "cfglist", "debug", "release")}
    product_type = "com.apple.product-type.bundle.unit-test" if kind == "unit" else "com.apple.product-type.bundle.ui-testing"

    text = insert_before(text, "/* End PBXContainerItemProxy section */",
        f"\t\t{ids['proxy']} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {proj} /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {app_id};\n\t\t\tremoteInfo = {APP_TARGET};\n\t\t}};\n")
    text = insert_before(text, "/* End PBXFileReference section */",
        f"\t\t{ids['product']} /* {name}.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
        f"includeInIndex = 0; path = {name}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    text = insert_before(text, "/* End PBXFrameworksBuildPhase section */",
        f"\t\t{ids['frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_before(text, "/* End PBXSourcesBuildPhase section */",
        f"\t\t{ids['sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_before(text, "/* End PBXTargetDependency section */",
        f"\t\t{ids['dep']} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {app_id} /* {APP_TARGET} */;\n\t\t\ttargetProxy = {ids['proxy']} /* PBXContainerItemProxy */;\n\t\t}};\n")
    text = insert_before(text, "/* End PBXNativeTarget section */",
        f"\t\t{ids['target']} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {ids['cfglist']} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{ids['sources']} /* Sources */,\n\t\t\t\t{ids['frameworks']} /* Frameworks */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t{ids['dep']} /* PBXTargetDependency */,\n\t\t\t);\n"
        f"\t\t\tname = {name};\n\t\t\tproductName = {name};\n"
        f"\t\t\tproductReference = {ids['product']} /* {name}.xctest */;\n"
        f"\t\t\tproductType = \"{product_type}\";\n\t\t}};\n")
    for cfg in ("debug", "release"):
        cname = cfg.capitalize()
        text = insert_before(text, "/* End XCBuildConfiguration section */",
            f"\t\t{ids[cfg]} /* {cname} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n"
            f"{build_settings(kind, bundle_id, version, build, cfg)}\t\t\t}};\n\t\t\tname = {cname};\n\t\t}};\n")
    text = insert_before(text, "/* End XCConfigurationList section */",
        f"\t\t{ids['cfglist']} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{ids['debug']} /* Debug */,\n\t\t\t\t{ids['release']} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")

    products = re.search(r"productRefGroup = (\w+)", text).group(1)
    text = append_to_list(text, products, "children", f"{ids['product']} /* {name}.xctest */")
    text = append_to_list(text, proj, "targets", f"{ids['target']} /* {name} */")
    # TargetAttributes
    m = re.search(r"(\n\t\t\t\tTargetAttributes = \{\n)", text)
    attr = (f"\t\t\t\t\t{ids['target']} = {{\n\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
            f"\t\t\t\t\t\tTestTargetID = {app_id};\n\t\t\t\t\t}};\n")
    text = text[: m.end()] + attr + text[m.end():]
    text, _ = ensure_group(text, folder)
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add-file")
    a.add_argument("path")
    a.add_argument("--targets", required=True)
    t = sub.add_parser("add-test-target")
    t.add_argument("--name", required=True)
    t.add_argument("--kind", choices=["unit", "ui"], required=True)
    t.add_argument("--folder", required=True)
    t.add_argument("--bundle-id", required=True)
    sub.add_parser("list-targets")
    args = ap.parse_args()

    text = load()
    if args.cmd == "list-targets":
        for name, (tid, src) in targets(text).items():
            print(f"{name}\ttarget={tid}\tsources={src}")
        return
    if args.cmd == "add-file":
        path = os.path.relpath(os.path.abspath(args.path), ROOT) if os.path.isabs(args.path) else args.path
        if not os.path.exists(os.path.join(ROOT, path)):
            sys.exit(f"{path} does not exist — create the file first")
        text = add_file(text, path, [s.strip() for s in args.targets.split(",") if s.strip()])
    elif args.cmd == "add-test-target":
        text = add_test_target(text, args.name, args.kind, args.folder, args.bundle_id)
    save(text)
    print("project.pbxproj updated")


if __name__ == "__main__":
    main()
