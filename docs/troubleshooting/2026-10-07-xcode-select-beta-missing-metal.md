# Build fails with "missing Metal Toolchain" after the active Xcode changed (2026-10-07)

## Symptom

`xcodebuild` for the iPhone or Mac target stops with `cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain`, although the same tree built minutes earlier. SwiftTerm compiles Metal shaders, so every target that links it needs the component.

## Cause (verified)

Another task switched the system Xcode (`xcode-select -p`) to `/Applications/Xcode-27.2-beta-2.app`, whose Metal Toolchain component was not installed (`xcodebuild -showComponent MetalToolchain` → `Status: uninstalled`). Downloading it for the beta failed with a general networking error. The stable `/Applications/Xcode.app` (27.0) still had the component.

## Remedy

Do not change `xcode-select` for the whole machine (other tasks rely on it). Pin the developer directory per command:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -showComponent MetalToolchain   # must not say "uninstalled"
```

then build as usual. Install the component for a new Xcode with `xcodebuild -downloadComponent MetalToolchain` when the network allows.

## Environment improvement (open)

Build scripts (`scripts/ios_sim.sh`, Mac release scripts) inherit whatever `xcode-select` points to. They should check the Metal component of the selected Xcode before compiling and name the fix, instead of failing deep in the SwiftTerm package build.

<!-- 该文档整理/压缩于 2026-10-20 -->
