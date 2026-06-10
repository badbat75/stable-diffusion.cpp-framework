# Apply library for sdcpp-patches\ — local, version-controlled modifications
# layered onto the (gitignored, auto-pulled) stable-diffusion.cpp clone.
#
# Each subfolder of sdcpp-patches\ is one patch set:
#   <name>\src\*           - NEW header-only sources, COPIED into <clone>\src\
#   <name>\wiring.patch    - unified diff against tracked upstream files (root)
#   <name>\ggml.patch      - unified diff against files INSIDE the ggml submodule
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
#
# Submodule patches: ggml.patch is applied with `git -C <clone>/ggml apply`,
# and Reset-SdCppClone resets the ggml submodule alongside the parent so a
# subsequent submodule sync sees a clean tree. Each ggml.patch supports
# "already applied upstream" detection — if `git apply --reverse --check`
# succeeds, the patch is treated as merged-in and silently skipped, which is
# what lets a stale ggml-targeted patch survive the day sd.cpp bumps its ggml
# gitlink past the upstream fix.

function Get-SdCppPatchSets {
    # Each subdirectory of sdcpp-patches\ is a patch set, EXCEPT one that
    # carries a `.disabled` marker file — those are skipped entirely (neither
    # reset nor applied), so a patch set can be parked in the repo (kept under
    # version control for future reference / re-enablement) without affecting
    # the build. Drop the `.disabled` file to re-activate it.
    param([Parameter(Mandatory)][string]$PatchRoot)
    if (-not (Test-Path $PatchRoot)) { return @() }
    Get-ChildItem -Path $PatchRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-Path (Join-Path $_.FullName '.disabled')) } |
        Sort-Object Name
}

function Reset-SdCppClone {
    # Revert every patch-set modification so `git pull --ff-only` sees a clean
    # tree. Tracked-file edits in the parent are undone with `reset --hard
    # HEAD` (HEAD does NOT move, so the rebuild-detection report stays
    # accurate); the untracked headers we copied in are deleted by name. The
    # ggml submodule is also reset (`git -C ggml reset --hard HEAD`) so the
    # next `git submodule update --init --recursive` doesn't trip over a dirty
    # tree from a previous run's ggml.patch.
    param(
        [Parameter(Mandatory)][string]$CloneDir,
        [Parameter(Mandatory)][string]$PatchRoot
    )
    if (-not (Test-Path "$CloneDir\.git")) { return }
    git -C $CloneDir reset --hard HEAD --quiet
    if (Test-Path "$CloneDir\ggml\.git") {
        git -C "$CloneDir\ggml" reset --hard HEAD --quiet
    }
    # Enumerate ALL patch-set directories here, ignoring `.disabled`: the
    # marker only gates APPLYING. Headers copied in before a set was parked
    # are untracked, so `reset --hard` never removes them — and if upstream
    # later adds a tracked file with the same name, the pull would fail with
    # "untracked working tree file would be overwritten".
    foreach ($set in (Get-ChildItem -Path $PatchRoot -Directory -ErrorAction SilentlyContinue)) {
        $srcDir = Join-Path $set.FullName 'src'
        if (-not (Test-Path $srcDir)) { continue }
        foreach ($f in Get-ChildItem -Path $srcDir -File) {
            $target = Join-Path $CloneDir "src\$($f.Name)"
            if (Test-Path $target) { Remove-Item $target -Force }
        }
    }
}

function Test-PatchHasDiff {
    # A wiring.patch / ggml.patch with no `diff --git` / `--- ` lines (e.g.
    # comment-only placeholder) is treated as "no tracked-file changes yet"
    # and skipped, so the harness builds vanilla upstream until a real patch
    # lands.
    param([string]$PatchFile)
    if (-not (Test-Path $PatchFile)) { return $false }
    foreach ($line in Get-Content -Path $PatchFile) {
        if ($line -match '^(diff --git |--- )') { return $true }
    }
    return $false
}

