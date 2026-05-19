"""HiDream-I1 reference capture (diffusers) for step-5 numerical validation.

Runs the canonical diffusers HiDreamImagePipeline ONCE with a fixed prompt /
seed / 1 step, dumps the EXACT transformer inputs and four intermediate
activations into <io_dir> as .bin (shared format: binfmt.py), so the sd.cpp
side can be fed bit-identical inputs and diffed stage-by-stage.

    pip install -U diffusers transformers accelerate torch sentencepiece
    # HiDream-I1-Full + Llama-3.1 are GATED on HF: accept both licenses and
    # `huggingface-cli login` (or set HF_TOKEN) first. The model is NOT
    # downloaded by this repo -- ~50-70GB, fetched on first run.
    python hidream_i1_ref.py --model HiDream-ai/HiDream-I1-Full \
        --io ./val --prompt "a red cube on grass" --seed 42 --size 256
    # default --offload sequential fits ~12GB VRAM but streams 17B weights
    # from system RAM (budget >=64GB; one 1-step forward = minutes). See
    # --offload --help for the model/none alternatives on bigger GPUs.

Then on the sd.cpp side (built -DSD_HIDREAM_I1_EXPERIMENTAL=ON) run
HiDreamI1::HiDreamI1Runner::load_from_file_and_test(<diffusion_gguf>, "./val",
"<stage>") for stage in {x_emb,dbl0,sgl31,final}; finally
`python hidream_i1_cmp.py ./val`. The first "*** DIVERGES ***" localises the
bug to the block between it and the previous good stage.

WHY THIS IS A TRANSFORMER-ISOLATION DIFF (read before trusting a result):
The encoders/tokenizer/scheduler are NOT bit-identical between diffusers and
sd.cpp (different Llama quant, the flagged llama3-rope-scaling / RMSNorm-eps
gaps, BPE-vs-Qwen2 tokenizer). So "same prompt" does NOT give the same
transformer inputs. The only rigorous isolation is to feed sd.cpp the EXACT
tensors diffusers' transformer consumed. This script captures them by spying
on transformer.forward; sd.cpp's load_from_file_and_test injects them and
bypasses its own conditioner entirely. Hence a divergence found here is a
genuine transformer-math bug, not an encoder mismatch.

The hook / restack / timestep conventions below are derived verbatim from the
diffusers source (transformer_hidream_image.py + pipeline_hidream_image.py),
not guessed -- the alignment is the whole point. The script still aborts
loudly on any structural surprise (module renamed, shape off): align to YOUR
diffusers source rather than papering over it -- same fidelity-honesty rule
as the C++ side.
"""

import argparse
import os
import numpy as np
import torch
from binfmt import write_bin

CAPTION_IN = 4096  # Llama-3.1 / T5-XXL hidden width


class _StopAfterCapture(Exception):
    """Raised right after the first transformer.forward returns, to skip the
    scheduler's remaining steps + VAE decode (we only need the hooks)."""


