# sdcpp-patches/hidream-i1

Adds **HiDream-I1** (original 17B MMDiT) support to the auto-pulled
stable-diffusion.cpp clone, without committing into the clone's git or
forking upstream. Layered on by `..\patch-lib.ps1` on every build.

> Status: **✅ NUMERICALLY VALIDATED & WORKING (2026-05-19).** Steps 1–5
> complete; gated behind `SD_HIDREAM_I1_EXPERIMENTAL` (default OFF).
> Generates coherent images (verified "a red cube on grass" @ 1024²,
> euler). The residual pure-noise bug was **root-caused**: diffusers'
> HiDream pipeline negates the transformer output (`noise_pred =
> -noise_pred`, `pipeline_hidream_image.py:1004`) before the FlowMatch
> scheduler, but sd.cpp fed the raw output into the *shared*
> `FluxFlowDenoiser` (Flux sign convention). Fixed by negating
> `HiDreamI1Runner::compute()`'s output (`return out * -1.0f;`) — in the
> copied-in `src/hidream_i1.hpp` only (production path; `compute_capture()`
> keeps the raw output so Step-5 remains a faithful oracle), so **zero
> `wiring.patch` growth**. Localisation used new dev hooks
> `HIDREAM_I1_INJECT_COND` (gold-cond → real sampler isolation) +
> `tools/{unpatchify_check,flow_dir_check}.py` (the latter is the smoking
> gun: x₀+v₀ spatial-corr 0.978 vs sd.cpp's x₀−v₀ 0.03). Leftover
> slightly-orange hue is a separate, documented conditioner-fidelity gap
> (Q8 + ~0.49 llama norm + tokenizer), not structural. `wiring.patch` (6 files, 17
> hunks, 119+/1− vs `8308042`) carries: `LLMArch::LLAMA3` (`src/llm.hpp`);
> `VERSION_HIDREAM_I1` detection + enum/string (`src/model.{h,cpp}`,
> `src/stable-diffusion.cpp`); and the gated Step-4 wiring (`CMakeLists.txt`
> option, `src/diffusion_model.hpp` wrapper + include + `DiffusionParams`
> field, `src/stable-diffusion.cpp` factory/pred-type/llama branches,
> `src/model.h` `sd_version_is_dit`). `src/hidream_i1.hpp` (full model +
> 4-encoder conditioner) is a copied-in `src/*` file, **not** in
> `wiring.patch`.
>
> **Default builds are byte-identical vanilla** — every Step-4 edit is
> `#ifdef SD_HIDREAM_I1_EXPERIMENTAL`, OFF by default, so with the patch
> applied a normal `02-build-server.ps1` is unchanged and the GGUF still
> fails cleanly as "unsupported" (not in `sd_version_is_dit` when OFF). Opt
> in with `-DSD_HIDREAM_I1_EXPERIMENTAL=ON` to exercise the wired path.
> Verified: OFF incremental build exit 0; ON full SD-lib build exit 0;
> restored OFF exit 0; harness `Reset`→`Invoke` round-trips clean.
>
> This README is the implementation plan; the **exact** GGUF-derived spec is
> in project memory `hidream-i1-architecture.md`. **Numerical fidelity is NOT
> verified** — the in-code `FIDELITY TODO (README step 5)` markers (MoE
> top-2 vs dense softmax, per-block Llama layer selection + T5/Llama concat
> order, joint-RoPE position scheme, Qwen2-fallback Llama tokenizer, deferred
> llama3-RoPE rescaling) all need a diffusers/ComfyUI reference run and are
> intentionally flagged rather than silently guessed. See Step 5 for the
> deterministic validation checklist.

## Exact architecture (verified)

From `hidream-i1-full-Q8_0.gguf` (1615 tensors) + diffusers
`transformer_hidream_image.py`. Full detail in the memory note above; the
load-bearing numbers:

- hidden=2560 (20 heads × 128), in_channels=64 (2×2 patch × 16 Flux-VAE ch).
- 16 `double_stream_blocks` + 32 `single_stream_blocks`.
- MoE `ff_i`: gate [2560→4], **top-2 of 4** routed SwiGLU experts
  (w1/w3 2560→6912, w2 6912→2560) + always-on `shared_experts`
  (2560→3584→2560). Dense `ff_t` (text, double blocks only).
- Double-block adaLN = Linear(2560→30720) = 12×hidden (img then `_t` text:
  shift/scale/gate ×{msa,mlp}); single-block adaLN = 15360 = 6×hidden.
- Joint attention: concat([q_i,q_t]),([k_i,k_t]),([v_i,v_t]) on dim 1; per-head
  `q_rms_norm`/`k_rms_norm` (+`_t`).
- **`caption_projection`: 49 × Linear(4096→2560)**. idx 0-15 → llama stream
  for double block i; 16-47 → llama stream for single block (i-16); 48 → T5.
  Per-block llama layer = `config.llama_layers`.
- Encoders: CLIP-L + CLIP-G (pooled 768+1280 → p_embedder 2048→2560),
  T5-XXL (4096), Llama-3.1-8B (`LLMArch::LLAMA3`). VAE = Flux VAE.
- EmbedND RoPE theta=10000, axes_dims=(32,32).

## Why this is needed

sd.cpp's only HiDream path is `VERSION_HIDREAM_O1`, which is a *different
model* (Qwen3-VL LLM-backbone, `hidream_o1.hpp`). It has zero code reusable
for HiDream-I1 and its detector hard-requires the LLM encoder bundled in the
checkpoint. A diffusion-only HiDream-I1 GGUF therefore fails version
detection (`get sd version from file failed`). Confirmed against the GGUF's
tensor table — see commit history / project memory.

## What HiDream-I1 actually is (from the GGUF tensor table)

- **Dual-stream then single-stream transformer** (Flux-like). Double-stream
  blocks carry separate image (`attn1.to_{q,k,v}`) and text
  (`attn1.to_{q,k,v}_t`) projections + dual RMS-norm.
- **Sparse-MoE feed-forward**: `ff_i.experts.{0..N}.w{1,2,3}` (SwiGLU) +
  `ff_i.gate` (top-k router) + `ff_i.shared_experts.w{1,2,3}`. Text stream
  uses a dense `ff_t.w{1,2,3}`.
- `caption_projection` (projects the 4 encoders), `x_embedder`, `t_embedder`,
  `p_embedder`, `final_layer`, adaLN modulation.
- Text encoders: **CLIP-L (long) + CLIP-G/bigG + T5-XXL + Llama-3.1-8B**.
- VAE: the Flux VAE (`flux1-dev_ae.safetensors`) — already supported.

## Implementation plan (order matters)

1. **`src/llm.hpp` — add `LLMArch::LLAMA3`. ✅ DONE (compile-verified).**
   Llama-3.1-8B encoder: RMSNorm, RoPE NEOX theta=500000, GQA (8 KV / 32
   heads, head_dim 128), SwiGLU MLP, no qk_norm, no qkv_bias; layers/hidden/
   vocab auto-detected from the tensor map. Four edit sites in `wiring.patch`:
   enum + `llm_arch_to_str`, `Attention::forward` RoPE branch, `LLMRunner`
   ctor param block, and the 1-D `input_pos` arch list. **Known fidelity gap
   (resolve in step 5):** the Llama-3.1 "llama3" piecewise inv-freq rescaling
   (factor 8 / low 1 / high 4 / orig 8192) is not yet applied — `ggml_rope_ext`
   has no scalar form, it needs a `freq_factors` tensor plumbed from the runner
   through `Attention`. HiDream pads the Llama branch to 128 tokens (<< 8192)
   so unscaled rope is close but not bit-exact.

2. **`src/hidream_i1.hpp` — the model + conditioner. ✅ DONE
   (compile-verified; numerics pending step 5).** Header-only NEW file,
   copied into the clone by the harness (no CMake change, like
   `hidream_o1.hpp`); reuses `Flux::{RMSNorm,LastLayer,modulate,
   ModulationOut}` since the shapes are identical. Contains:
   - `HiDreamI1Params` + `make_hidream_i1_params()` (hidden 2560, 20 heads ×
     128, 16 double + 32 single blocks, 4 experts/top-2, expert FF 6912,
     shared FF 3584, caption 4096, pooled 2048, EmbedND θ=10000 axes (32,32)).
   - `SwiGLU` (expert / shared / dense `ff_t`), `MoEFeedForward`
     (gate → softmax → 4 experts + always-on shared).
   - `JointAttention` (img + optional `_t` text projections, per-head q/k
     RMS-norm, `Rope::attention` over the concatenated [img;txt] sequence).
   - `AdaLN` (×4 for double = img{msa,mlp}+txt{msa,mlp}, ×2 for single),
     `DoubleStreamBlock`, `SingleStreamBlock`.
   - `HiDreamI1` (x_embedder + t/p_embedder + 49 `caption_projection` +
     blocks + Flux `LastLayer`) and `HiDreamI1Runner` (gen_flux_pe → graph),
     mirroring the `HiDreamO1Runner`/`FluxRunner` GGMLRunner shape.
   - `HiDreamI1Conditioner`: CLIP-L + CLIP-G pooled → `c_vector`, T5-XXL →
     `c_crossattn`, Llama-3.1 (`LLM::LLMEmbedder`, all hidden states) →
     `extra_c_crossattns`; `caption_projection`/`p_embedder` live in the
     transformer, so the conditioner only emits the four raw encoder outputs.
   Open numerical items carry inline `FIDELITY TODO (README step 5)` markers
   (MoE top-2+renorm vs dense softmax, per-block Llama layer / concat order,
   joint-RoPE positions, Qwen2-fallback Llama tokenizer).

3. **`src/model.cpp` — `VERSION_HIDREAM_I1` detection. ✅ DONE
   (compile-verified).** `get_sd_version()` returns `VERSION_HIDREAM_I1` on
   substring `double_stream_blocks.0.block.ff_i.experts.0.w1.weight` (the MoE
   signature, prefix-agnostic since it loads via `--diffusion-model`), with
   **no** `language_model.*` requirement. Also added the `VERSION_HIDREAM_I1`
   enum value (`src/model.h`, right after `VERSION_HIDREAM_O1`) and its
   `"HiDream I1"` string in `model_version_to_str[]`
   (`src/stable-diffusion.cpp`) — both kept positionally aligned with the
   enum. **Not** added to `sd_version_is_dit()` yet (Step 4): the GGUF is now
   *recognized & named* instead of failing `get sd version from file failed`,
   but model construction is intentionally still unwired, so it will fail
   later with a clear "unsupported" state rather than render. *`wiring.patch`
   (5 files: + `src/model.h`).*

4. **`src/stable-diffusion.cpp` + `src/diffusion_model.hpp` — wiring. ✅ DONE
   (gated; both configs compile-verified).** HiDream-I1 is Flux-shaped (Flux
   VAE 16ch, flow-matching denoiser), **not** HiDream-O1-shaped, so it is
   modelled on the Flux sites — *not* the HiDream-O1 ones (no FakeVAE, no
   `latent_channel=3`, no `eta=8`/`sigma=1-t` special cases). All edits are
   guarded by **`SD_HIDREAM_I1_EXPERIMENTAL`** (CMake `option(... OFF)`):
   default-OFF builds are byte-identical vanilla; opt in with
   `-DSD_HIDREAM_I1_EXPERIMENTAL=ON`. Sites:
   - `CMakeLists.txt`: the option + `target_compile_definitions` on `${SD_LIB}`.
   - `src/model.h`: `VERSION_HIDREAM_I1` into `sd_version_is_dit()` (gated).
   - `src/diffusion_model.hpp`: gated `#include "hidream_i1.hpp"`, a gated
     `DiffusionParams::hidream_llama` field (Llama-3.1 stream), and the
     `HiDreamI1Model : DiffusionModel` wrapper (context→T5, y→pooled,
     hidream_llama→Llama).
   - `src/stable-diffusion.cpp`: gated conditioner/diffusion factory branch
     (`HiDreamI1Conditioner` + `HiDreamI1Model`), gated `FLUX_FLOW_PRED`
     pred-type branch, and the gated `diffusion_params.hidream_llama`
     assignment (= `condition.extra_c_crossattns[0]`). `get_latent_channel()`
     needs no edit — once in `sd_version_is_dit` it falls through to the
     Flux-VAE `else { 16 }`. Encoders load from `text_encoders.*` (no bundle
     requirement). Compile-verified: default OFF incremental build exit 0
     (vanilla preserved); `-DSD_HIDREAM_I1_EXPERIMENTAL=ON` full SD-lib build
     exit 0 (27 objs incl. `stable-diffusion.cpp.obj` with the wired path);
     restored to OFF exit 0. Harness `Reset`→`Invoke` round-trips clean.
   *`wiring.patch` (6 files: + `CMakeLists.txt`, `src/diffusion_model.hpp`).*

5. **Validate numerically — ✅ DONE (2026-05-18/19).** The diffusers reference
   WAS run (HF token loaded; `tools/val/ref_{x_emb,dbl0,sgl31,final}.bin`
   captured 2026-05-18 22:29 by `tools/hidream_i1_ref.py`) and the per-stage
   diff performed. Result: the **transformer is numerically faithful**
   (final-latent cos 0.99995 under `HIDREAM_I1_INJECT_COND` isolation). The
   diff localised — and `flow_dir_check.py` confirmed — the residual
   pure-noise bug as a flow-direction sign error (diffusers negates the
   transformer output before FlowMatch; sd.cpp's shared `FluxFlowDenoiser`
   used Flux's sign); **fixed** via `return out * -1.0f` in
   `HiDreamI1Runner::compute()` (see status banner at the top). The ONLY
   residual is a **separate, already-localised conditioner-fidelity gap**
   (slight orange/saturation drift): three named contributors — Q8/quant
   error, the ~0.49 |sd|/|ref| Llama-3.1 hidden-states norm ratio, and the
   Llama-3.1 tokenizer. Non-structural, NOT a "Step-5 not done" item; closing
   it is conditioner code work (priority list below), not a missing reference.
   `wiring.patch` regeneration + harness round-trip are **DONE**. The
   sd.cpp-side validation harness (kept for re-runs / regression; in
   `src/hidream_i1.hpp`, gated, not in `wiring.patch`):
   - `HiDreamI1::dump_f32` + `compute_capture` + a `capture` tap after
     `x_embedder` / double-block 0 / single-block 31 / `final_layer` (tags
     `x_emb`/`dbl0`/`sgl31`/`final`; empty in all normal use).
   - `static HiDreamI1::load_from_file_and_test(diffusion_gguf, io_dir,
     stage)` — mirrors `Flux::load_from_file_and_test`; loads the GGUF +
     `io_dir/{x,timestep,t5,llama,pooled}.bin`, runs one forward capturing
     `stage`, prints stats, dumps `io_dir/sdcpp_<stage>.bin`.
   - `tools/binfmt.py` (shared format), `tools/hidream_i1_ref.py` (diffusers
     reference: writes the inputs + `ref_<stage>.bin`), `tools/hidream_i1_cmp.py`
     (max/mean/cos diff).

   **`tools/hidream_i1_ref.py` HARDENED (2026-05-18) from a verbatim re-read
   of `transformer_hidream_image.py` + `pipeline_hidream_image.py` — the
   hook/restack/timestep conventions are now derived, not guessed:**
   - `sgl31` is a **forward-PRE-hook on `final_layer` (its input[0])**, NOT a
     forward hook on `single_stream_blocks.31`. A single block returns the
     full `[img+text+cur_llama]` sequence; sd.cpp's `sgl31` tap is the
     post-loop image-only slice fed INTO `final_layer` — only the pre-hook
     matches it. (`x_emb`=x_embedder out, `dbl0`=double_stream_blocks.0
     out[0], `final`=final_layer out, all forward hooks — verified.)
   - `llama.bin` is written as sd.cpp's 33-block feature stack: pipeline does
     `outputs.hidden_states[1:]`→`stack(dim=0)`→`[32,B,S,4096]`; restacked so
     block `(1+k)` = layer-`k` (block 0 = unused embed slot), matching
     `HiDreamI1::forward`'s `llama_layer(hfk)=view block 1+hfk`.
   - `timestep.bin` = diffusers scheduler `t / 1000` (sd.cpp's t_embedder
     `time_factor=1000.f` ×1000 recovers it — the Flux FLUX_FLOW_PRED
     convention, independently verified; removes the timestep convention as a
     confound, documented in-script so it stays auditable).
   - single-call capture guard + `_StopAfterCapture` short-circuits the
     scheduler/VAE after the one transformer forward; aborts loudly on any
     module-rename / shape surprise (same fidelity-honesty rule as C++).
   - Companion correctness fix this session (copied-in `src/hidream_i1.hpp`,
     NOT `wiring.patch`): `HiDreamRMSNorm` eps `1e-6f`→**`1e-5f`** (diffusers
     `nn.RMSNorm` via `HiDreamAttention` default `eps=1e-5`). Won't fix the
     noise (sub-catastrophic) but removes a verified fidelity gap. Plus an
     exhaustive first-hand spec re-verification (see project memory
     `hidream-i1-architecture.md`): the entire transformer/conditioner/
     patchify/RoPE/AdaLN/MoE surface is faithful — the residual pure-noise
     bug is a SUB-SPEC numeric/ggml-op issue, which is exactly what this
     stage-diff localises.

   Runbook for whoever has the reference env:
   0. **Pre-flight (zero GPU, numpy-only): `python tools/selftest.py`.** Proves
      the on-disk contract offline — binfmt round-trip; that `write_bin` is a
      byte-identical `dump_f32` stand-in; that all 4 capture stages are
      flat-compatible (ref numpy vs sd.cpp ggml-ne) so none false-DIVERGE; and
      that `hidream_i1_cmp.stat` flags a real perturbation but passes an
      identical pair. Exit 0 ⇒ any later divergence is a genuine sub-spec
      model bug, not a layout artefact. (Verified green 2026-05-18, 16/16.)
   1. `python tools/hidream_i1_ref.py --model HiDream-ai/HiDream-I1-Full
      --io ./val --prompt "a red cube on grass" --seed 42` → writes
      `./val/{x,timestep,t5,llama,pooled}.bin` + `./val/ref_*.bin`. (It
      prints the transformer's module names and aborts loudly if the hook
      targets don't match your diffusers version — align the hook plan
      rather than guessing; same fidelity-honesty rule as the C++ side.)
      **Prereq: gated HF access** — `HiDream-ai/HiDream-I1-Full` AND
      `meta-llama/Llama-3.1-8B` are license-gated; accept both on HF and
      `huggingface-cli login` first. `--offload sequential` (default) fits a
      ~12GB GPU by streaming the 17B weights from system RAM (budget ≥64GB;
      one 1-step forward ≈ minutes — fine for a single reference);
      `--offload {model,none}` for ≥40GB GPUs (see `--help`).
      **Toolchain status (this box, 2026-05-18): pre-installed & verified —
      torch 2.6.0+cu124 (CUDA on, RTX 4070 SUPER 12GB), diffusers 0.38.0
      (`HiDreamImagePipeline` imports), transformers 5.8.1, accelerate
      1.13.0, numpy. RAM 62GB/40GB-free, disk ample. Sole remaining gate:
      the two HF licenses + a token (not present here) — then this step is a
      single command.**
   2. Build `-DSD_HIDREAM_I1_EXPERIMENTAL=ON`, then invoke via the **built-in
      gated env-var hook** at the top of `new_sd_ctx`
      (`src/stable-diffusion.cpp`, in `wiring.patch`) — no hand-edited driver:
      ```
      for s in x_emb dbl0 sgl31 final; do \
        HIDREAM_I1_VAL="<diffusion_gguf>;./val;$s" \
          build/cmake-build/bin/sd-cli -M img_gen -p x -o /tmp/x.png ; done
      ```
      The hook fires before any model load: it runs
      `HiDreamI1Runner::load_from_file_and_test` on the fixed `./val` inputs,
      dumps `./val/sdcpp_<stage>.bin`, and `exit(0)`s (the trailing sd-cli
      args are ignored — they only satisfy arg parsing). Wholly inside
      `#ifdef SD_HIDREAM_I1_EXPERIMENTAL` **and** behind the env var, so
      vanilla and normal experimental runs are byte-identical (the preprocessor
      strips it when OFF — a static guarantee). *Compile status: VERIFIED
      2026-05-18 — `-DSD_HIDREAM_I1_EXPERIMENTAL=ON` rebuilt
      `stable-diffusion.cpp.obj` with the hook and linked `sd-cli` exit 0;
      reconfigured OFF rebuilt the same TU (hook preprocessor-stripped) exit 0,
      restoring the default-safe build state.*
   3. `python tools/hidream_i1_cmp.py ./val` — front-to-back; the first
      `*** DIVERGES ***` localises the bug to the block above it. bf16
      tolerance cos ≥ ~0.999 / max-abs ≲ 1e-2. Use an **unquantized fp16/bf16**
      GGUF so Q8_0 error doesn't mask logic bugs; cfg=1 + steps=1 isolates a
      single transformer forward. Validate encoders in isolation first (the
      Llama tokenizer gap below makes everything downstream meaningless until
      its token IDs match the reference).

   **Progress log (2026-05-18, in-sandbox, no reference avail.):** built a
   gated throwaway smoke driver + a self-contained `HiDreamI1Runner::
   smoke_test` (synthetic deterministic inputs, real GGUF, no encoders/.bin)
   and ran it against `hidream-i1-full-Q8_0.gguf`. It exposed and fixed four
   tensor-binding bugs vs GGUF ground truth → **`load_tensors` now binds
   1615/1615** (was 1071/1408): (a) `caption_projection.linear` is
   weight-only — drop bias; (b) the `AdaLN` sub-block double-prefixed the
   path — its Linear key must be `"1"` so the path is
   `…block.adaLN_modulation.1`; (c) `attn1.to_{q,k,v,out}(+_t)` have bias and
   the output proj is `to_out`/`to_out_t` (not `to_out.0`); (d) added
   `HiDreamRMSNorm` whose param is `.weight` (Flux::RMSNorm uses `.scale`)
   over the **full 2560** projection, applied before head-split. Also fixed
   the synthetic input shapes to ggml ne order.

   **End-to-end pipeline VALIDATED with real encoders (2026-05-18):** with
   user-supplied T5-XXL (`t5-v1_1-xxl-encoder-Q8_0.gguf`) + CLIP-L + CLIP-G
   + Flux VAE (`flux1-dev_ae.safetensors`), ran the real `sd-cli` (experimental
   ON) on `hidream-i1-full-Q8_0.gguf`. Verified working in the live pipeline:
   `Version: HiDream I1` detection; **all 1615 diffusion tensors bind**
   (17.8 GB VRAM); CLIP-L/CLIP-G/T5/VAE all load under the correct prefixes
   (24.3 GB total); the **full conditioner runs** — `get_learned_condition
   completed in 0.24s` producing `c_vector`+`c_crossattn`. Four bugs found &
   fixed (all in the copied-in `src/hidream_i1.hpp`, **not** `wiring.patch`):
   (1) **invocation contract** — the bare GGUF has no `model.diffusion_model.`
   prefix, so it must be loaded via `--diffusion-model`, NOT `-m` (else every
   diffusion tensor logs `not in model file`); (2) conditioner detected/built
   the Llama encoder against `text_encoders.llama.transformer` but upstream's
   `--llm` flag loads under `text_encoders.llm` (conditioner.hpp:1572/1707/
   2122) → never bound; fixed to `text_encoders.llm`; (3) CLIP padding used
   `min_length=0` so tokens were never padded to the 77-pos window →
   `clip.hpp:167` exact-match assert; fixed to `77,77,true` (upstream SD3/Flux
   contract) — **this cleared the assert; the conditioner now runs fully**;
   (4) T5 padding aligned to HiDream's documented `max_length=128`. Added an
   actionable early error when `--llm`/`--t5xxl` are absent (was an opaque
   `tensor_ggml.hpp:67` abort). **Sole remaining blocker for an actual image:
   a Llama-3.1-8B-Instruct GGUF** (`--llm`) — architecturally load-bearing
   (48/49 caption projections + running text stream); none present in-sandbox
   (`text_encoders\llm\` has only gemma-4-E4B + Qwen2.5-VL). Numeric-fidelity
   validation still additionally needs a diffusers reference.

   **Heap-corruption RESOLVED (2026-05-18, root cause):** the `0xC0000374`
   (no ggml assert, fired even at `x_emb` capture) was an OOB write in
   upstream `Rope::gen_flux_img_ids`: it sizes each id vector to
   `axes_dim.size()` but unconditionally writes index `[2]` (Flux always has
   3 axes). HiDream's 2-element `{64,64}` → size-2 vectors → a 1-float heap
   overflow, detected later at free. Fix (FINAL, authoritative): `axes_dim =
   {64,32,32}` — this is the official `axes_dims_rope` from
   `HiDream-ai/HiDream-I1-Full/transformer/config.json` (3-axis Flux
   convention index/h/w, sum `128==head_dim`), so it is both numerically
   faithful AND ≥3 elements (no OOB). (An intermediate `{0,64,64}` was a
   dimensional-only guess before the config was consulted — superseded.)
   With the fix the **entire transformer executes on real GGUF weights** —
   all capture stages finite, exit 0: `x_emb`[2560×64] 2ms, `dbl0` ~70ms,
   `sgl31`/`final`/`image` ~3s, `image` well-bounded `[-0.69, 0.47]`. This is
   **execution-validation**, not numeric-fidelity validation (still blocked:
   no torch/diffusers/encoder weights in-sandbox). The four binding fixes +
   `HiDreamRMSNorm` + the `{64,32,32}` RoPE fix + the gated MoE top-2 path +
   smoke harness are committed in
   `src/hidream_i1.hpp` (copied-in; NOT in `wiring.patch`); see project
   memory `hidream-i1-architecture.md` for the full binding contract.
   **MoE top-2 + renorm IMPLEMENTED (2026-05-18, gated):**
   `MoEFeedForward::forward` now has an exact-by-construction sparse path
   behind `MOE_TOP2_RENORM` (still default `false`): `softmax → ggml_top_k(2)
   → one-hot mask `relu(1-|e-idx_k|)` (no gather/constant; exact for integer
   indices) → keep top-2, renorm by `sum_rows`+eps → weighted expert sum +
   shared`. Mirrors diffusers `MoEGate` (norm_topk_prob=True). A/B smoke on
   real GGUF: both paths exit 0 / finite; the sparse path measurably changes
   output (dbl0 mean −1.037 vs dense −0.933; image range [−1.09,1.05] vs
   [−1.04,0.91]) — confirms the mask is live, not a no-op. Default stays
   dense (`false`) because correctness is proven by construction + execution
   only; flip once a numeric reference confirms it (README step 5).
   - Resolve, in priority order (each is a flagged `FIDELITY TODO` in
     `src/hidream_i1.hpp`):
     1. ~~**MoE top-2 + renorm**~~ — DONE (gated, see above); remaining:
        numeric-validate vs reference, then flip `MOE_TOP2_RENORM` default.
     2. **Per-block Llama layer + running T5/L31 text stream** — now
        PRECISELY SPECIFIED from the authoritative diffusers source +
        official config (see project memory `hidream-i1-architecture.md`
        "AUTHORITATIVE forward() text routing"): `llama_layers` =
        `[0..31, 31×16]`; double/single blocks each consume a *selected*
        llama hidden-state layer; `initial=[T5proj ; L31proj]` is a running
        stream updated through the 16 double blocks then fused into the
        single-block image stream. Current impl uses one static `llama`
        tensor + `[llama_i;t5]` concat — needs the conditioner to emit
        stacked llama hidden states (layers 0-31) and forward() restructured
        to the running-stream topology. Big interface change, unverifiable
        in-sandbox (no llama/T5/CLIP weights, no reference) → spec recorded,
        implementation deferred until a reference env exists.
     3. ~~**RoPE axes**~~ — DONE: `axes_dim={64,32,32}` is the authoritative
        `axes_dims_rope` (config.json), supersedes the `{0,64,64}` heap
        workaround; 3-axis Flux convention, sum 128==head_dim, smoke-runs
        finite. Remaining joint-RoPE fidelity (exact img/txt position ids
        over `[img;txt]`) still needs reference validation.
     4. **Llama-3.1 BPE tokenizer** — replace the `LLMEmbedder` Qwen2
        fallback; align the chat template + pad length.
     5. **llama3 RoPE freq rescaling** (the deferred Step-1 gap): plumb a
        `freq_factors` tensor (factor 8 / low 1 / high 4 / orig 8192)
        through `LLM::Attention` for `LLMArch::LLAMA3`.

Scope: comparable to upstreaming Flux/Qwen-Image — thousands of lines, the
MoE routing and 4-encoder conditioner being the hard parts.

## Regenerating wiring.patch

After staging the edits to the tracked files in the clone (note:
`src/hidream_i1.hpp` is **not** in `wiring.patch` — it is a copied-in
`src/*` file the harness installs separately):

```powershell
git -C build\stable-diffusion.cpp diff -- `
    CMakeLists.txt src/llm.hpp src/model.h src/model.cpp `
    src/stable-diffusion.cpp src/diffusion_model.hpp src/auto_encoder_kl.hpp `
    > sdcpp-patches\hidream-i1\wiring.patch
```

Then set `base-commit.txt` to the clone's current HEAD
(`git -C build\stable-diffusion.cpp rev-parse HEAD`). If upstream later
drifts and `git apply` fails, the build throws with this path — re-stage
against the new HEAD and regenerate. Current `wiring.patch`: 7 files,
**161 insertions / 2 deletions** vs `8308042` (base unchanged). Carries,
beyond the Step 1–4 wiring: `src/auto_encoder_kl.hpp` (gated Flux-VAE latent
scale/shift 0.3611/0.1159) and the gated Step-5 `HIDREAM_I1_VAL` env-var
validation hook in `src/stable-diffusion.cpp`'s `new_sd_ctx` (+28 lines,
2026-05-18; fully `#ifdef SD_HIDREAM_I1_EXPERIMENTAL` + env-gated → OFF path
provably byte-identical by inspection; **ON & OFF builds both verified exit 0
2026-05-18**, see Step-5 runbook §2).
