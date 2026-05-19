"""Compare sd.cpp captures vs diffusers reference for step-5 validation.

    python hidream_i1_cmp.py ./val [stage ...]

For each stage compares ref_<stage>.bin (hidream_i1_ref.py) against
sdcpp_<stage>.bin (HiDreamI1::load_from_file_and_test). The shared dim-reversal
convention (binfmt.py) makes a flat compare valid with no transpose, provided
the same fixed inputs were fed to both sides.

Read front-to-back: the first stage that fails localises the bug to the block
between it and the previous good stage. bf16 tolerance: cos >= ~0.999,
max-abs <~ 1e-2.
"""

import sys
import os
import numpy as np
from binfmt import read_bin

STAGES = ["x_emb", "dbl0", "sgl31", "final"]


def stat(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    if a.shape != b.shape:
        return "SHAPE MISMATCH %s vs %s" % (a.shape, b.shape)
    den = np.linalg.norm(a) * np.linalg.norm(b)
    cos = float(a @ b / den) if den else float("nan")
    return "max=%.3e mean=%.3e cos=%.6f  %s" % (
        np.abs(a - b).max(), np.abs(a - b).mean(), cos,
        "OK" if cos >= 0.999 and np.abs(a - b).max() < 5e-2 else "*** DIVERGES ***")


def main():
    io = sys.argv[1] if len(sys.argv) > 1 else "./val"
    stages = sys.argv[2:] or STAGES
    for s in stages:
        rp, sp = os.path.join(io, "ref_%s.bin" % s), os.path.join(io, "sdcpp_%s.bin" % s)
        if not (os.path.exists(rp) and os.path.exists(sp)):
            print("%-7s SKIP (missing %s)" % (s, rp if not os.path.exists(rp) else sp))
            continue
        print("%-7s %s" % (s, stat(read_bin(rp), read_bin(sp))))


if __name__ == "__main__":
    main()