function Invoke-PatchInRepo {
    # Apply $PatchFile inside $RepoDir using `git -C $RepoDir apply`. If the
    # forward apply fails, try `apply --reverse --check`: a clean reverse
    # means the patch's effect is already present in the tree (upstream
    # merged the same fix, or a prior partial run left it applied) — in
    # which case we log "already applied" and return without throwing. Any
    # other failure surfaces as a hard error with a regenerate hint.
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$PatchFile,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$PatchSetName
    )
    git -C $RepoDir apply --check --whitespace=nowarn $PatchFile 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [patch:$PatchSetName] applying $Label" -ForegroundColor Cyan
        git -C $RepoDir apply --whitespace=nowarn $PatchFile
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to apply '$PatchFile' against current upstream. Regenerate it - see sdcpp-patches\$PatchSetName\README.md"
        }
        return
    }

    git -C $RepoDir apply --reverse --check --whitespace=nowarn $PatchFile 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [patch:$PatchSetName] $Label already applied upstream - skipping" -ForegroundColor DarkGray
        return
    }

    throw "Failed to apply '$PatchFile' against current upstream (neither forward nor reverse). Regenerate it - see sdcpp-patches\$PatchSetName\README.md"
}

function Invoke-SdCppPatches {
    # Copy new sources into <clone>\src\, then git-apply each wiring.patch
    # (root) and ggml.patch (submodule). A patch that fails to apply throws
    # (loud + clear: upstream drifted and the patch must be regenerated),
    # UNLESS the reverse-check succeeds — in which case the patch is treated
    # as already merged upstream and silently skipped. Run AFTER the pull /
    # submodule sync.
    param(
        [Parameter(Mandatory)][string]$CloneDir,
        [Parameter(Mandatory)][string]$PatchRoot
    )
    foreach ($set in Get-SdCppPatchSets $PatchRoot) {
        $name = $set.Name

        $wiringFile = Join-Path $set.FullName 'wiring.patch'
        $ggmlFile   = Join-Path $set.FullName 'ggml.patch'

        $baseFile = Join-Path $set.FullName 'base-commit.txt'
        if (Test-Path $baseFile) {
            $base = (Get-Content $baseFile -Raw).Trim()
            # A set that only patches the ggml submodule records a ggml SHA in
            # base-commit.txt — compare it against the SUBMODULE's HEAD, not
            # the sd.cpp clone's, or the warning below fires on every build
            # for a perfectly current patch.
            $ggmlOnly = (Test-PatchHasDiff $ggmlFile) -and -not (Test-PatchHasDiff $wiringFile)
            $headRepo = if ($ggmlOnly) { Join-Path $CloneDir 'ggml' } else { $CloneDir }
            $head = (git -C $headRepo rev-parse HEAD).Trim()
            if ($base -and $head -and $base -ne $head) {
                Write-Host ("  [patch:{0}] {1} HEAD {2} != patch base {3} - patch may need regeneration" -f `
                    $name, $(if ($ggmlOnly) { 'ggml' } else { 'upstream' }), $head.Substring(0, 10), $base.Substring(0, 10)) -ForegroundColor Yellow
            }
        }

        $srcDir = Join-Path $set.FullName 'src'
        if (Test-Path $srcDir) {
            foreach ($f in Get-ChildItem -Path $srcDir -File) {
                Copy-Item $f.FullName (Join-Path $CloneDir "src\$($f.Name)") -Force
            }
        }

        if (Test-PatchHasDiff $wiringFile) {
            Invoke-PatchInRepo -RepoDir $CloneDir -PatchFile $wiringFile -Label 'wiring.patch' -PatchSetName $name
        }

        if (Test-PatchHasDiff $ggmlFile) {
            $ggmlRepo = Join-Path $CloneDir 'ggml'
            if (-not (Test-Path "$ggmlRepo\.git")) {
                throw "Patch set '$name' has ggml.patch but $ggmlRepo is not a git repo (was the submodule init'd?)"
            }
            Invoke-PatchInRepo -RepoDir $ggmlRepo -PatchFile $ggmlFile -Label 'ggml.patch' -PatchSetName $name
        }

        if (-not (Test-PatchHasDiff $wiringFile) -and -not (Test-PatchHasDiff $ggmlFile) -and -not (Test-Path $srcDir)) {
            Write-Host "  [patch:$name] no diff/sources yet (placeholder)" -ForegroundColor DarkGray
        }
    }
}