def resolve(mod, dotted):
    cur = mod
    for part in dotted.split("."):
        cur = cur[int(part)] if part.isdigit() else getattr(cur, part)
    return cur


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="HiDream-ai/HiDream-I1-Full")
    ap.add_argument("--io", default="./val")
    ap.add_argument("--prompt", default="a red cube on grass")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--dtype", default="bfloat16",
                    choices=["bfloat16", "float16", "float32"])
    ap.add_argument(
        "--offload", default="sequential",
        choices=["none", "model", "sequential"],
        help="VRAM strategy. HiDream-I1-Full is 17B (bf16 transformer ~34GB) "
             "+ 4 text encoders -- it does NOT fit a consumer GPU. "
             "'sequential' (default) = accelerate per-MODULE CPU<->GPU "
             "streaming: fits ~12GB VRAM, needs the weights resident in "
             "system RAM (bf16: transformer ~34GB + T5 ~9GB + Llama-3.1 ~16GB "
             "+ CLIPs; budget >=64GB RAM or expect swap; one 1-step forward is "
             "minutes, which is fine for a single reference). 'model' = "
             "per-SUBMODEL offload (needs each submodel to fit VRAM alone -- "
             "the 17B transformer does NOT, so only use on a >=40GB GPU). "
             "'none' = everything on --device (needs a very large GPU). "
             "RAM-tight? capture on a bigger box, or use a quantized-"
             "transformer diffusers variant -- but a quantized reference "
             "reintroduces the very error this diff exists to isolate, so "
             "prefer an unquantized run elsewhere over a quantized one here.")
    ap.add_argument(
        "--llama-gguf", default=None,
        help="Path to a local Llama-3.1-8B-Instruct GGUF to use as "
             "text_encoder_4 INSTEAD of fetching the HF-gated "
             "meta-llama/Meta-Llama-3.1-8B-Instruct. transformers dequantises "
             "it on load. VALID for this diff specifically: Step-5 is a "
             "transformer-ISOLATION diff -- the Llama only produces llama.bin, "
             "which is captured and injected IDENTICALLY into both diffusers "
             "and sd.cpp (sd.cpp's own conditioner is bypassed), so the "
             "encoder's quantisation cancels out of the comparison. (The "
             "no-quant rule applies to the *transformer* GGUF on the sd.cpp "
             "side, not this encoder.) The reconstructed-from-GGUF tokenizer "
             "may differ subtly from the official one -- irrelevant here for "
             "the same reason; it would only matter if validating the "
             "conditioner end-to-end, which Step-5 does not.")
    args = ap.parse_args()
    os.makedirs(args.io, exist_ok=True)

    from diffusers import HiDreamImagePipeline

    dt = getattr(torch, args.dtype)
    extra = {}
    if args.llama_gguf:
        from transformers import LlamaForCausalLM, AutoTokenizer
        gd, gf = os.path.dirname(args.llama_gguf), os.path.basename(args.llama_gguf)
        print("text_encoder_4 <- local GGUF (bypassing gated meta-llama): %s"
              % args.llama_gguf)
        tok4 = AutoTokenizer.from_pretrained(gd, gguf_file=gf)
        te4 = LlamaForCausalLM.from_pretrained(
            gd, gguf_file=gf, torch_dtype=dt, output_hidden_states=True,
            low_cpu_mem_usage=True)
        te4.train(False)  # inference mode (== .eval(); avoids dropout etc.)
        nl = te4.config.num_hidden_layers
        if nl != 32:
            print("WARNING: text_encoder_4 has %d layers, expected 32 for "
                  "Llama-3.1-8B (hidden_states[1:] -> restack stays general)."
                  % nl)
        extra = {"text_encoder_4": te4, "tokenizer_4": tok4}
    pipe = HiDreamImagePipeline.from_pretrained(args.model, torch_dtype=dt,
                                                **extra)
    # Offloading manages device placement itself -> must NOT also .to(device)
    # (doing both throws / silently breaks the accelerate hooks).
    if args.offload == "sequential":
        pipe.enable_sequential_cpu_offload()
    elif args.offload == "model":
        pipe.enable_model_cpu_offload()
    else:
        pipe = pipe.to(args.device)
    tf = pipe.transformer
    top = [n for n, _ in tf.named_children()]
    print("transformer top-level modules:", top)
    for need_mod in ("x_embedder", "double_stream_blocks",
                     "single_stream_blocks", "final_layer"):
        if need_mod not in top:
            raise SystemExit(
                "module '%s' absent from this diffusers' HiDream transformer "
                "(%s). The hook plan is from transformer_hidream_image.py; "
                "align it to your version rather than guessing." % (need_mod, top))

    acts, tin, done = {}, {}, {"captured": False}

    def save_out(tag, idx=None):
        def h(_m, _i, o):
            if done["captured"]:          # ignore any 2nd (CFG/neg) call
                return
            if idx is not None:
                t = o[idx]
            else:
                t = o[0] if isinstance(o, (tuple, list)) else o
            acts[tag] = t.detach().float().cpu().numpy()
        return h

    def save_in(tag, idx=0):
        # forward-PRE-hook signature is (module, args) -- 2 positional args,
        # NOT 3 (that's the post forward-hook). `args` is the tuple of
        # positional inputs to final_layer.forward(hidden_states, temb).
        def h(_m, i):
            if done["captured"]:
                return
            acts[tag] = i[idx].detach().float().cpu().numpy()
        return h

    # --- capture points (verified vs transformer_hidream_image.py) ----------
    # x_emb : output of self.x_embedder(hidden_states)             [B,n_img,2560]
    # dbl0  : output[0] (hidden_states) of double_stream_blocks[0] [B,n_img,2560]
    #         (each block is a HiDreamBlock wrapper -> returns
    #          (hidden_states, encoder_hidden_states); we want [0])
    # sgl31 : INPUT[0] of final_layer == hidden_states[:, :image_tokens_seq_len]
    #         AFTER all 32 single blocks + the post-loop image slice. A forward
    #         hook on single_stream_blocks.31 would be WRONG: a single block's
    #         output is the full [img+text+cur_llama] sequence, not the sliced
    #         image-only tensor sd.cpp's "sgl31" tap returns. The pre-hook on
    #         final_layer's input is exactly sd.cpp's tap.
    # final : output of self.final_layer(hidden_states, temb), BEFORE
    #         unpatchify (sd.cpp captures the same pre-unpatchify tensor) -> [B,n_img,p*p*C]
    resolve(tf, "x_embedder").register_forward_hook(save_out("x_emb"))
    resolve(tf, "double_stream_blocks.0").register_forward_hook(save_out("dbl0", idx=0))
    fl = resolve(tf, "final_layer")
    fl.register_forward_pre_hook(save_in("sgl31"))
    fl.register_forward_hook(save_out("final"))

    # --- capture the exact transformer inputs ------------------------------
    import inspect
    orig_fwd = tf.forward
    sig = inspect.signature(orig_fwd)

    def spy_fwd(*a, **kw):
        if not done["captured"]:
            try:
                bound = sig.bind(*a, **kw)
                bound.apply_defaults()
                ba = dict(bound.arguments)
                ba.update(ba.pop("kwargs", {}) or {})
            except TypeError:
                ba = dict(kw)

            def grab(*names):
                for n in names:
                    if n in ba and ba[n] is not None:
                        return ba[n]
                raise SystemExit(
                    "transformer input %s not found among %s; adapt grab() to "
                    "your diffusers transformer.forward signature." %
                    (names, list(ba)))

            hs = grab("hidden_states")                          # [B,16,H,W] pre-patchify latent
            ts = grab("timesteps", "timestep")                  # scheduler t, ~[0,1000]
            t5 = grab("encoder_hidden_states_t5", "t5_hidden_states")          # [B,S_t5,4096]
            ll = grab("encoder_hidden_states_llama3", "llama3_hidden_states")  # [32,B,S_l,4096]
            pl = grab("pooled_embeds", "pooled_projections")    # [B,2048]

            hs = hs.detach().float().cpu().numpy()
            ts = ts.detach().float().cpu().numpy().reshape(-1)
            t5 = t5.detach().float().cpu().numpy()
            ll = ll.detach().float().cpu().numpy()
            pl = pl.detach().float().cpu().numpy()

            # sd.cpp's t_embedder is ggml_ext_timestep_embedding(t,256,10000,
            # time_factor=1000.f): it scales t by 1000 internally (the Flux
            # FLUX_FLOW_PRED convention -- flux.hpp:896 uses the identical
            # factor and works). diffusers' Timesteps(scale=1) consumes the
            # scheduler t (~[0,1000]) directly. So feed sd.cpp t/1000 and its
            # x1000 recovers diffusers' value -> identical sinusoid, timestep
            # convention removed as a confound. (Independently verified, not a
            # guess; documented so it stays auditable.)
            ts = (ts / 1000.0).astype(np.float32)

            if ll.ndim != 4 or ll.shape[0] < 1 or ll.shape[-1] != CAPTION_IN:
                raise SystemExit(
                    "encoder_hidden_states_llama3 shape %s unexpected; the "
                    "pipeline stacks outputs.hidden_states[1:] -> [n_layers,B,"
                    "S,4096]. Align the restack below to your diffusers." %
                    (ll.shape,))
            H, B, S = ll.shape[0], ll.shape[1], ll.shape[2]
            # sd.cpp HiDreamI1::forward indexes its stacked `llama` as
            # llama_layer(hfk) = view block (1+hfk) of [embed,L0..L30,norm(L31)]
            # (33 blocks on the feature axis). diffusers' llama3[k] == HF
            # outputs.hidden_states[1:][k] == layer-k output L_k. So place L_k
            # at block (1+k); block 0 (embed slot) is never selected
            # (llama_layers in [0..31] -> blocks 1..32) -> left zero. NB=H+1.
            NB = H + 1
            stack = np.zeros((B, S, NB * CAPTION_IN), np.float32)
            for k in range(H):
                stack[:, :, (1 + k) * CAPTION_IN:(2 + k) * CAPTION_IN] = ll[k]

            tin["x"] = hs.astype(np.float32)        # numpy [N,C,H,W]  -> ggml ne [W,H,C,N]
            tin["timestep"] = ts                    #       [N]
            tin["t5"] = t5.astype(np.float32)       #       [N,S_t5,4096]
            tin["llama"] = stack                    #       [N,S_l,33*4096]
            tin["pooled"] = pl.astype(np.float32)   #       [N,2048]

        out = orig_fwd(*a, **kw)
        if not done["captured"]:
            # Task #12: capture the transformer's POST-unpatchify return
            # (the [B,C,H,W] velocity the scheduler consumes). Step-5's
            # "final" tap stops BEFORE unpatchify; this validates the
            # token->spatial unpatchify that the full sampler exercises and
            # Step-5 never did. diffusers returns (sample,) when
            # return_dict=False, else Transformer2DModelOutput(sample=...).
            o = out
            if hasattr(o, "sample"):
                o = o.sample
            elif isinstance(o, (tuple, list)):
                o = o[0]
            acts["out"] = o.detach().float().cpu().numpy()
            done["captured"] = True
            raise _StopAfterCapture
        return out

    tf.forward = spy_fwd

    # Under CPU offload the accelerate hooks own device placement; a CPU
    # generator is deterministic and avoids a device-mismatch on the initial
    # latent. With --offload none, match the pipeline device.
    gen_dev = "cpu" if args.offload != "none" else args.device
    g = torch.Generator(gen_dev).manual_seed(args.seed)
    try:
        pipe(args.prompt, height=args.size, width=args.size,
             num_inference_steps=1, guidance_scale=1.0, generator=g)
    except _StopAfterCapture:
        pass  # expected: short-circuit after the single transformer call

    miss = [s for s in ("x_emb", "dbl0", "sgl31", "final") if s not in acts]
    if miss or not tin:
        raise SystemExit(
            "capture incomplete (missing acts=%s, got inputs=%s) -- the "
            "forward likely errored before the hooks fired; check the "
            "diffusers stack trace above." % (miss, bool(tin)))

    for nm, a in tin.items():
        write_bin(os.path.join(args.io, nm + ".bin"), a)
        print("input  %-9s %s" % (nm, a.shape))
    for tag, a in acts.items():
        write_bin(os.path.join(args.io, "ref_%s.bin" % tag), a)
        print("ref    %-9s %s" % (tag, a.shape))
    print("wrote %d inputs + %d ref captures to %s" %
          (len(tin), len(acts), args.io))


if __name__ == "__main__":
    main()
