"""Task #12 — validate sd.cpp's HiDream-I1 token->spatial unpatchify.

Step-5's "final" tap proved sd.cpp's pre-unpatchify tokens match diffusers
(cos 0.99995). The full sampler then runs unpatchify, which Step-5 never
checked. diffusers' unpatchify (transformer_hidream_image.py:699-704,
inference branch) is a pure deterministic reshape:

    t = x[i,:pH*pW].reshape(1,pH,pW, p1,p2,C)   # C innermost/fastest
    t = t.permute(0,5,1,3,2,4)                   # -> [1,C,pH,p1,pW,p2]
    t = t.reshape(1,C, pH*p1, pW*p2)

Apply that to sd.cpp's OWN pre-unpatchify dump and to the diffusers gold,
then compare both against sd.cpp's post-unpatchify dump. If they disagree,
sd.cpp's reorder + DiT::unpatchify_and_crop is the residual pure-noise bug.
"""
import sys, numpy as np
sys.path.insert(0, __file__.rsplit("\\", 1)[0])
from binfmt import read_bin

V = __file__.rsplit("\\", 1)[0] + "\\val\\"
P = 2

def diff_unpatchify(tok):
    # tok: [..., S, F] -> take last two axes as (S, F); squeeze any batch
    a = np.asarray(tok, np.float64)
    a = a.reshape(-1, a.shape[-1]) if a.ndim > 2 else a   # [S, F]
    S, F = a.shape
    pH = pW = int(round(S ** 0.5))
    assert pH * pW == S, f"S={S} not square"
    C = F // (P * P)
    t = a.reshape(pH, pW, P, P, C)          # C fastest (innermost)
    t = np.transpose(t, (4, 0, 2, 1, 3))    # -> [C, pH, p1, pW, p2]
    t = t.reshape(C, pH * P, pW * P)        # [C, H, W]
    return t

def stats(name, x):
    print(f"  {name:22s} shape={x.shape} min={x.min():.4f} "
          f"max={x.max():.4f} mean={x.mean():.4f} std={x.std():.4f}")

def cos(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))

sf = read_bin(V + "sdcpp_final.bin")
rf = read_bin(V + "ref_final.bin")
si = read_bin(V + "sdcpp_image.bin")
print("RAW shapes:")
stats("sdcpp_final", sf); stats("ref_final", rf); stats("sdcpp_image", si)
print(f"  cos(sdcpp_final, ref_final) = {cos(sf, rf):.6f}   (Step-5 oracle)")

exp_sd  = diff_unpatchify(sf)
exp_ref = diff_unpatchify(rf)
sic = si.reshape(exp_sd.shape)
print("\nDiffusers-exact unpatchify applied:")
stats("unpatch(sdcpp_final)", exp_sd)
stats("unpatch(ref_final)",   exp_ref)
stats("sdcpp_image (actual)", sic)
print(f"\n  cos( unpatch(sdcpp_final) , sdcpp_image ) = {cos(exp_sd,  sic):.6f}")
print(f"  cos( unpatch(ref_final)   , sdcpp_image ) = {cos(exp_ref, sic):.6f}")
print(f"  max|unpatch(sdcpp_final) - sdcpp_image|   = "
      f"{np.abs(exp_sd - sic).max():.6f}")
print("\nVERDICT: cos~1.0 => sd.cpp unpatchify == diffusers (NOT the bug).")
print("         cos<<1   => sd.cpp unpatchify DIVERGES => the pure-noise bug.")
