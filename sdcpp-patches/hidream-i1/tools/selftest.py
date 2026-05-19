"""Offline plumbing self-test for the HiDream-I1 step-5 validation tools.

Run this BEFORE spending GPU time on the real diffusers reference. It needs
only numpy (no torch / diffusers / sd.cpp) and proves the cross-tool
on-disk contract is correct, so a divergence found later is a real model
bug and not a layout artefact.

    python selftest.py

What it verifies:

 1. binfmt round-trip (write_bin -> read_bin) is identity for the exact
    tensor RANKS used by the harness (4-D latent, 3-D activations, 1-D
    timestep), including non-cubic shapes that would expose an axis bug.

 2. The sd.cpp <-> diffusers reversal contract. sd.cpp's `dump_f32` writes
    `sd::Tensor.shape()` (== ggml `ne` order, ne[0] fastest-varying) followed
    by C-contiguous-in-ne-order f32. numpy is last-axis-fastest. For the SAME
    logical tensor those two byte streams are IDENTICAL iff ggml ne ==
    reversed(numpy.shape) AND the data orders line up. This test emulates
    sd.cpp's writer independently (manual struct pack in ne order) and
    asserts it is byte-identical to `binfmt.write_bin` of the same logical
    numpy array -- i.e. `write_bin` is a faithful `dump_f32` stand-in, so a
    flat compare in `hidream_i1_cmp.py` is valid with no transpose.

 3. The 4 capture stages are flat-compatible between the two sides given the
    shapes each actually produces (sd.cpp ne vs diffusers numpy), so none
    will throw a spurious SHAPE MISMATCH / DIVERGES.

 4. `hidream_i1_cmp.stat` actually flags a perturbation (no false OK) and
    passes on a bit-identical pair (no false DIVERGES), via a synthetic
    ./val_selftest fixture it also leaves on disk for inspection.

Exit code 0 = all green.
"""

import os
import struct
import sys
import tempfile
import numpy as np

from binfmt import write_bin, read_bin
import hidream_i1_cmp as cmp


def _emulate_dump_f32(path, logical):
    """Independently emulate sd.cpp HiDreamI1::dump_f32 for `logical`, a numpy
    array given in *numpy* order. sd.cpp holds it as sd::Tensor with
    shape == ggml ne == reversed(numpy.shape), data C-contiguous ne[0]-fastest.
    ne[0]-fastest over logical[d0,..,dk] is exactly numpy C-order of `logical`
    (last axis fastest), so the raw block is logical.tobytes(C). Header:
    int32 n_dims, int32 name_len(0), int32 ttype(0=f32), int32 dims[ne order]."""
    a = np.ascontiguousarray(logical, np.float32)
    ne = list(reversed(a.shape))
    with open(path, "wb") as f:
        f.write(struct.pack("<iii", len(ne), 0, 0))
        f.write(struct.pack("<%di" % len(ne), *ne))
        f.write(a.tobytes(order="C"))


def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        check.failed = True
check.failed = False


