#ifndef __SD_HIDREAM_I1_H__
#define __SD_HIDREAM_I1_H__

// HiDream-I1 — original 17B sparse-MoE MMDiT (dual/single-stream transformer)
// + 4-encoder conditioner: CLIP-L, CLIP-G, T5-XXL, Llama-3.1-8B.
//
// Header-only, copied verbatim into <clone>\src\ by the harness
// (sdcpp-patches\patch-lib.ps1). Not #included anywhere until the wiring.patch
// in this folder adds the include + factory branch (Step 4), so this TU stays
// inert and the build is vanilla upstream until that lands.
//
// Architecture is Flux-derived (see src/flux.hpp): the embedders, modulation,
// joint dual-stream attention, single-stream block and final-layer shapes
// mirror Flux's, with three HiDream-specific deltas:
//   1. The image feed-forward is a sparse Mixture-of-Experts (`ff_i`): a
//      [hidden->4] router, top-2 of 4 SwiGLU experts, plus an always-on
//      `shared_experts` SwiGLU. Double blocks additionally carry a dense text
//      feed-forward (`ff_t`).
//   2. Double-stream blocks carry SEPARATE text attention projections
//      (`attn1.to_{q,k,v}_t` / `to_out_t`) and per-head q/k RMS-norm for both
//      streams; the joint attention concatenates [img;txt] on the token axis.
//   3. Conditioning is the concat of a projected T5-XXL stream and a per-block
//      projected Llama-3.1 hidden-state stream (`caption_projection`, 49
//      Linear(4096->2560): idx 0-15 -> double block i, 16-47 -> single block
//      (i-16), 48 -> T5), plus a pooled CLIP-L+CLIP-G vector through
//      `p_embedder` added into the timestep modulation vector.
//
// FIDELITY STATUS (the items below were "TODO pending a diffusers reference"
// in the original plan; the reference WAS run 2026-05-18/19 and the per-stage
// numeric diff performed — see README step 5 + project memory
// `hidream-i1-architecture` / `hidream-i1-noise-rootcause`. All RESOLVED;
// recorded here so the constants stay auditable, not as open work):
//   * MoE routing — RESOLVED. Implemented as the authoritative diffusers
//     `MoEGate`: softmax(4) → top-2 → weights used AS-IS (norm_topk_prob =
//     False, verified from source — there is NO renorm; the earlier "renorm
//     to sum 1" plan and the MOE_TOP2_RENORM flag were both wrong and removed).
//     Now the unconditional default (MoEFeedForward::forward).
//   * Per-block Llama layer selection — RESOLVED. `config.llama_layers` =
//     [0..31, 31×16] is implemented (HiDreamI1::forward: `caption_proj(LL[i])`
//     over the 49 projections + the running [T5proj;L31proj] text stream
//     carried through the 16 double blocks then fused into the single blocks),
//     verbatim from `transformer_hidream_image.py`.
//   * Joint RoPE — RESOLVED. EmbedND theta=10000, axes_dims_rope = {64,32,32}
//     (official HiDream-I1-Full config; Σ=128=head_dim — the old (32,32) note
//     was wrong), image-first [img;txt] pe reorder; gen_flux_pe path.
//   * Llama-3.1 "llama3" RoPE freq rescaling — RESOLVED in wiring.patch
//     (llm.hpp): precomputed freq_factors (factor 8 / low 1 / high 4 /
//     orig 8192, theta 500000) per the HF Llama-3.1 config.
// The pure-noise bug was root-caused (FluxFlow output-sign: `return out *
// -1.0f` here) and the pure-white bug fixed at source (F16-overflow →
// kv_scale=1/128 in JointAttention). Only residual MEASURED item, minor and
// sub-catastrophic, NOT a wrong constant: the Llama pad-position hidden states
// run ~2.9× (project memory `hidream-i1-llama-encoder-bug-measured`).
//
// See sdcpp-patches\hidream-i1\README.md for the implementation plan and the
// project memory `hidream-i1-architecture.md` for the exact GGUF tensor table.

#include <fstream>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "common_dit.hpp"
#include "conditioner.hpp"
#include "flux.hpp"
#include "ggml_extend.hpp"
#include "llama3_tokenizer.hpp"  // patch-set sibling (copied-in, not wiring.patch)
#include "llm.hpp"
#include "model.h"
#include "rope.hpp"

namespace HiDreamI1 {

    constexpr int HIDREAM_I1_GRAPH_SIZE = 32768;

    // MoE routing is the authoritative diffusers `MoEGate`: softmax(4) →
    // top-2 select → weights used AS-IS (norm_topk_prob = False, verified
    // 2026-05-18 from source) → Σ selected expert·w + always-on shared. It
    // is exact-by-construction (one-hot mask via the integer-index identity,
    // no gather/constant) and now the unconditional default — the earlier
    // dense-4 default and the renorm path were both wrong.

    // ---- reused Flux building blocks (identical math) ------------------------
    using Flux::LastLayer;
    using Flux::modulate;
    using Flux::ModulationOut;
    using Flux::MLPEmbedder;
    using Flux::RMSNorm;

