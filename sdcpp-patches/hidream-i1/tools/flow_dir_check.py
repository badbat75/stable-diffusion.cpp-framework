"""Task #12 — is the validated step-0 velocity actually denoising?

x0  = val/x.bin           (diffusers transformer input @ sigma~1, t=0.999)
v0  = sdcpp_image.bin     (sd.cpp post-unpatchify output; cos 0.99995 vs
                           diffusers => the faithful predicted velocity)

diffusers FlowMatchEuler 1-step: x_clean = x0 + (sigma1 - sigma0)*v0
with sigma0=1, sigma1=0  ->  x_clean = x0 - v0.

A clean VAE latent has strong nearest-neighbour spatial autocorrelation;
pure noise has ~0. If corr(x0 - v0) >> corr(x0) the flow direction is
right and the bug is downstream (sd.cpp multi-step loop / VAE). Also try
x0 + v0 (sign flip) as a control.
"""
import sys, numpy as np
sys.path.insert(0, __file__.rsplit("\\", 1)[0])
from binfmt import read_bin

V = __file__.rsplit("\\", 1)[0] + "\\val\\"
x0 = read_bin(V + "x.bin").reshape(16, 128, 128).astype(np.float64)
v0 = read_bin(V + "sdcpp_image.bin").reshape(16, 128, 128).astype(np.float64)

def spatial_corr(a):
    # mean over channels of lag-1 Pearson corr (right + down neighbours)
    cs = []
    for c in range(a.shape[0]):
        m = a[c]
        for p, q in (((m[:, :-1]).ravel(), (m[:, 1:]).ravel()),
                     ((m[:-1, :]).ravel(), (m[1:, :]).ravel())):
            cs.append(np.corrcoef(p, q)[0, 1])
    return float(np.mean(cs))

def st(n, a):
    print(f"  {n:14s} std={a.std():7.4f}  spatial_corr={spatial_corr(a):+.4f}")

print("step-0 flow-direction probe (1024px / 128-latent, gold cond):")
st("x0 (noise)", x0)
st("v0 (vel)",   v0)
st("x0 - v0",    x0 - v0)
st("x0 + v0",    x0 + v0)
r0, rm, rp = spatial_corr(x0), spatial_corr(x0 - v0), spatial_corr(x0 + v0)
print(f"\n  corr gain  (x0-v0): {rm - r0:+.4f}   (x0+v0): {rp - r0:+.4f}")
print("  >>0 for x0-v0  => velocity denoises, flow dir correct,"
      " bug is downstream (sd.cpp loop/VAE).")
print("  ~0 / negative  => velocity scale or sign is wrong"
      " (transformer faithful in cos but not usable).")