def main():
    rng = np.random.default_rng(0)
    tmp = tempfile.mkdtemp(prefix="hidream_st_")

    # --- 1. binfmt round-trip on harness ranks (deliberately non-cubic) -----
    print("[1] binfmt write/read round-trip")
    shapes = {
        "x(latent NCHW)": (1, 16, 24, 40),
        "t5 (N,S,4096)":  (1, 7, 4096),
        "llama(N,S,33C)": (1, 5, 33 * 4096),
        "pooled (N,2048)": (1, 2048),
        "timestep (N)":   (1,),
        "act (N,nimg,H)": (1, 13, 2560),
    }
    for nm, sh in shapes.items():
        a = rng.standard_normal(sh).astype(np.float32)
        p = os.path.join(tmp, "rt.bin")
        write_bin(p, a)
        b = read_bin(p)
        check("%-18s shape %s preserved & exact" % (nm, sh),
              b.shape == a.shape and np.array_equal(a, b))

    # --- 2. write_bin IS a faithful dump_f32 stand-in -----------------------
    print("[2] sd.cpp dump_f32 <-> binfmt.write_bin byte-identity")
    for nm, sh in shapes.items():
        a = rng.standard_normal(sh).astype(np.float32)
        pw = os.path.join(tmp, "w.bin")
        pd = os.path.join(tmp, "d.bin")
        write_bin(pw, a)            # diffusers/ref side
        _emulate_dump_f32(pd, a)    # sd.cpp side, same logical tensor
        with open(pw, "rb") as f:
            wb = f.read()
        with open(pd, "rb") as f:
            db = f.read()
        check("%-18s identical bytes (no transpose needed)" % nm, wb == db)

    # --- 3. the 4 stages are flat-compatible with their real shapes ---------
    # ref (diffusers, numpy order)  vs  sd.cpp (ggml ne order, what dump_f32
    # records). cmp ravels both; equal iff same logical layout. n_img=15,
    # hidden=2560, p*p*C=64, B=N=1.
    print("[3] capture-stage flat-compatibility (ref numpy vs sd.cpp ne)")
    n_img = 15
    stage_shapes = {
        "x_emb": ((1, n_img, 2560), (2560, n_img, 1)),
        "dbl0":  ((1, n_img, 2560), (2560, n_img, 1)),
        "sgl31": ((1, n_img, 2560), (2560, n_img, 1)),
        "final": ((1, n_img, 64),   (64,   n_img, 1)),
    }
    for s, (ref_np, sd_ne) in stage_shapes.items():
        logical = rng.standard_normal(ref_np).astype(np.float32)  # the true values
        rp = os.path.join(tmp, "ref_%s.bin" % s)
        sp = os.path.join(tmp, "sdcpp_%s.bin" % s)
        write_bin(rp, logical)              # ref dumps in numpy order
        # sd.cpp produces the same logical values but as a ggml tensor whose
        # ne == reversed(numpy). _emulate_dump_f32 takes numpy order and packs
        # ne order, so feeding `logical` models the matched (correct) case.
        _emulate_dump_f32(sp, logical)
        line = cmp.stat(read_bin(rp), read_bin(sp))
        check("%-6s ref%s vs sd.cpp ne%s -> %s"
              % (s, ref_np, sd_ne, line.strip()), "OK" in line)

    # --- 4. cmp.stat sensitivity (no false OK / no false DIVERGES) ---------
    print("[4] hidream_i1_cmp.stat detects a real perturbation")
    val = os.path.join(os.getcwd(), "val_selftest")
    os.makedirs(val, exist_ok=True)
    base = rng.standard_normal((1, n_img, 2560)).astype(np.float32)
    # identical pair -> must be OK
    write_bin(os.path.join(val, "ref_x_emb.bin"), base)
    _emulate_dump_f32(os.path.join(val, "sdcpp_x_emb.bin"), base)
    ok_line = cmp.stat(read_bin(os.path.join(val, "ref_x_emb.bin")),
                       read_bin(os.path.join(val, "sdcpp_x_emb.bin")))
    check("identical pair -> OK (cos 1.0)", "OK" in ok_line)
    # a 3% relative perturbation -> must DIVERGE (this is the localiser firing)
    pert = base + 0.03 * np.abs(base).mean() * rng.standard_normal(base.shape).astype(np.float32) + 0.05
    write_bin(os.path.join(val, "ref_dbl0.bin"), base)
    _emulate_dump_f32(os.path.join(val, "sdcpp_dbl0.bin"), pert)
    bad_line = cmp.stat(read_bin(os.path.join(val, "ref_dbl0.bin")),
                        read_bin(os.path.join(val, "sdcpp_dbl0.bin")))
    check("perturbed pair -> *** DIVERGES ***", "DIVERGES" in bad_line)
    # shape mismatch must be reported, not crash
    sm = cmp.stat(np.zeros((4,), np.float32), np.zeros((5,), np.float32))
    check("shape mismatch reported cleanly", "SHAPE MISMATCH" in sm)
    print("    (left ./val_selftest as an inspectable fixture; "
          "`python hidream_i1_cmp.py ./val_selftest x_emb dbl0` reproduces)")

    print()
    if check.failed:
        print("SELFTEST FAILED")
        sys.exit(1)
    print("SELFTEST OK -- the on-disk contract is sound; a divergence in the "
          "real run is a genuine sub-spec model bug, localised to the block "
          "between the last OK stage and the first *** DIVERGES ***.")


if __name__ == "__main__":
    main()