    // HiDream's attn q/k RMS-norm stores its scale as `.weight` (GGUF ground
    // truth), unlike Flux::RMSNorm which names it `.scale`.
    struct HiDreamRMSNorm : public UnaryBlock {
        int64_t dim;
        float eps;
        void init_params(ggml_context* ctx,
                         const String2TensorStorage& tensor_storage_map = {},
                         const std::string prefix                       = "") override {
            params["weight"] = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, dim);
        }
        // eps = 1e-5: diffusers HiDreamAttention.__init__ default
        // `eps: float = 1e-5` passed to nn.RMSNorm(inner_dim, eps)
        // (verified vs transformer_hidream_image.py 2026-05-18; was 1e-6f).
        HiDreamRMSNorm(int64_t dim, float eps = 1e-5f)
            : dim(dim), eps(eps) {}
        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* x) override {
            x = ggml_rms_norm(ctx->ggml_ctx, x, eps);
            return ggml_mul(ctx->ggml_ctx, x, params["weight"]);
        }
    };

    // Per-head query/key RMS-norm pair (HiDream `*_rms_norm` tensors).
    struct QKRMSNorm : public GGMLBlock {
        QKRMSNorm(int64_t head_dim) {
            blocks["q"] = std::make_shared<RMSNorm>(head_dim);
            blocks["k"] = std::make_shared<RMSNorm>(head_dim);
        }
        ggml_tensor* q_norm(GGMLRunnerContext* ctx, ggml_tensor* x) {
            return std::dynamic_pointer_cast<RMSNorm>(blocks["q"])->forward(ctx, x);
        }
        ggml_tensor* k_norm(GGMLRunnerContext* ctx, ggml_tensor* x) {
            return std::dynamic_pointer_cast<RMSNorm>(blocks["k"])->forward(ctx, x);
        }
    };

    struct TimestepEmbedder : public GGMLBlock {
        int frequency_embedding_size = 256;
        TimestepEmbedder(int64_t hidden_size) {
            blocks["timestep_embedder.linear_1"] = std::make_shared<Linear>(frequency_embedding_size, hidden_size, true);
            blocks["timestep_embedder.linear_2"] = std::make_shared<Linear>(hidden_size, hidden_size, true);
        }
        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* t) {
            auto l1  = std::dynamic_pointer_cast<Linear>(blocks["timestep_embedder.linear_1"]);
            auto l2  = std::dynamic_pointer_cast<Linear>(blocks["timestep_embedder.linear_2"]);
            auto emb = ggml_ext_timestep_embedding(ctx->ggml_ctx, t, frequency_embedding_size, 10000, 1000.0f);
            emb      = l1->forward(ctx, emb);
            emb      = ggml_silu_inplace(ctx->ggml_ctx, emb);
            emb      = l2->forward(ctx, emb);
            return emb;
        }
    };

    // CLIP-L+CLIP-G pooled (2048) -> hidden, added into the modulation vec.
    struct PooledEmbedder : public GGMLBlock {
        PooledEmbedder(int64_t in_dim, int64_t hidden_size) {
            blocks["pooled_embedder.linear_1"] = std::make_shared<Linear>(in_dim, hidden_size, true);
            blocks["pooled_embedder.linear_2"] = std::make_shared<Linear>(hidden_size, hidden_size, true);
        }
        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* x) {
            auto l1 = std::dynamic_pointer_cast<Linear>(blocks["pooled_embedder.linear_1"]);
            auto l2 = std::dynamic_pointer_cast<Linear>(blocks["pooled_embedder.linear_2"]);
            x       = l1->forward(ctx, x);
            x       = ggml_silu_inplace(ctx->ggml_ctx, x);
            x       = l2->forward(ctx, x);
            return x;
        }
    };

    // SwiGLU expert / shared-expert / dense text-FF: w2(silu(w1 x) * w3 x).
    struct SwiGLU : public UnaryBlock {
        SwiGLU(int64_t dim, int64_t inter) {
            blocks["w1"] = std::make_shared<Linear>(dim, inter, false);
            blocks["w2"] = std::make_shared<Linear>(inter, dim, false);
            blocks["w3"] = std::make_shared<Linear>(dim, inter, false);
        }
        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* x) override {
            auto w1 = std::dynamic_pointer_cast<Linear>(blocks["w1"]);
            auto w2 = std::dynamic_pointer_cast<Linear>(blocks["w2"]);
            auto w3 = std::dynamic_pointer_cast<Linear>(blocks["w3"]);
            auto g  = ggml_silu_inplace(ctx->ggml_ctx, w1->forward(ctx, x));
            auto u  = w3->forward(ctx, x);
            return w2->forward(ctx, ggml_mul_inplace(ctx->ggml_ctx, g, u));
        }
    };

    // Sparse-MoE image feed-forward (`ff_i`): router + 4 routed SwiGLU experts
    // + always-on shared SwiGLU.
    struct MoEFeedForward : public GGMLBlock {
        int num_experts;
        MoEFeedForward(int64_t dim, int64_t expert_inter, int64_t shared_inter, int num_experts)
            : num_experts(num_experts) {
            blocks["gate"] = std::make_shared<Linear>(dim, num_experts, false);
            for (int e = 0; e < num_experts; e++) {
                blocks["experts." + std::to_string(e)] = std::make_shared<SwiGLU>(dim, expert_inter);
            }
            blocks["shared_experts"] = std::make_shared<SwiGLU>(dim, shared_inter);
        }

        ggml_tensor* forward(GGMLRunnerContext* ctx, ggml_tensor* x) {
            // x: [N, n_token, dim]
            auto gate   = std::dynamic_pointer_cast<Linear>(blocks["gate"]);
            auto shared = std::dynamic_pointer_cast<SwiGLU>(blocks["shared_experts"]);

            auto logits  = gate->forward(ctx, x);                       // [E, n_token, N]
            auto weights = ggml_soft_max(ctx->ggml_ctx, logits);        // [E, n_token, N]

            // AUTHORITATIVE MoEGate (diffusers transformer_hidream_image.py,
            // verified 2026-05-18): scoring=softmax, top-2 select, and
            // **norm_topk_prob = False** — the selected softmax probs are used
            // AS-IS, NOT renormalised (earlier memory/comment said True; the
            // source has it False). So: zero all but the top-2 experts and
            // keep their raw softmax weights. The previous default summed all
            // 4 (dense) and the gated path renormalised — both wrong.
            //
            // Top-2 mask without any gather/constant: for integer top-k
            // indices, the one-hot of index j over axis e is
            // relu(1 - |e - j|) (==1 iff e==j, else 0 since |e-j| is an
            // integer >= 1). M = sum of the 2 one-hots (indices distinct ⇒
            // M ∈ {0,1}); weights := softmax · M  (no /denominator).
            {
                int64_t E = weights->ne[0], T = weights->ne[1], Nn = weights->ne[2];
                auto idx  = ggml_top_k(ctx->ggml_ctx, weights, 2);                  // i32 [2,T,N]
                auto idxf = ggml_cast(ctx->ggml_ctx, idx, GGML_TYPE_F32);           // f32 [2,T,N]
                auto arE  = ggml_repeat(ctx->ggml_ctx,
                                        ggml_reshape_4d(ctx->ggml_ctx,
                                                        ggml_arange(ctx->ggml_ctx, 0.f, (float)E, 1.f),
                                                        E, 1, 1, 1),
                                        weights);                                   // [E,T,N] = e
                ggml_tensor* M = nullptr;
                for (int k = 0; k < 2; k++) {
                    auto jk  = ggml_view_3d(ctx->ggml_ctx, idxf, 1, T, Nn,
                                            idxf->nb[1], idxf->nb[2], k * idxf->nb[0]);  // [1,T,N]
                    auto d   = ggml_sub(ctx->ggml_ctx, arE, jk);                          // [E,T,N] e-j
                    auto oh  = ggml_relu(ctx->ggml_ctx,
                                         ggml_scale_bias(ctx->ggml_ctx,
                                                         ggml_abs(ctx->ggml_ctx, d), -1.f, 1.f));
                    M = M ? ggml_add(ctx->ggml_ctx, M, oh) : oh;                          // [E,T,N] {0,1}
                }
                weights = ggml_mul(ctx->ggml_ctx, weights, M);  // top-2, NO renorm
            }

            ggml_tensor* out = nullptr;
            for (int e = 0; e < num_experts; e++) {
                auto expert = std::dynamic_pointer_cast<SwiGLU>(blocks["experts." + std::to_string(e)]);
                auto y      = expert->forward(ctx, x);  // [N, n_token, dim]
                // per-token scalar weight for expert e: weights[..., e]
                auto w = ggml_view_3d(ctx->ggml_ctx, weights,
                                      1, weights->ne[1], weights->ne[2],
                                      weights->nb[1], weights->nb[2],
                                      e * weights->nb[0]);  // [N, n_token, 1]
                y      = ggml_mul(ctx->ggml_ctx, y, w);
                out    = out ? ggml_add_inplace(ctx->ggml_ctx, out, y) : y;
            }
            out = ggml_add_inplace(ctx->ggml_ctx, out, shared->forward(ctx, x));
            return out;
        }
    };

    // Single-stream joint attention shared by double (img+txt) and single
    // blocks. `to_*_t` projections only exist on double blocks (separate=true).
    struct JointAttention : public GGMLBlock {
        int64_t num_heads;
        bool separate_txt;
        JointAttention(int64_t dim, int64_t num_heads, bool separate_txt)
            : num_heads(num_heads), separate_txt(separate_txt) {
            // GGUF ground truth: to_{q,k,v,out}.{weight,bias} (bias present);
            // q_rms_norm/k_rms_norm.weight dims=[dim] -> RMSNorm over the full
            // projection (applied before head-split), NOT per head_dim.
            blocks["to_q"]       = std::make_shared<Linear>(dim, dim, true);
            blocks["to_k"]       = std::make_shared<Linear>(dim, dim, true);
            blocks["to_v"]       = std::make_shared<Linear>(dim, dim, true);
            blocks["to_out"]     = std::make_shared<Linear>(dim, dim, true);
            blocks["q_rms_norm"] = std::make_shared<HiDreamRMSNorm>(dim);
            blocks["k_rms_norm"] = std::make_shared<HiDreamRMSNorm>(dim);
            if (separate_txt) {
                blocks["to_q_t"]       = std::make_shared<Linear>(dim, dim, true);
                blocks["to_k_t"]       = std::make_shared<Linear>(dim, dim, true);
                blocks["to_v_t"]       = std::make_shared<Linear>(dim, dim, true);
                blocks["to_out_t"]     = std::make_shared<Linear>(dim, dim, true);
                blocks["q_rms_norm_t"] = std::make_shared<HiDreamRMSNorm>(dim);
                blocks["k_rms_norm_t"] = std::make_shared<HiDreamRMSNorm>(dim);
            }
        }

        // split a [.,.,dim] projection into [head_dim, n_head, L, N]
        ggml_tensor* split_heads(GGMLRunnerContext* ctx, ggml_tensor* t) {
            int64_t head_dim = t->ne[0] / num_heads;
            return ggml_reshape_4d(ctx->ggml_ctx, t, head_dim, num_heads, t->ne[1], t->ne[2]);
        }

        // returns concatenated attention output [img;txt] split by the caller.
        std::pair<ggml_tensor*, ggml_tensor*> forward(GGMLRunnerContext* ctx,
                                                      ggml_tensor* img,
                                                      ggml_tensor* txt,
                                                      ggml_tensor* pe,
                                                      ggml_tensor* mask) {
            auto to_q    = std::dynamic_pointer_cast<Linear>(blocks["to_q"]);
            auto to_k    = std::dynamic_pointer_cast<Linear>(blocks["to_k"]);
            auto to_v    = std::dynamic_pointer_cast<Linear>(blocks["to_v"]);
            auto to_out  = std::dynamic_pointer_cast<Linear>(blocks["to_out"]);
            auto q_norm  = std::dynamic_pointer_cast<HiDreamRMSNorm>(blocks["q_rms_norm"]);
            auto k_norm  = std::dynamic_pointer_cast<HiDreamRMSNorm>(blocks["k_rms_norm"]);

            // RMSNorm over the full projection (dim) THEN split into heads.
            auto iq = split_heads(ctx, q_norm->forward(ctx, to_q->forward(ctx, img)));
            auto ik = split_heads(ctx, k_norm->forward(ctx, to_k->forward(ctx, img)));
            auto iv = split_heads(ctx, to_v->forward(ctx, img));

            ggml_tensor* q = iq;
            ggml_tensor* k = ik;
            ggml_tensor* v = iv;
            ggml_tensor* tq = nullptr;
            if (txt != nullptr) {
                std::shared_ptr<Linear> tq_p, tk_p, tv_p;
                std::shared_ptr<HiDreamRMSNorm> tqn, tkn;
                if (separate_txt) {
                    tq_p = std::dynamic_pointer_cast<Linear>(blocks["to_q_t"]);
                    tk_p = std::dynamic_pointer_cast<Linear>(blocks["to_k_t"]);
                    tv_p = std::dynamic_pointer_cast<Linear>(blocks["to_v_t"]);
                    tqn  = std::dynamic_pointer_cast<HiDreamRMSNorm>(blocks["q_rms_norm_t"]);
                    tkn  = std::dynamic_pointer_cast<HiDreamRMSNorm>(blocks["k_rms_norm_t"]);
                } else {
                    tq_p = to_q;
                    tk_p = to_k;
                    tv_p = to_v;
                    tqn  = q_norm;
                    tkn  = k_norm;
                }
                tq      = split_heads(ctx, tqn->forward(ctx, tq_p->forward(ctx, txt)));
                auto tk = split_heads(ctx, tkn->forward(ctx, tk_p->forward(ctx, txt)));
                auto tv = split_heads(ctx, tv_p->forward(ctx, txt));
                q       = ggml_concat(ctx->ggml_ctx, iq, tq, 2);  // concat on token axis
                k       = ggml_concat(ctx->ggml_ctx, ik, tk, 2);
                v       = ggml_concat(ctx->ggml_ctx, iv, tv, 2);
            }

            // kv_scale = 1/d_head (d_head = 2560/20 = 128): HiDream's q/k pass
            // through a learned-weight RMSNorm over the full 2560-dim
            // projection, giving larger magnitudes than Flux's per-head qk
            // norm. ggml_ext_attention_ext's flash path casts k,v to F16, so
            // at high resolution (long [img;txt] sequence) the F16 QK^T
            // overflows -> NaN -> pure-white image (FA-on only; FA-off keeps
            // F32 and is fine). The helper's kv_scale down-scales k,v before
            // the F16 cast and compensates exactly (softmax scale/kv_scale,
            // output x 1/kv_scale) -> mathematically transparent, only the
            // F16 dynamic range changes. Mirrors the proven Z-Image DiT path
            // (z_image.hpp uses the identical 1/128). Lets flash attention be
            // used for HiDream-I1 without the white-image NaN.
            auto attn = Rope::attention(ctx, q, k, v, pe, mask, 1.f / 128.f);  // [N, L, dim]

            ggml_tensor* img_out = attn;
            ggml_tensor* txt_out = nullptr;
            if (txt != nullptr) {
                img_out = ggml_view_3d(ctx->ggml_ctx, attn, attn->ne[0], img->ne[1], attn->ne[2],
                                       attn->nb[1], attn->nb[2], 0);
                txt_out = ggml_view_3d(ctx->ggml_ctx, attn, attn->ne[0], txt->ne[1], attn->ne[2],
                                       attn->nb[1], attn->nb[2], img->ne[1] * attn->nb[1]);
                txt_out = ggml_cont(ctx->ggml_ctx, txt_out);
                if (separate_txt) {
                    auto to_out_t = std::dynamic_pointer_cast<Linear>(blocks["to_out_t"]);
                    txt_out       = to_out_t->forward(ctx, txt_out);
                } else {
                    txt_out = to_out->forward(ctx, txt_out);
                }
            }
            img_out = ggml_cont(ctx->ggml_ctx, img_out);
            img_out = to_out->forward(ctx, img_out);
            return {img_out, txt_out};
        }
    };

    // adaLN modulation: silu(vec) -> Linear -> chunk into `mult` ModulationOut
    // groups of (shift, scale, gate).
    struct AdaLN : public GGMLBlock {
        int mult;
        AdaLN(int64_t dim, int mult)
            : mult(mult) {
            // Registered by the parent under key "adaLN_modulation"; this
            // Linear's key "1" makes the full path "...adaLN_modulation.1"
            // (GGUF ground truth) instead of double-prefixing.
            blocks["1"] = std::make_shared<Linear>(dim, dim * 3 * mult, true);
        }
        std::vector<ModulationOut> forward(GGMLRunnerContext* ctx, ggml_tensor* vec) {
            auto lin = std::dynamic_pointer_cast<Linear>(blocks["1"]);
            auto out = lin->forward(ctx, ggml_silu(ctx->ggml_ctx, vec));  // [N, dim*3*mult]
            auto m   = ggml_reshape_3d(ctx->ggml_ctx, out, vec->ne[0], 3 * mult, vec->ne[1]);
            m        = ggml_cont(ctx->ggml_ctx, ggml_permute(ctx->ggml_ctx, m, 0, 2, 1, 3));  // [3*mult, N, dim]
            std::vector<ModulationOut> mods;
            for (int i = 0; i < mult; i++) {
                mods.emplace_back(ctx, m, 3 * i);
            }
            return mods;
        }
    };

    struct DoubleStreamBlock : public GGMLBlock {
        DoubleStreamBlock(int64_t hidden, int64_t num_heads, int num_experts,
                          int64_t expert_inter, int64_t shared_inter, int64_t txt_ff_inter) {
            blocks["adaLN_modulation"] = std::make_shared<AdaLN>(hidden, 4);  // img{msa,mlp} + txt{msa,mlp}
            blocks["norm1_i"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["norm1_t"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["norm3_i"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["norm3_t"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["attn1"]            = std::make_shared<JointAttention>(hidden, num_heads, true);
            blocks["ff_i"]             = std::make_shared<MoEFeedForward>(hidden, expert_inter, shared_inter, num_experts);
            blocks["ff_t"]             = std::make_shared<SwiGLU>(hidden, txt_ff_inter);
        }

        std::pair<ggml_tensor*, ggml_tensor*> forward(GGMLRunnerContext* ctx,
                                                      ggml_tensor* img,
                                                      ggml_tensor* txt,
                                                      ggml_tensor* vec,
                                                      ggml_tensor* pe,
                                                      ggml_tensor* mask) {
            auto ada    = std::dynamic_pointer_cast<AdaLN>(blocks["adaLN_modulation"]);
            auto n1i    = std::dynamic_pointer_cast<LayerNorm>(blocks["norm1_i"]);
            auto n1t    = std::dynamic_pointer_cast<LayerNorm>(blocks["norm1_t"]);
            auto n3i    = std::dynamic_pointer_cast<LayerNorm>(blocks["norm3_i"]);
            auto n3t    = std::dynamic_pointer_cast<LayerNorm>(blocks["norm3_t"]);
            auto attn   = std::dynamic_pointer_cast<JointAttention>(blocks["attn1"]);
            auto ff_i   = std::dynamic_pointer_cast<MoEFeedForward>(blocks["ff_i"]);
            auto ff_t   = std::dynamic_pointer_cast<SwiGLU>(blocks["ff_t"]);

            auto mods = ada->forward(ctx, vec);  // [img_msa, img_mlp, txt_msa, txt_mlp]
            auto& im1 = mods[0];
            auto& im2 = mods[1];
            auto& tm1 = mods[2];
            auto& tm2 = mods[3];

            auto img_in = modulate(ctx->ggml_ctx, n1i->forward(ctx, img), im1.shift, im1.scale);
            auto txt_in = modulate(ctx->ggml_ctx, n1t->forward(ctx, txt), tm1.shift, tm1.scale);

            auto a   = attn->forward(ctx, img_in, txt_in, pe, mask);
            img      = ggml_add(ctx->ggml_ctx, img, ggml_mul(ctx->ggml_ctx, a.first, im1.gate));
            txt      = ggml_add(ctx->ggml_ctx, txt, ggml_mul(ctx->ggml_ctx, a.second, tm1.gate));

            auto img_ff = ff_i->forward(ctx, modulate(ctx->ggml_ctx, n3i->forward(ctx, img), im2.shift, im2.scale));
            img         = ggml_add(ctx->ggml_ctx, img, ggml_mul(ctx->ggml_ctx, img_ff, im2.gate));
            auto txt_ff = ff_t->forward(ctx, modulate(ctx->ggml_ctx, n3t->forward(ctx, txt), tm2.shift, tm2.scale));
            txt         = ggml_add(ctx->ggml_ctx, txt, ggml_mul(ctx->ggml_ctx, txt_ff, tm2.gate));
            return {img, txt};
        }
    };

    struct SingleStreamBlock : public GGMLBlock {
        SingleStreamBlock(int64_t hidden, int64_t num_heads, int num_experts,
                          int64_t expert_inter, int64_t shared_inter) {
            blocks["adaLN_modulation"] = std::make_shared<AdaLN>(hidden, 2);  // msa + mlp (image-only)
            blocks["norm1_i"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["norm3_i"]          = std::make_shared<LayerNorm>(hidden, 1e-6f, false);
            blocks["attn1"]            = std::make_shared<JointAttention>(hidden, num_heads, false);
            blocks["ff_i"]             = std::make_shared<MoEFeedForward>(hidden, expert_inter, shared_inter, num_experts);
        }

        ggml_tensor* forward(GGMLRunnerContext* ctx,
                             ggml_tensor* x,
                             ggml_tensor* vec,
                             ggml_tensor* pe,
                             ggml_tensor* mask) {
            auto ada  = std::dynamic_pointer_cast<AdaLN>(blocks["adaLN_modulation"]);
            auto n1   = std::dynamic_pointer_cast<LayerNorm>(blocks["norm1_i"]);
            auto n3   = std::dynamic_pointer_cast<LayerNorm>(blocks["norm3_i"]);
            auto attn = std::dynamic_pointer_cast<JointAttention>(blocks["attn1"]);
            auto ff_i = std::dynamic_pointer_cast<MoEFeedForward>(blocks["ff_i"]);

            auto mods = ada->forward(ctx, vec);  // [msa, mlp]
            auto& m1  = mods[0];
            auto& m2  = mods[1];

            auto x_in = modulate(ctx->ggml_ctx, n1->forward(ctx, x), m1.shift, m1.scale);
            auto a    = attn->forward(ctx, x_in, nullptr, pe, mask);
            x         = ggml_add(ctx->ggml_ctx, x, ggml_mul(ctx->ggml_ctx, a.first, m1.gate));
            auto ff   = ff_i->forward(ctx, modulate(ctx->ggml_ctx, n3->forward(ctx, x), m2.shift, m2.scale));
            x         = ggml_add(ctx->ggml_ctx, x, ggml_mul(ctx->ggml_ctx, ff, m2.gate));
            return x;
        }
    };

    struct HiDreamI1Params {
        int patch_size           = 2;
        int64_t in_channels      = 64;   // 2x2 patch * 16 Flux-VAE channels
        int64_t vae_channels     = 16;
        int64_t hidden_size      = 2560;
        int num_heads            = 20;
        int head_dim             = 128;
        int num_double_blocks    = 16;
        int num_single_blocks    = 32;
        int num_experts          = 4;
        int num_activated        = 2;
        int64_t expert_inter     = 6912;
        int64_t shared_inter     = 3584;
        int64_t txt_ff_inter     = 6912;
        int64_t caption_in       = 4096;  // T5 / Llama-3.1 width
        int64_t pooled_in        = 2048;  // CLIP-L(768)+CLIP-G(1280)
        int theta                = 10000;
        // AUTHORITATIVE (HiDream-ai/HiDream-I1-Full transformer/config.json):
        // axes_dims_rope = [64, 32, 32], θ=10000. Three axes (index, h, w),
        // Flux convention — exactly what upstream Rope::gen_flux_img_ids
        // expects (it writes id components [0]=index/[1]=row/[2]=col, so a
        // 3-element axes_dim is both numerically faithful AND avoids the
        // earlier 0xC0000374: a 2-element axes_dim sized the id vectors to 2
        // while [2] was still written → 1-float heap overflow). sum =
        // 64+32+32 = 128 == head_dim, so pe sizing / apply_rope are exact.
        // (Supersedes the earlier {0,64,64} dimensional workaround, which
        // was a guess; this is the official config value.)
        std::vector<int> axes_dim = {64, 32, 32};
        int axes_dim_sum         = 128;
    };

    static inline HiDreamI1Params make_hidream_i1_params() { return {}; }

    struct HiDreamI1 : public GGMLBlock {
        HiDreamI1Params params;
        // Step-5 validation: when non-empty, forward() returns the named raw
        // activation (pre-unpatchify) instead of the final image so it can be
        // diffed against a diffusers forward-hook capture. Tags: "x_emb",
        // "dbl0", "sgl31", "final". Empty in all normal use.
        std::string capture;
        HiDreamI1() = default;
        explicit HiDreamI1(HiDreamI1Params params)
            : params(params) {
            int n_cap = params.num_double_blocks + params.num_single_blocks + 1;  // 49

            blocks["x_embedder.proj"] = std::make_shared<Linear>(params.in_channels, params.hidden_size, true);
            blocks["t_embedder"]      = std::make_shared<TimestepEmbedder>(params.hidden_size);
            blocks["p_embedder"]      = std::make_shared<PooledEmbedder>(params.pooled_in, params.hidden_size);
            for (int i = 0; i < n_cap; i++) {
                blocks["caption_projection." + std::to_string(i) + ".linear"] =
                    std::make_shared<Linear>(params.caption_in, params.hidden_size, false);  // GGUF: weight only
            }
            for (int i = 0; i < params.num_double_blocks; i++) {
                blocks["double_stream_blocks." + std::to_string(i) + ".block"] =
                    std::make_shared<DoubleStreamBlock>(params.hidden_size, params.num_heads,
                                                        params.num_experts, params.expert_inter,
                                                        params.shared_inter, params.txt_ff_inter);
            }
            for (int i = 0; i < params.num_single_blocks; i++) {
                blocks["single_stream_blocks." + std::to_string(i) + ".block"] =
                    std::make_shared<SingleStreamBlock>(params.hidden_size, params.num_heads,
                                                        params.num_experts, params.expert_inter,
                                                        params.shared_inter);
            }
            blocks["final_layer"] = std::make_shared<LastLayer>(params.hidden_size, 1,
                                                                params.in_channels, false, true);
        }

        std::shared_ptr<Linear> caption_proj(int i) {
            return std::dynamic_pointer_cast<Linear>(
                blocks["caption_projection." + std::to_string(i) + ".linear"]);
        }

        // x: [N, vae_channels, H, W]; t5/llama: [N, n_txt, caption_in];
        // pooled: [N, pooled_in]; timesteps: [N]
        ggml_tensor* forward(GGMLRunnerContext* ctx,
                             ggml_tensor* x,
                             ggml_tensor* timesteps,
                             ggml_tensor* t5,
                             ggml_tensor* llama,
                             ggml_tensor* pooled,
                             ggml_tensor* pe,
                             ggml_tensor* mask) {
            auto x_embedder = std::dynamic_pointer_cast<Linear>(blocks["x_embedder.proj"]);
            auto t_embedder = std::dynamic_pointer_cast<TimestepEmbedder>(blocks["t_embedder"]);
            auto p_embedder = std::dynamic_pointer_cast<PooledEmbedder>(blocks["p_embedder"]);
            auto final_layer = std::dynamic_pointer_cast<LastLayer>(blocks["final_layer"]);

            int64_t H = x->ne[1];
            int64_t W = x->ne[0];

            // HiDream-I1 patchify feature order differs from Flux/other DiTs.
            // diffusers (square): reshape(B,C,pH,p,pW,p).permute(0,2,4,3,5,1)
            // .reshape(B,pH*pW,p*p*C) → per-token feature = (p1,p2,C), C
            // INNERMOST/fastest. sd.cpp's shared DiT::pad_and_patchify emits
            // Flux's (C,p1,p2) C-OUTERMOST order (ne0 fastest→slowest =
            // [pw,ph,C]). HiDream's x_embedder.proj was trained on the
            // C-fastest order, so feed it that. Token order (pH outer / pW
            // inner) already matches, so img_ids/pe stay consistent.
            int    P  = params.patch_size;
            int64_t Cv = params.vae_channels;
            auto img = DiT::pad_and_patchify(ctx, x, P, P);  // [C*P*P, T, N], C-slowest
            {
                int64_t T = img->ne[1], Nb = img->ne[2];
                auto r = ggml_reshape_4d(ctx->ggml_ctx, img, P, P, Cv, T * Nb);  // [pw,ph,C,T*N]
                r = ggml_cont(ctx->ggml_ctx, ggml_permute(ctx->ggml_ctx, r, 1, 2, 0, 3));  // ne=[C,pw,ph,T*N]
                img = ggml_reshape_3d(ctx->ggml_ctx, r, Cv * P * P, T, Nb);  // [C*P*P, T, N], C-fastest
            }
            img = x_embedder->forward(ctx, img);                                            // [N, n_img, hidden]
            if (capture == "x_emb") return ggml_cont(ctx->ggml_ctx, img);

            auto vec = t_embedder->forward(ctx, timesteps);            // [N, hidden]
            vec      = ggml_add(ctx->ggml_ctx, vec, p_embedder->forward(ctx, pooled));

            int n_double = params.num_double_blocks;   // 16
            int n_single = params.num_single_blocks;    // 32
            int n_cap    = n_double + n_single;         // 48 llama projections

            // AUTHORITATIVE text routing (diffusers transformer_hidream_image
            // .py + HiDream-ai/HiDream-I1-Full config.json, verified
            // 2026-05-18). `llama` here is sd.cpp's return_all_hidden_states
            // stack concatenated on ne0: blocks = [embed, L0, L1, …, L30,
            // norm(L31)] (33 × caption_in). The HF pipeline uses
            // outputs.hidden_states[1:] (drops the embed) indexed by
            // config.llama_layers, so HF llama3[k] == sd.cpp stack block
            // (1+k). LL = config.llama_layers (48): 0..31 then 31×16.
            // FIDELITY NOTE: sd.cpp applies the final RMSNorm to its last
            // stacked entry, so block (1+31) is norm(L31) where HF wants raw
            // L31 — a flagged minor gap for the heavily-reused layer-31 slot.
            static const int LL[48] = {
                0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
                16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
                31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31};
            int64_t C = params.caption_in;  // 4096; stack block stride on ne0
            auto llama_layer = [&](int hfk) -> ggml_tensor* {
                int64_t blk = 1 + hfk;  // skip embed (stack idx 0)
                auto v = ggml_view_3d(ctx->ggml_ctx, llama, C, llama->ne[1], llama->ne[2],
                                      llama->nb[1], llama->nb[2], blk * C * llama->nb[0]);
                return ggml_cont(ctx->ggml_ctx, v);
            };

            // ehs[0..47] = caption_proj(i)(llama[LL[i]]); ehs[48] = proj(t5).
            std::vector<ggml_tensor*> ehs(n_cap + 1);
            for (int i = 0; i < n_cap; i++)
                ehs[i] = caption_proj(i)->forward(ctx, llama_layer(LL[i]));
            ehs[n_cap] = caption_proj(n_cap)->forward(ctx, t5);

            // initial = cat([ehs[-1]=t5 , ehs[-2]=proj47(L31)], seq); it is a
            // RUNNING stream updated through every double block (sliced back
            // to its original prefix length each iteration).
            auto initial     = ggml_concat(ctx->ggml_ctx, ehs[n_cap], ehs[n_cap - 1], 1);
            int64_t init_len = initial->ne[1];

            for (int i = 0; i < n_double; i++) {
                auto block = std::dynamic_pointer_cast<DoubleStreamBlock>(
                    blocks["double_stream_blocks." + std::to_string(i) + ".block"]);
                auto cur_enc = ggml_concat(ctx->ggml_ctx, initial, ehs[i], 1);  // [initial ; cur_llama]
                auto r       = block->forward(ctx, img, cur_enc, vec, pe, mask);
                img          = r.first;
                initial      = ggml_cont(ctx->ggml_ctx,
                                         ggml_view_3d(ctx->ggml_ctx, r.second, r.second->ne[0],
                                                      init_len, r.second->ne[2],
                                                      r.second->nb[1], r.second->nb[2], 0));
                if (i == 0 && capture == "dbl0") return ggml_cont(ctx->ggml_ctx, img);
            }

            int64_t image_len = img->ne[1];
            img               = ggml_concat(ctx->ggml_ctx, img, initial, 1);  // fuse image + running text
            int64_t hs_len    = img->ne[1];

            for (int i = 0; i < n_single; i++) {
                auto block = std::dynamic_pointer_cast<SingleStreamBlock>(
                    blocks["single_stream_blocks." + std::to_string(i) + ".block"]);
                img        = ggml_concat(ctx->ggml_ctx, img, ehs[n_double + i], 1);  // append cur_llama
                img        = block->forward(ctx, img, vec, pe, mask);
                img        = ggml_cont(ctx->ggml_ctx,
                                       ggml_view_3d(ctx->ggml_ctx, img, img->ne[0], hs_len,
                                                    img->ne[2], img->nb[1], img->nb[2], 0));
            }
            img = ggml_cont(ctx->ggml_ctx,
                            ggml_view_3d(ctx->ggml_ctx, img, img->ne[0], image_len,
                                         img->ne[2], img->nb[1], img->nb[2], 0));
            if (capture == "sgl31") return img;

            img = final_layer->forward(ctx, img, vec);  // [P*P*out_ch, T, N], diffusers (p1,p2,C) C-fastest
            if (capture == "final") return ggml_cont(ctx->ggml_ctx, img);
            // Inverse of the input feature-order remap: diffusers final_layer
            // emits (p1,p2,C) C-fastest; DiT::unpatchify_and_crop expects
            // sd.cpp's (C,p1,p2) C-slowest. ne0 fastest→slowest is [C,pw,ph]
            // → reorder to [pw,ph,C] before unpatchify.
            {
                int64_t T = img->ne[1], Nb = img->ne[2];
                auto r = ggml_reshape_4d(ctx->ggml_ctx, img, Cv, P, P, T * Nb);  // [C,pw,ph,T*N]
                r = ggml_cont(ctx->ggml_ctx, ggml_permute(ctx->ggml_ctx, r, 2, 0, 1, 3));  // ne=[pw,ph,C,T*N]
                img = ggml_reshape_3d(ctx->ggml_ctx, r, Cv * P * P, T, Nb);  // [P*P*C, T, N], C-slowest
            }
            img = DiT::unpatchify_and_crop(ctx->ggml_ctx, img, H, W, P, P);
            return img;
        }
    };

    // Step-5 validation: write `t` in the exact binary layout
    // `sd::load_tensor_from_file_as_tensor` (tensor_ggml.hpp) reads, so
    // reference inputs and sd.cpp captures share one format. Header:
    // int32 n_dims, int32 name_len, int32 ggml_type(0=f32),
    // int32 dims[n_dims] in sd::Tensor order (== ggml ne order, i.e. the
    // REVERSE of numpy/torch .shape), char name[name_len], raw f32 data.
    // The dim order is written as-is here (already sd order); the Python
    // reference side must reverse its numpy shape — see README step 5.
    static inline void dump_f32(const std::string& path, const sd::Tensor<float>& t) {
        std::ofstream f(path, std::ios::binary);
        if (!f) { LOG_ERROR("dump_f32: cannot open %s", path.c_str()); return; }
        auto shape       = t.shape();  // sd order (= ggml ne order)
        int32_t n_dims   = static_cast<int32_t>(shape.size());
        int32_t name_len = 0;
        int32_t ttype    = 0;  // GGML_TYPE_F32
        f.write(reinterpret_cast<const char*>(&n_dims), 4);
        f.write(reinterpret_cast<const char*>(&name_len), 4);
        f.write(reinterpret_cast<const char*>(&ttype), 4);
        for (int i = 0; i < n_dims; i++) {
            int32_t d = static_cast<int32_t>(shape[static_cast<size_t>(i)]);
            f.write(reinterpret_cast<const char*>(&d), 4);
        }
        f.write(reinterpret_cast<const char*>(t.values().data()),
                static_cast<std::streamsize>(t.numel() * sizeof(float)));
    }

    struct HiDreamI1Runner : public GGMLRunner {
        HiDreamI1Params params;
        HiDreamI1 model;
        std::vector<float> pe_vec;
        std::string capture_stage;  // Step-5 only; "" in normal use

        HiDreamI1Runner(ggml_backend_t backend,
                        ggml_backend_t params_backend,
                        const String2TensorStorage& tensor_storage_map = {},
                        const std::string& prefix                      = "model.diffusion_model")
            : GGMLRunner(backend, params_backend), params(make_hidream_i1_params()) {
            model = HiDreamI1(params);
            model.init(params_ctx, tensor_storage_map, prefix);
        }

        std::string get_desc() override { return "hidream_i1"; }

        void get_param_tensors(std::map<std::string, ggml_tensor*>& tensors, const std::string& prefix) {
            model.get_param_tensors(tensors, prefix);
        }

        ggml_cgraph* build_graph(const sd::Tensor<float>& x_t,
                                 const sd::Tensor<float>& timesteps_t,
                                 const sd::Tensor<float>& t5_t,
                                 const sd::Tensor<float>& llama_t,
                                 const sd::Tensor<float>& pooled_t) {
            ggml_cgraph* gf = new_graph_custom(HIDREAM_I1_GRAPH_SIZE);
            auto x          = make_input(x_t);
            auto timesteps  = make_input(timesteps_t);
            auto t5         = make_input(t5_t);
            auto llama      = make_input(llama_t);
            auto pooled     = make_input(pooled_t);

            int64_t n_img = (x->ne[0] / params.patch_size) * (x->ne[1] / params.patch_size);
            // diffusers txt_ids length = ehs[-1].seq + ehs[-2].seq +
            // ehs[0].seq = t5_tok + llama_tok + llama_tok (T5 + L31 +
            // one llama layer). All llama layers share ne[1] (= per-layer
            // token count, unaffected by the ne0 hidden-state stacking).
            int64_t n_txt = t5->ne[1] + 2 * llama->ne[1];

            // Joint RoPE. txt_arange_dims={} → gen_flux_txt_ids leaves text
            // positions all-zero (== diffusers HiDream txt_ids = zeros);
            // image tokens get the 2D grid (axes [64,32,32], θ=10000).
            pe_vec = Rope::gen_flux_pe(static_cast<int>(x->ne[1]),
                                       static_cast<int>(x->ne[0]),
                                       params.patch_size,
                                       static_cast<int>(x->ne[3]),
                                       static_cast<int>(n_txt),
                                       {},
                                       {},
                                       false,
                                       1.f,
                                       params.theta,
                                       false,
                                       false,
                                       params.axes_dim);
            // gen_flux_ids emits [txt ; img] (Flux order), but HiDream's
            // sequence is [img ; txt] (diffusers ids=cat(img_ids,txt_ids),
            // attn=cat(q_i,q_t)). Reorder the per-position pe blocks to
            // image-first so each rotary position lands on its matching
            // token. (txt positions are identity, so only the img/txt split
            // matters.) Without this every token gets the wrong rotary →
            // attention spatial scramble → pure noise.
            {
                size_t per_pos   = static_cast<size_t>(params.axes_dim_sum / 2) * 2 * 2;
                int    total_pos = static_cast<int>(pe_vec.size() / per_pos);
                int    n_txt_i   = static_cast<int>(n_txt);
                int    n_img_i   = total_pos - n_txt_i;
                if (n_img_i > 0 && n_txt_i > 0) {
                    std::vector<float> ro(pe_vec.size());
                    std::copy(pe_vec.begin() + (size_t)n_txt_i * per_pos,
                              pe_vec.begin() + (size_t)total_pos * per_pos, ro.begin());
                    std::copy(pe_vec.begin(),
                              pe_vec.begin() + (size_t)n_txt_i * per_pos,
                              ro.begin() + (size_t)n_img_i * per_pos);
                    pe_vec.swap(ro);
                }
            }
            int pos_len = static_cast<int>(pe_vec.size() / params.axes_dim_sum / 2);
            auto pe     = ggml_new_tensor_4d(compute_ctx, GGML_TYPE_F32, 2, 2,
                                             params.axes_dim_sum / 2, pos_len);
            set_backend_tensor_data(pe, pe_vec.data());

            model.capture   = capture_stage;
            auto runner_ctx = get_context();
            auto out        = model.forward(&runner_ctx, x, timesteps, t5, llama, pooled, pe, nullptr);
            ggml_build_forward_expand(gf, out);
            return gf;
        }

        sd::Tensor<float> compute(int n_threads,
                                  const sd::Tensor<float>& x,
                                  const sd::Tensor<float>& timesteps,
                                  const sd::Tensor<float>& t5,
                                  const sd::Tensor<float>& llama,
                                  const sd::Tensor<float>& pooled) {
            // HiDream-I1 needs all FOUR text encoders. 48 of 49
            // caption_projection inputs (+ the running text stream) come from
            // Llama-3.1-8B (`--llm`); cross-attn from T5-XXL (`--t5xxl`); the
            // pooled modulation `c_vector` from CLIP-L+CLIP-G
            // (`--clip_l`/`--clip_g`) — get_learned_condition only sets
            // c_vector when BOTH CLIPs load. With any of these missing the
            // conditioner emits a 0-dim tensor and the wrapper passes it here,
            // which would abort deep in make_ggml_tensor (tensor_ggml.hpp:67)
            // with an opaque assert. Fail early with an actionable message.
            if (llama.dim() == 0 || t5.dim() == 0 || pooled.dim() == 0) {
                // LOG_ERROR (flushed) before the throw — an uncaught C++
                // exception out of the C-API generate_image() becomes a
                // no-flush std::terminate/abort, so the throw's what() never
                // reaches the user; the log line guarantees the reason is
                // visible.
                LOG_ERROR("HiDream-I1 requires the --t5xxl, --llm, --clip_l and "
                          "--clip_g encoders. Missing: %s%s%s. Pass --llm "
                          "<Llama-3.1-8B-Instruct GGUF> (feeds 48/49 caption "
                          "projections + the running text stream), --t5xxl "
                          "<T5-XXL>, and --clip_l <CLIP-L> --clip_g <CLIP-G> "
                          "(pooled c_vector — both required).",
                          llama.dim() == 0 ? "--llm " : "",
                          t5.dim() == 0 ? "--t5xxl " : "",
                          pooled.dim() == 0 ? "--clip_l/--clip_g" : "");
                throw std::runtime_error("HiDream-I1: missing required text encoder (see log)");
            }
            auto get_graph = [&]() { return build_graph(x, timesteps, t5, llama, pooled); };
            auto out = restore_trailing_singleton_dims(
                GGMLRunner::compute<float>(get_graph, n_threads, false), x.dim());
            // ROOT-CAUSE FIX (Task #12, the residual pure-noise bug). diffusers'
            // HiDream pipeline NEGATES the transformer output before handing it
            // to the FlowMatchEuler scheduler (pipeline_hidream_image.py:1004
            // `noise_pred = -noise_pred`, verified in the installed diffusers,
            // not guessed). sd.cpp's transformer is bit-faithful to diffusers'
            // RAW (pre-negation) output — Step-5's transformer-isolation cos
            // 0.99995 and the bit-exact unpatchify check both confirm this —
            // but the shared FluxFlowDenoiser then computes denoised = x −
            // σ·model_out (FLUX_FLOW_PRED c_out = −σ), i.e. it assumes the
            // Flux sign convention. HiDream-I1 uses the opposite sign, so
            // without this negation every euler step integrates the velocity
            // the WRONG way and the latent never leaves the noise manifold →
            // pure RGB static (empirically: x₀+v₀ has spatial-corr 0.978 — a
            // clean latent — while sd.cpp's x₀−v₀ is corr 0.03 noise; see
            // tools/flow_dir_check.py). Negate ONLY here in the production
            // path; compute_capture() below must keep returning the raw
            // transformer output so Step-5 stays a faithful oracle. Lives in
            // this copied-in header ⇒ zero wiring.patch growth, and is
            // HiDream-I1-specific by construction (Flux is untouched).
            return out * -1.0f;
        }

        // Step-5: run one forward and return the raw `stage` activation
        // (no unpatchify / no dim restore), for diffing vs a diffusers hook.
        sd::Tensor<float> compute_capture(int n_threads,
                                          const sd::Tensor<float>& x,
                                          const sd::Tensor<float>& timesteps,
                                          const sd::Tensor<float>& t5,
                                          const sd::Tensor<float>& llama,
                                          const sd::Tensor<float>& pooled,
                                          const std::string& stage) {
            capture_stage  = stage;
            auto get_graph = [&]() { return build_graph(x, timesteps, t5, llama, pooled); };
            auto out       = GGMLRunner::compute<float>(get_graph, n_threads, false);
            capture_stage.clear();
            return out.has_value() ? std::move(out.value()) : sd::Tensor<float>();
        }

        // Dev driver (mirrors Flux::load_from_file_and_test). Loads the
        // diffusion GGUF + fixed inputs `<io_dir>/{x,timestep,t5,llama,
        // pooled}.bin` (written by tools/hidream_i1_ref.py), runs one forward
        // capturing `stage`, prints stats and dumps `<io_dir>/sdcpp_<stage>.bin`
        // for the numpy compare. `stage` in {x_emb,dbl0,sgl31,final,""}
        // ("" = full image). See sdcpp-patches/hidream-i1/README.md step 5.
        // Step-5 smoke test: run the transformer on the REAL GGUF weights with
        // synthetic deterministic inputs (no encoders / no .bin / no reference
        // needed). Verifies the whole ggml graph (patchify, MoE joint-attn
        // double/single blocks, caption_projection, RoPE, final_layer) builds
        // and EXECUTES, producing finite output of the expected shape. This is
        // execution validation, NOT numerical-fidelity validation.
        static void smoke_test(const std::string& diffusion_gguf,
                               const std::string& stage = "") {
            ggml_backend_t backend = ggml_backend_cpu_init();
            ModelLoader ml;
            if (!ml.init_from_file_and_convert_name(diffusion_gguf, "model.diffusion_model.")) {
                LOG_ERROR("hidream_i1 smoke: load failed '%s'", diffusion_gguf.c_str());
                return;
            }
            auto& tsm = ml.get_tensor_storage_map();
            fprintf(stderr, "[SMOKE] gguf tensors=%zu\n", tsm.size());
            auto runner = std::make_shared<HiDreamI1Runner>(backend, backend, tsm, "model.diffusion_model");
            runner->alloc_params_buffer();
            std::map<std::string, ggml_tensor*> tensors;
            runner->get_param_tensors(tensors, "model.diffusion_model");
            fprintf(stderr, "[SMOKE] model expects %zu param tensors\n", tensors.size());
            // Name-match diagnostic: how many of the model's expected tensor
            // names are actually present in the GGUF storage map.
            {
                size_t hit = 0;
                std::string first_miss;
                for (auto& kv : tensors) {
                    if (tsm.find(kv.first) != tsm.end()) hit++;
                    else if (first_miss.empty()) first_miss = kv.first;
                }
                fprintf(stderr, "[SMOKE] name-match: %zu/%zu present in GGUF; first miss: %s\n",
                        hit, tensors.size(), first_miss.empty() ? "(none)" : first_miss.c_str());
            }
            bool loaded = ml.load_tensors(tensors);
            fprintf(stderr, "[SMOKE] load_tensors -> %s\n", loaded ? "true" : "FALSE");
            if (!loaded) return;
            HiDreamI1Params p;
            auto ramp = [](std::vector<int64_t> shp) {
                sd::Tensor<float> t(shp);
                auto& v = const_cast<std::vector<float>&>(t.values());
                for (size_t i = 0; i < v.size(); i++)
                    v[i] = std::sin(0.001f * static_cast<float>(i)) * 0.1f;  // small, deterministic, finite
                return t;
            };
            int W = 16, H = 16, n_t5 = 8, n_ll = 8;  // tiny -> fast on CPU
            // sd::Tensor shape is ggml ne order (ne0 first), cf. Flux::test()
            // using x({W,H,C,N}).
            auto x      = ramp({W, H, p.vae_channels, 1});
            auto ts     = sd::Tensor<float>({1}, std::vector<float>{0.5f});
            auto t5     = ramp({p.caption_in, n_t5, 1});
            auto llama  = ramp({p.caption_in, n_ll, 1});
            auto pooled = ramp({p.pooled_in, 1});
            LOG_INFO("hidream_i1 smoke: x=%dx%dx%lld t5=%d llama=%d stage=%s",
                     W, H, (long long)p.vae_channels, n_t5, n_ll,
                     stage.empty() ? "(full image)" : stage.c_str());
            int64_t t0 = ggml_time_ms();
            auto out   = runner->compute_capture(8, x, ts, t5, llama, pooled, stage);
            int64_t t1 = ggml_time_ms();
            if (out.empty()) {
                fprintf(stderr, "[SMOKE] stage=%s : *** EMPTY output (graph compute failed) ***\n",
                        stage.empty() ? "image" : stage.c_str());
                return;
            }
            const auto& v = out.values();
            size_t nan = 0, inf = 0;
            double mn = 1e30, mx = -1e30, sum = 0;
            for (float f : v) {
                if (std::isnan(f)) nan++;
                else if (std::isinf(f)) inf++;
                else { mn = std::min(mn, (double)f); mx = std::max(mx, (double)f); sum += f; }
            }
            auto shp = out.shape();
            std::string shps;
            for (size_t i = 0; i < shp.size(); i++) shps += (i ? "x" : "") + std::to_string(shp[i]);
            fprintf(stderr,
                    "[SMOKE] stage=%s shape=[%s] numel=%zu nan=%zu inf=%zu "
                    "min=%.4g max=%.4g mean=%.4g  %s  (%lldms)\n",
                    stage.empty() ? "image" : stage.c_str(), shps.c_str(),
                    v.size(), nan, inf, mn, mx, v.empty() ? 0.0 : sum / v.size(),
                    (nan == 0 && inf == 0) ? "FINITE-OK" : "*** NON-FINITE ***",
                    (long long)(t1 - t0));
        }

        static void load_from_file_and_test(const std::string& diffusion_gguf,
                                            const std::string& io_dir,
                                            const std::string& stage = "") {
            ggml_backend_t backend = ggml_backend_cpu_init();
            ModelLoader ml;
            if (!ml.init_from_file_and_convert_name(diffusion_gguf, "model.diffusion_model.")) {
                LOG_ERROR("hidream_i1 test: load failed '%s'", diffusion_gguf.c_str());
                return;
            }
            auto& tsm   = ml.get_tensor_storage_map();
            auto runner = std::make_shared<HiDreamI1Runner>(backend, backend, tsm, "model.diffusion_model");
            runner->alloc_params_buffer();
            std::map<std::string, ggml_tensor*> tensors;
            runner->get_param_tensors(tensors, "model.diffusion_model");
            if (!ml.load_tensors(tensors)) {
                LOG_ERROR("hidream_i1 test: load_tensors failed");
                return;
            }
            auto L = [&](const char* n) {
                return sd::load_tensor_from_file_as_tensor<float>(io_dir + "/" + std::string(n) + ".bin");
            };
            auto x = L("x"), ts = L("timestep"), t5 = L("t5"), llama = L("llama"), pooled = L("pooled");
            int64_t t0  = ggml_time_ms();
            auto out    = runner->compute_capture(8, x, ts, t5, llama, pooled, stage);
            int64_t t1  = ggml_time_ms();
            GGML_ASSERT(!out.empty());
            print_sd_tensor(out, false, ("hidream_i1[" + stage + "]").c_str());
            dump_f32(io_dir + "/sdcpp_" + (stage.empty() ? "image" : stage) + ".bin", out);
            LOG_INFO("hidream_i1 test done in %lldms", (long long)(t1 - t0));
        }
    };

    // 4-encoder conditioner: CLIP-L + CLIP-G (pooled vector) + T5-XXL +
    // Llama-3.1-8B (all hidden states). caption_projection lives in the
    // transformer, so this just produces the four encoder outputs:
    //   c_vector            = [CLIP-L pooled ; CLIP-G pooled]   (2048)
    //   c_crossattn         = T5-XXL last hidden                (4096 x n_txt)
    //   extra_c_crossattns  = Llama-3.1 all hidden states stacked
    struct HiDreamI1Conditioner : public Conditioner {
        CLIPTokenizer clip_l_tokenizer;
        CLIPTokenizer clip_g_tokenizer;
        T5UniGramTokenizer t5_tokenizer;
        std::shared_ptr<CLIPTextModelRunner> clip_l;
        std::shared_ptr<CLIPTextModelRunner> clip_g;
        std::shared_ptr<T5Runner> t5;
        // LLMEmbedder bundles the tokenizer + LLMRunner; LLAMA3 params are
        // derived from the arch inside LLMRunner's ctor.
        std::shared_ptr<LLM::LLMEmbedder> llama;
        // ROOT-CAUSE FIX (Task #5/#6): LLMEmbedder hands LLMArch::LLAMA3 a
        // Qwen2Tokenizer (vocab 151936) whose IDs overflow Llama-3.1's 128256
        // embed_tokens -> get_rows OOB crash / pure-noise. When set, the llama
        // branch tokenises with this GGUF-derived Llama-3.1 BPE instead
        // (IDs index embed_tokens 1:1 by construction). Populated from the
        // --llm GGUF path; see set_llama3_tokenizer / llama3_tokenizer.hpp.
        std::shared_ptr<Llama3Tokenizer> llama3_tok;

        HiDreamI1Conditioner(ggml_backend_t backend,
                             ggml_backend_t params_backend,
                             const String2TensorStorage& tensor_storage_map = {})
            : clip_g_tokenizer(0) {
            for (auto& pair : tensor_storage_map) {
                const std::string& n = pair.first;
                if (n.find("text_encoders.clip_l") != std::string::npos && !clip_l) {
                    clip_l = std::make_shared<CLIPTextModelRunner>(backend, params_backend, tensor_storage_map,
                                                                   "text_encoders.clip_l.transformer.text_model",
                                                                   OPENAI_CLIP_VIT_L_14, false);
                } else if (n.find("text_encoders.clip_g") != std::string::npos && !clip_g) {
                    clip_g = std::make_shared<CLIPTextModelRunner>(backend, params_backend, tensor_storage_map,
                                                                   "text_encoders.clip_g.transformer.text_model",
                                                                   OPEN_CLIP_VIT_BIGG_14, false);
                } else if (n.find("text_encoders.t5xxl") != std::string::npos && !t5) {
                    t5 = std::make_shared<T5Runner>(backend, params_backend, tensor_storage_map,
                                                    "text_encoders.t5xxl.transformer");
                } else if (n.find("text_encoders.llm") != std::string::npos && !llama) {
                    // Upstream sd.cpp loads the `--llm` encoder under the
                    // `text_encoders.llm.` prefix (stable-diffusion.cpp:307)
                    // and every LLM consumer constructs LLM:: with the prefix
                    // string "text_encoders.llm" (conditioner.hpp:1572/1707/
                    // 2122 — no trailing dot, no `.transformer`). The earlier
                    // `text_encoders.llama[.transformer]` here never matched
                    // the flag's actual prefix, so the Llama encoder could
                    // never bind. Aligned to the upstream convention.
                    llama = std::make_shared<LLM::LLMEmbedder>(LLM::LLMArch::LLAMA3, backend, params_backend,
                                                               tensor_storage_map,
                                                               "text_encoders.llm", false);
                }
            }
        }

        void get_param_tensors(std::map<std::string, ggml_tensor*>& tensors) override {
            if (clip_l) clip_l->get_param_tensors(tensors, "text_encoders.clip_l.transformer.text_model");
            if (clip_g) clip_g->get_param_tensors(tensors, "text_encoders.clip_g.transformer.text_model");
            if (t5) t5->get_param_tensors(tensors, "text_encoders.t5xxl.transformer");
            if (llama) llama->get_param_tensors(tensors, "text_encoders.llm");
        }
        void alloc_params_buffer() override {
            if (clip_l) clip_l->alloc_params_buffer();
            if (clip_g) clip_g->alloc_params_buffer();
            if (t5) t5->alloc_params_buffer();
            if (llama) llama->model.alloc_params_buffer();
        }
        void free_params_buffer() override {
            if (clip_l) clip_l->free_params_buffer();
            if (clip_g) clip_g->free_params_buffer();
            if (t5) t5->free_params_buffer();
            if (llama) llama->model.free_params_buffer();
        }
        size_t get_params_buffer_size() override {
            size_t s = 0;
            if (clip_l) s += clip_l->get_params_buffer_size();
            if (clip_g) s += clip_g->get_params_buffer_size();
            if (t5) s += t5->get_params_buffer_size();
            if (llama) s += llama->model.get_params_buffer_size();
            return s;
        }
        void set_flash_attention_enabled(bool e) override {
            if (clip_l) clip_l->set_flash_attention_enabled(e);
            if (clip_g) clip_g->set_flash_attention_enabled(e);
            if (t5) t5->set_flash_attention_enabled(e);
            if (llama) llama->model.set_flash_attention_enabled(e);
        }

        SDCondition get_learned_condition(int n_threads,
                                          const ConditionerParams& cp) override {
            // FIDELITY: RESOLVED via the 2026-05-18/19 reference run. Token
            // padding lengths (CLIP-L = checkpoint n_token / 248, CLIP-G 77,
            // T5 128, Llama 128), the Llama-3.1 tokenizer + chat template
            // (llama3_tokenizer.hpp; add_bos_token=false, PAD=BOS), and which
            // Llama hidden states caption_projection consumes (llama_layers =
            // [0..31, 31×16]) are all pinned to the reference. Only residual
            // measured item: Llama pad-position hidden states ~2.9× (memory
            // `hidream-i1-llama-encoder-bug-measured`) — minor, not structural.
            SDCondition result;
            // Task #11 — ref-driven full-sampler isolation (dev only; inert
            // unless the env var is set, so byte-identical to a normal run).
            // HIDREAM_I1_INJECT_COND=<io_dir>: bypass ALL FOUR encoders and
            // return the authoritative diffusers conditioning captured by
            // tools/hidream_i1_ref.py (<io_dir>/{t5,llama,pooled}.bin — the
            // exact tensors Step-5's transformer-isolation already proved
            // faithful, final-latent cos 0.99995). The REAL sampler +
            // FluxFlow denoiser + VAE then run completely unchanged, so the
            // output image is a clean binary oracle: COHERENT => the residual
            // pure-noise bug is 100% inside THIS conditioner (chase the
            // ~0.49 |sd|/|ref| llama norm ratio); PURE STATIC => the bug is
            // in the real sampler/CFG/flow loop that Step-5's single forward
            // never exercised. Text conditioning is step-invariant, so one
            // capture validly drives every sampler step. The reference was
            // captured at guidance_scale=1.0 -> run sd-cli with --cfg-scale
            // 1.0 (no negative embedding is captured/needed). Lives entirely
            // in this copied-in header => zero wiring.patch growth.
            if (const char* inj = getenv("HIDREAM_I1_INJECT_COND")) {
                std::string dir(inj);
                auto LD = [&](const char* n) {
                    return sd::load_tensor_from_file_as_tensor<float>(
                        dir + "/" + std::string(n) + ".bin");
                };
                result.c_crossattn = LD("t5");
                result.extra_c_crossattns.push_back(LD("llama"));
                result.c_vector = LD("pooled");
                LOG_INFO("HiDreamI1: INJECTED diffusers conditioning from "
                         "'%s' (t5/llama/pooled) — all 4 encoders bypassed "
                         "(Task #11 full-sampler isolation)", dir.c_str());
                return result;
            }
            auto on_tok = [&](std::string&, std::vector<int32_t>&) -> bool { return false; };

            sd::Tensor<float> pooled_l, pooled_g;
            if (clip_l) {
                auto toks = clip_l_tokenizer.encode(cp.text, on_tok);
                // CLIP forward asserts input_ids->ne[0] == position_embedding
                // length (clip.hpp:167) — an EXACT match, not <=. Pad to the
                // model's OWN position window: HiDream-I1's CLIP-L is the
                // long-context 248-pos CLIPTextModelWithProjection, whereas
                // CLIP-G stays the standard 77. clip.hpp's init_params sets
                // model.n_token from the checkpoint's position table, so this
                // tracks whichever CLIP variant the user supplied.
                const int clip_l_npos = clip_l->model.n_token;
                clip_l_tokenizer.pad_tokens(toks, nullptr, nullptr, clip_l_npos, clip_l_npos, true);
                sd::Tensor<int32_t> ids({(int64_t)toks.size()}, toks);
                auto it     = std::find(toks.begin(), toks.end(), clip_l_tokenizer.EOS_TOKEN_ID);
                size_t mtok = std::min<size_t>(std::distance(toks.begin(), it), toks.size() - 1);
                pooled_l    = clip_l->compute(n_threads, ids, 0, nullptr, mtok, true, 2);
            }
            if (clip_g) {
                auto toks = clip_g_tokenizer.encode(cp.text, on_tok);
                const int clip_g_npos = clip_g->model.n_token;  // see clip_l note (normally 77)
                clip_g_tokenizer.pad_tokens(toks, nullptr, nullptr, clip_g_npos, clip_g_npos, true);
                sd::Tensor<int32_t> ids({(int64_t)toks.size()}, toks);
                auto it     = std::find(toks.begin(), toks.end(), clip_g_tokenizer.EOS_TOKEN_ID);
                size_t mtok = std::min<size_t>(std::distance(toks.begin(), it), toks.size() - 1);
                pooled_g    = clip_g->compute(n_threads, ids, 0, nullptr, mtok, true, 2);
            }
            if (!pooled_l.empty() && !pooled_g.empty()) {
                result.c_vector = sd::ops::concat(pooled_l, pooled_g, 0);
            }

            if (t5) {
                auto toks = t5_tokenizer.encode(cp.text);
                // HiDream's diffusers pipeline tokenizes T5 with
                // max_length=128, padding="max_length" (T5 has no learned
                // position table so the missing pad never asserted, but
                // min_length=0 left it unpadded and non-reference-faithful).
                // CRITICAL (Task #7, pure-noise critical path): diffusers'
                // _get_t5_prompt_embeds passes attention_mask into the
                // BIDIRECTIONAL T5 encoder. With an empty mask the 121
                // right-pad tokens leak into every real-token hidden state ->
                // sdcpp_t5 vs val/t5.bin cos~0.10 -> the denoiser gets garbage
                // cross-attention -> pure RGB noise even after the Llama
                // tokenizer/crash fix. Build the padding mask exactly as the
                // proven upstream T5 path does (conditioner.hpp:1464-1525):
                // pad_tokens fills >0 for real / <=0 for pad; map real->0,
                // pad->-inf; pass the 1-D [n_token] additive mask (T5's
                // SelfAttention ggml_repeats it across query/key/heads).
                std::vector<float> t5_mask;
                t5_tokenizer.pad_tokens(toks, nullptr, &t5_mask, 128, 128, true);
                for (auto& m : t5_mask) {
                    m = m > 0.0f ? 0.0f : -INFINITY;
                }
                sd::Tensor<int32_t> ids({(int64_t)toks.size()}, toks);
                sd::Tensor<float> t5_attn_mask({(int64_t)t5_mask.size()}, t5_mask);
                result.c_crossattn = t5->compute(n_threads, ids, t5_attn_mask);
            }

            if (llama) {
                std::vector<int> toks;
                if (llama3_tok && llama3_tok->ok) {
                    // Reference-faithful Llama-3.1 path (the fix). encode() +
                    // pad_tokens(128,128) with add_bos_token honours diffusers'
                    // padding="max_length"/max_length=128/truncation/
                    // add_special_tokens=True exactly; IDs index embed_tokens
                    // 1:1 so get_rows can no longer go OOB.
                    toks = llama3_tok->tokenize(cp.text, nullptr,
                                                /*padding=*/true,
                                                /*min_length=*/128,
                                                /*max_length=*/128,
                                                /*allow_overflow_expand=*/false);
                } else {
                    // Legacy (BROKEN for Llama-3.1: LLMEmbedder's Qwen2
                    // tokenizer — kept only as a fallback when no GGUF
                    // tokenizer is available; see llama3_tok docs).
                    auto tw = llama->tokenize(cp.text, {0, (int)cp.text.size()}, 128, true);
                    toks    = std::get<0>(tw);
                }
                sd::Tensor<int32_t> ids({(int64_t)toks.size()}, toks);
                // CRITICAL (measured 2026-05-19, conditioner-isolation diff):
                // diffusers _get_llama3_prompt_embeds passes the tokenizer
                // attention_mask into the (causal) Llama-3.1; sd.cpp's
                // LLMRunner builds ONLY a causal mask when none is supplied
                // (llm.hpp:1418-1432), so the ~121 right-pad positions attend
                // to real tokens instead of being masked — ~95% of the 128
                // stack positions then diverge from the reference (llama
                // cos 0.39 / ‖sd‖/‖ref‖ 0.49, vs T5 0.99 which DOES get its
                // pad mask here). Build the combined causal+padding 2-D
                // [n,n] mask exactly as the empty-mask branch's causal fill
                // (index [q*n + k], 0 keep / -INF mask) AND additionally mask
                // pad KEY columns, mirroring the proven T5 path above.
                sd::Tensor<float> llama_mask;
                if (llama3_tok && llama3_tok->ok) {
                    const int64_t n = (int64_t)toks.size();
                    int64_t real_len = n;  // diffusers right-pads with PAD(=EOS)
                    while (real_len > 0 &&
                           toks[(size_t)real_len - 1] == llama3_tok->PAD_TOKEN_ID) {
                        real_len--;
                    }
                    // real_len==0 (an all-pad sequence, e.g. the empty
                    // CFG-negative prompt with add_bos=false) would make every
                    // (k>=real_len) true → an entire -INF row → softmax NaN →
                    // NaN latent → pure-white image. HF avoids this via
                    // AttentionMaskConverter._unmask_unattended (fully-masked
                    // rows are left unmasked); sd.cpp has no such safeguard, so
                    // mirror it: when there are no real tokens, fall back to a
                    // causal-only mask (drop the pad-key term) so no row is
                    // ever fully masked. Non-empty prompts are unaffected.
                    const bool mask_pad_keys = real_len > 0;
                    std::vector<float> m((size_t)(n * n));
                    for (int64_t q = 0; q < n; q++) {
                        for (int64_t k = 0; k < n; k++) {
                            bool masked = (k > q) || (mask_pad_keys && k >= real_len);
                            m[(size_t)(q * n + k)] = masked ? -INFINITY : 0.f;
                        }
                    }
                    llama_mask = sd::Tensor<float>({n, n}, m);
                }
                // return_all_hidden_states = true → LLM::forward_embeds
                // concats all 33 hidden states along ne0 (llm.hpp:870):
                // [embed, L0..L30, norm(L31)] × caption_in. forward()'s
                // authoritative #2 routing slices the per-block layer
                // (HF llama3[k] == stack block 1+k) BEFORE caption_proj, so
                // the 4096-wide matmul is well-formed. (The single-final-
                // tensor stand-in is gone — #2 is implemented.)
                auto h = llama->model.compute(n_threads, ids, llama_mask,
                                              {}, std::set<int>(), true);
                result.extra_c_crossattns.push_back(std::move(h));
            }
            return result;
        }

        // Step-5 conditioner-isolation diff (dev only). Loads the 4 text
        // encoders, runs THIS conditioner on the fixed reference prompt and
        // dumps c_crossattn(T5) / extra_c_crossattns[0](Llama 33-stack) /
        // c_vector(pooled) as sdcpp_{t5,llama,pooled}.bin in the SAME binfmt
        // as tools/hidream_i1_ref.py's val/{t5,llama,pooled}.bin. Step-5's
        // transformer-isolation diff already proved the transformer faithful
        // (final cos 0.99995) and localised the residual pure-noise bug to
        // THIS conditioner; this pinpoints WHICH encoder diverges. Apples-to-
        // apples requires the SAME prompt the reference used (default
        // "a red cube on grass", size 256, seed 42).
        static void dump_conditioner_and_test(const std::string& clip_l_path,
                                              const std::string& clip_g_path,
                                              const std::string& t5_path,
                                              const std::string& llm_path,
                                              const std::string& io_dir,
                                              const std::string& prompt) {
            ggml_backend_t backend = ggml_backend_cpu_init();
            ModelLoader ml;
            // Prefixes mirror stable-diffusion.cpp:276/284/300/307 exactly so
            // the conditioner ctor's tensor_storage_map scan binds each model.
            if (!clip_l_path.empty() &&
                !ml.init_from_file(clip_l_path, "text_encoders.clip_l.transformer."))
                LOG_WARN("hidream cond test: clip_l load failed '%s'", clip_l_path.c_str());
            if (!clip_g_path.empty() &&
                !ml.init_from_file(clip_g_path, "text_encoders.clip_g.transformer."))
                LOG_WARN("hidream cond test: clip_g load failed '%s'", clip_g_path.c_str());
            if (!t5_path.empty() &&
                !ml.init_from_file(t5_path, "text_encoders.t5xxl.transformer."))
                LOG_WARN("hidream cond test: t5xxl load failed '%s'", t5_path.c_str());
            if (!llm_path.empty() &&
                !ml.init_from_file(llm_path, "text_encoders.llm."))
                LOG_WARN("hidream cond test: llm load failed '%s'", llm_path.c_str());

            // The real SD pipeline calls convert_tensors_name() ONCE globally
            // after all encoder init_from_file()s accumulate into one map
            // (plain init_from_file does NOT convert). Without this the
            // llama.cpp GGUF stays `blk.*`/`token_embd.*` and the LLM runner
            // (which wants HF `model.layers.*`/`model.embed_tokens.*`) can't
            // bind — name_conversion.cpp:131 llm_name_map does the mapping.
            ml.convert_tensors_name();

            auto& tsm = ml.get_tensor_storage_map();
            HiDreamI1Conditioner cond(backend, backend, tsm);
            // The fix under test: feed the conditioner the Llama-3.1 BPE built
            // from the --llm GGUF instead of LLMEmbedder's Qwen2 fallback.
            if (!llm_path.empty()) {
                cond.llama3_tok = std::make_shared<Llama3Tokenizer>(llm_path);
            }
            cond.alloc_params_buffer();
            std::map<std::string, ggml_tensor*> tensors;
            cond.get_param_tensors(tensors);
            if (!ml.load_tensors(tensors)) {
                LOG_ERROR("hidream cond test: load_tensors failed");
                return;
            }
            ConditionerParams cp;
            cp.text   = prompt;
            cp.width  = 256;
            cp.height = 256;
            int64_t t0    = ggml_time_ms();
            SDCondition c = cond.get_learned_condition(8, cp);
            int64_t t1    = ggml_time_ms();
            if (!c.c_crossattn.empty()) {
                print_sd_tensor(c.c_crossattn, false, "hidream_cond[t5]");
                dump_f32(io_dir + "/sdcpp_t5.bin", c.c_crossattn);
            }
            if (!c.extra_c_crossattns.empty() && !c.extra_c_crossattns[0].empty()) {
                print_sd_tensor(c.extra_c_crossattns[0], false, "hidream_cond[llama]");
                dump_f32(io_dir + "/sdcpp_llama.bin", c.extra_c_crossattns[0]);
            }
            if (!c.c_vector.empty()) {
                print_sd_tensor(c.c_vector, false, "hidream_cond[pooled]");
                dump_f32(io_dir + "/sdcpp_pooled.bin", c.c_vector);
            }
            LOG_INFO("hidream cond test done in %lldms", (long long)(t1 - t0));
        }
    };

}  // namespace HiDreamI1

#endif  // __SD_HIDREAM_I1_H__
