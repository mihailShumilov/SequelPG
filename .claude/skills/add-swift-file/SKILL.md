---
name: add-swift-file
description: Add a new Swift source or test file to SequelPG and register it in SequelPG.xcodeproj/project.pbxproj (the project uses explicit file references, so new files are not picked up automatically). Use whenever creating a new .swift file in SequelPGApp/ or SequelPGTests/.
---

# Add a Swift file to the Xcode project

`project.pbxproj` uses objectVersion 56 with explicit file references. A `.swift` file that exists on disk but isn't registered is silently ignored by the build.

## 1. Create the file

Put it in the folder matching its layer: `SequelPGApp/{Models,Services,ViewModels,Views,Utilities}/` or `SequelPGTests/`.

## 2. Pick two unused ids

Every file needs a build-file id (`AA…`) and a file-reference id (`AB…`), 24 hex characters each. Ids are not strictly sequential, so check before using one:

```bash
P=SequelPG.xcodeproj/project.pbxproj
grep -o 'AA1000000000000000[0-9A-F]*' $P | sort -u | tail -5   # see recent ids
grep -c 'AA10000000000000000E30' $P                          # must print 0
grep -c 'AB10000000000000000E30' $P                          # must print 0
```

Use the same suffix for the pair (`AA…E30` / `AB…E30`).

## 3. Insert four entries

Copy the entries of a sibling file as the template (e.g. `ResultExporter.swift` for app code, `QuoteIdentTests.swift` for tests):

| Section | Entry |
| --- | --- |
| `PBXBuildFile` | `AA…E30 /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = AB…E30; };` |
| `PBXFileReference` | `AB…E30 /* Foo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = "<group>"; };` |
| Group `children` | `AB…E30 /* Foo.swift */,` in the folder's group |
| Sources phase `files` | `AA…E30 /* Foo.swift in Sources */,` in the target's phase |

Group and phase ids:

| Folder | Group | Sources phase |
| --- | --- | --- |
| `SequelPGApp/Models` | `AC20000000000000000003` | `AF10000000000000000012` (app) |
| `SequelPGApp/Services` | `AC20000000000000000004` | `AF10000000000000000012` |
| `SequelPGApp/ViewModels` | `AC20000000000000000005` | `AF10000000000000000012` |
| `SequelPGApp/Views` | `AC20000000000000000006` | `AF10000000000000000012` |
| `SequelPGApp/Utilities` | `AC20000000000000000007` | `AF10000000000000000012` |
| `SequelPGTests` | `AC20000000000000000009` | `AF10000000000000000013` (tests) |

Verify these ids with `grep -n "AC2000000000000000000[0-9A-F] /\*" $P` if the project layout has changed. Keep entries alphabetized within each list when the neighbors are.

## 4. Verify

```bash
grep -c 'E30' SequelPG.xcodeproj/project.pbxproj   # expect 4
```

Then build (see `build-and-test`). Never regenerate or reformat `project.pbxproj` wholesale; edit only the four lines.
