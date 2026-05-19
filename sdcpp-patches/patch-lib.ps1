# Apply library for sdcpp-patches\ — local, version-controlled modifications
# layered onto the (gitignored, auto-pulled) stable-diffusion.cpp clone.
#
# Each subfolder of sdcpp-patches\ is one patch set:
#   <name>\src\*           - NEW header-only sources, COPIED into <clone>\src\
#   <name>\wiring.patch    - unified diff against tracked upstream files
#   <name>\base-commit.txt - upstream SHA the patch was generated against
#   <name>\README.md       - what it is + how to regenerate the patch
#
# Contract: the clone's working tree is patched only DURING a build. Both
# 00-install-prerequisites.ps1 and 02-build-server.ps1 call Reset-SdCppClone
# before `git pull --ff-only` (so the pull always fast-forwards a clean tree
# and never throws) and Invoke-SdCppPatches after the pull/submodule sync, so
# patches are re-applied fresh on every build. This file defines functions
# only (no $cfg dependency) so 00-install-prerequisites.ps1 — which must run
# on a bare machine before 01-configure.ps1 — can dot-source it safely.

function Get-SdCppPatchSets {
    param([Parameter(Mandatory)][string]$PatchRoot)
    if (-not (Test-Path $PatchRoot)) { return @() }
    Get-ChildItem -Path $PatchRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name
}

function Reset-SdCppClone {
    # Revert every patch-set modification so `git pull --ff-only` sees a clean
    # tree. Tracked-file edits are undone with `reset --hard HEAD` (HEAD does
    # NOT move, so the rebuild-detection report stays accurate); the untracked
    # headers we copied in are deleted by name. Submodules are never touched.
    param(
        [Parameter(Mandatory)][string]$CloneDir,
        [Parameter(Mandatory)][string]$PatchRoot
    )
    if (-not (Test-Path "$CloneDir\.git")) { return }
    git -C $CloneDir reset --hard HEAD --quiet
    foreach ($set in Get-SdCppPatchSets $PatchRoot) {
        $srcDir = Join-Path $set.FullName 'src'
        if (-not (Test-Path $srcDir)) { continue }
        foreach ($f in Get-ChildItem -Path $srcDir -File) {
            $target = Join-Path $CloneDir "src\$($f.Name)"
            if (Test-Path $target) { Remove-Item $target -Force }
        }
    }
}

function Test-PatchHasDiff {
    # A wiring.patch with no `diff --git` / `--- ` lines (e.g. comment-only
    # placeholder) is treated as "no tracked-file changes yet" and skipped,
    # so the harness builds vanilla upstream until a real patch lands.
    param([string]$PatchFile)
    if (-not (Test-Path $PatchFile)) { return $false }
    foreach ($line in Get-Content -Path $PatchFile) {
        if ($line -match '^(diff --git |--- )') { return $true }
    }
    return $false
}

function Invoke-SdCppPatches {
    # Copy new sources into <clone>\src\, then git-apply each wiring.patch.
    # A patch that fails to apply throws (loud + clear: upstream drifted and
    # the patch must be regenerated). Run AFTER the pull / submodule sync.
    param(
        [Parameter(Mandatory)][string]$CloneDir,
        [Parameter(Mandatory)][string]$PatchRoot
    )
    foreach ($set in Get-SdCppPatchSets $PatchRoot) {
        $name = $set.Name

        $baseFile = Join-Path $set.FullName 'base-commit.txt'
        if (Test-Path $baseFile) {
            $base = (Get-Content $baseFile -Raw).Trim()
            $head = (git -C $CloneDir rev-parse HEAD).Trim()
            if ($base -and $head -and $base -ne $head) {
                Write-Host ("  [patch:{0}] upstream HEAD {1} != patch base {2} - patch may need regeneration" -f `
                    $name, $head.Substring(0, 10), $base.Substring(0, 10)) -ForegroundColor Yellow
            }
        }

        $srcDir = Join-Path $set.FullName 'src'
        if (Test-Path $srcDir) {
            foreach ($f in Get-ChildItem -Path $srcDir -File) {
                Copy-Item $f.FullName (Join-Path $CloneDir "src\$($f.Name)") -Force
            }
        }

        $patch = Join-Path $set.FullName 'wiring.patch'
        if (Test-PatchHasDiff $patch) {
            Write-Host "  [patch:$name] applying wiring.patch" -ForegroundColor Cyan
            git -C $CloneDir apply --whitespace=nowarn $patch
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to apply '$patch' against current upstream. Regenerate it - see sdcpp-patches\$name\README.md"
            }
        } else {
            Write-Host "  [patch:$name] no wiring.patch yet (new sources copied only)" -ForegroundColor DarkGray
        }
    }
}
