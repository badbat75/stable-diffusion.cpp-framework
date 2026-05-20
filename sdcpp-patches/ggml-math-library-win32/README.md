# ggml-math-library-win32

Restores Windows/MSVC builds of ggml on commits where `src/CMakeLists.txt`
links `ggml-base` against the bare `${MATH_LIBRARY}` cache variable. On
Windows, `find_library(MATH_LIBRARY m)` (called from ggml's own
`tests/CMakeLists.txt`) sets the cache to `MATH_LIBRARY-NOTFOUND`, which then
becomes `DEFINED` but invalid as a link argument. CMake errors out at
generate time with:

```
CMake Error: The following variables are used in this project, but they are
set to NOTFOUND: MATH_LIBRARY linked by target "ggml-base"
```

The patch swaps `if (DEFINED MATH_LIBRARY)` for `if (MATH_LIBRARY)`, so
`MATH_LIBRARY-NOTFOUND` evaluates falsy and the broken link line is skipped.
This matches the upstream revert in ggml `74f21355` ("ggml : revert to -lm
linking instead of find_library", in `v0.10.1`) — but ggml's submodule SHA in
sd.cpp `master` still points at the broken `0ce7ad34` (introduced by
`a06bdb67`, "ggml-base: use MATH_LIBRARY variable instead of hardcoded 'm'"),
so we carry the fix locally until sd.cpp bumps its ggml gitlink past the
revert.

## Scope

This is a **submodule patch**: it targets files inside `<clone>/ggml/`, not
sd.cpp's root tree. `patch-lib.ps1` handles `ggml.patch` by `git -C
<clone>/ggml apply`-ing the diff. Reset-SdCppClone resets the ggml submodule
to its tracked SHA as well, so each build sees a clean tree.

## Already-applied detection

Once sd.cpp bumps ggml past `74f21355`, the patched line will already be in
the file. `Invoke-SdCppPatches` detects this by trying `git apply --reverse
--check`: if the reversed patch applies cleanly, we treat the patch as
already-merged upstream and skip it silently. At that point this patch set
can be deleted.

## Regenerating

Not expected — the diff is a single-line change to a well-known block. If
upstream restructures the math-library block before the revert lands in
sd.cpp's pinned ggml, edit the patch by hand against the new context.
