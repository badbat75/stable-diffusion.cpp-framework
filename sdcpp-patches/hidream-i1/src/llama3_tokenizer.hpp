#ifndef __SD_HIDREAM_LLAMA3_TOKENIZER_H__
#define __SD_HIDREAM_LLAMA3_TOKENIZER_H__

// Part of the sdcpp-patches/hidream-i1 patch set. Copied verbatim into the
// sd.cpp clone's src/ by sdcpp-patches\patch-lib.ps1 (Invoke-SdCppPatches);
// like hidream_i1.hpp it is NOT part of wiring.patch and is not #included
// anywhere upstream until hidream_i1.hpp pulls it in.
//
// WHY THIS EXISTS (Task #5/#6 root-cause fix):
//   sd.cpp's LLM::LLMEmbedder (llm.hpp:1514-1518) hands every non-Mistral
//   arch -- including LLMArch::LLAMA3 -- a Qwen2Tokenizer. Qwen2's vocab is
//   ~151,936; Llama-3.1's embed_tokens table is 128,256 rows. Qwen2-emitted
//   IDs >= 128256 index past the embedding table -> the quantised get_rows
//   GGML_ASSERT(i01 < ne01) hard-crashes (ggml-cpu/ops.cpp:4699); in-range
//   IDs are simply the wrong tokens -> garbage Llama hidden states -> the
//   HiDream-I1 "pure RGB noise". Step-5 already cleared the transformer
//   (final latent cos 0.99995), so the conditioner's Llama tokeniser is THE
//   bug.
//
//   Fix: tokenise with the Llama-3.1 vocab that is embedded in the GGUF the
//   user already passes via --llm. llama.cpp's Llama-3 conversion stores it
//   as tokenizer.ggml.model="gpt2": byte-level (GPT-2) BPE whose
//   tokenizer.ggml.tokens[i] is the byte<->unicode-mapped string for id i and
//   tokenizer.ggml.merges are the rank-ordered pairs -- exactly what
//   BPETokenizer::encode() consumes. Building encoder/decoder DIRECTLY from
//   the tokens array (index == id) GUARANTEES the produced IDs index
//   embed_tokens 1:1, which is the whole point.

#include <map>
#include <string>
#include <utility>
#include <vector>

#include "gguf.h"
#include "tokenizers/bpe_tokenizer.h"
#include "util.h"  // utf8_to_utf32 / utf32_to_utf8

namespace HiDreamI1 {

class Llama3Tokenizer : public BPETokenizer {
public:
    bool ok = false;

    explicit Llama3Tokenizer(const std::string& gguf_path) {
        byte_level_bpe = true;   // GPT-2 byte-level (same family as Qwen2/CLIP)
        byte_fallback  = false;  // gpt2 model has no <0xNN> byte tokens
        // diffusers HiDreamImagePipeline._get_llama3_prompt_embeds:
        //   tokenizer_4(prompt, padding="max_length", max_length=128,
        //               truncation=True, add_special_tokens=True)
        //   with tokenizer_4.pad_token = tokenizer_4.eos_token.
        // Llama-3's fast tokenizer with add_special_tokens=True prepends BOS
        // only (no trailing EOS, no chat template). pad_tokens() honours
        // these two flags, so [BOS]+ids padded to 128 with PAD(=EOS) and
        // truncated to 128 reproduces it byte-for-byte.
        // Production-faithful: HiDream loads the real (gated)
        // meta-llama-3.1-8B tokenizer, and diffusers calls it with
        // add_special_tokens=True, which prepends BOS(128000) only (no EOS,
        // no chat template — verified vs installed diffusers 0.38.0
        // pipeline_hidream_image.py:_get_llama3_prompt_embeds).
        // Task #9 bisection result (do NOT flip to match val/llama.bin):
        // toggling this off moved llama cos only 0.39->0.49 (no clean
        // 0.39->0.99 snap), so BOS is NOT the dominant divergence; the
        // residual is the missing Llama-3.1 "llama3" RoPE rescaling
        // (llm.hpp:677 FIDELITY TODO — monotonic per-layer cos decay
        // blk1 0.66 -> blk32 0.06). Keep this production-faithful.
        add_bos_token = true;
        add_eos_token = false;

        // Byte<->unicode map: identical to the one BPETokenizer::encode() uses
        // to lift raw input bytes before BPE, and the same space the GGUF
        // token strings live in.
        auto bu      = bytes_to_unicode();
        byte_encoder = std::map<int, std::u32string>(bu.begin(), bu.end());
        for (auto& p : bu) {
            byte_decoder[p.second] = p.first;
        }

        struct gguf_init_params gp = {/*no_alloc=*/true, /*ctx=*/nullptr};
        gguf_context* ctx          = gguf_init_from_file(gguf_path.c_str(), gp);
        if (!ctx) {
            LOG_ERROR("Llama3Tokenizer: gguf_init_from_file failed '%s'", gguf_path.c_str());
            return;
        }

        int64_t k_tok = gguf_find_key(ctx, "tokenizer.ggml.tokens");
        int64_t k_mrg = gguf_find_key(ctx, "tokenizer.ggml.merges");
        int64_t k_typ = gguf_find_key(ctx, "tokenizer.ggml.token_type");
        if (k_tok < 0) {
            LOG_ERROR("Llama3Tokenizer: '%s' has no tokenizer.ggml.tokens "
                      "(not a llama.cpp-converted Llama-3 GGUF?)",
                      gguf_path.c_str());
            gguf_free(ctx);
            return;
        }

        // encoder[token_str] = id ; decoder[id] = token_str. Index == GGUF
        // array position == the embed_tokens row, by construction.
        size_t n = gguf_get_arr_n(ctx, k_tok);
        for (size_t i = 0; i < n; i++) {
            std::u32string t = utf8_to_utf32(gguf_get_arr_str(ctx, k_tok, i));
            encoder[t]       = static_cast<int>(i);
            decoder[static_cast<int>(i)] = t;
        }
        encoder_len = static_cast<int>(n);

        if (k_mrg >= 0) {
            size_t m = gguf_get_arr_n(ctx, k_mrg);
            int rank = 0;
            for (size_t i = 0; i < m; i++) {
                std::string mg = gguf_get_arr_str(ctx, k_mrg, i);
                size_t sp      = mg.find(' ');
                if (sp == std::string::npos) {
                    continue;
                }
                bpe_ranks[{utf8_to_utf32(mg.substr(0, sp)),
                           utf8_to_utf32(mg.substr(sp + 1))}] = rank++;
            }
            bpe_len = rank;
        }

        // Reserved/added tokens (LLAMA_TOKEN_TYPE CONTROL=3, USER_DEFINED=4 --
        // e.g. <|begin_of_text|>=128000, <|eot_id|>=128009). Registering them
        // makes BPETokenizer::encode() isolate them via
        // split_with_special_tokens and map each to its exact GGUF id rather
        // than BPE-splitting the literal text.
        if (k_typ >= 0 && gguf_get_arr_n(ctx, k_typ) == n) {
            const int32_t* tt = static_cast<const int32_t*>(gguf_get_arr_data(ctx, k_typ));
            for (size_t i = 0; i < n; i++) {
                if (tt[i] == 3 || tt[i] == 4) {
                    special_tokens.push_back(gguf_get_arr_str(ctx, k_tok, i));
                }
            }
        }

        auto sid = [&](const char* key, int dflt) -> int {
            int64_t k = gguf_find_key(ctx, key);
            return k >= 0 ? static_cast<int>(gguf_get_val_u32(ctx, k)) : dflt;
        };
        BOS_TOKEN_ID = sid("tokenizer.ggml.bos_token_id", 128000);
        EOS_TOKEN_ID = sid("tokenizer.ggml.eos_token_id", 128001);
        PAD_TOKEN_ID = EOS_TOKEN_ID;
        UNK_TOKEN_ID = EOS_TOKEN_ID;
        if (decoder.count(BOS_TOKEN_ID)) {
            BOS_TOKEN = utf32_to_utf8(decoder[BOS_TOKEN_ID]);
        }
        if (decoder.count(EOS_TOKEN_ID)) {
            EOS_TOKEN = utf32_to_utf8(decoder[EOS_TOKEN_ID]);
        }

        gguf_free(ctx);
        ok = encoder_len > 0;
        LOG_INFO("Llama3Tokenizer: %d tokens, %d merges, %zu special "
                 "(bos=%d eos=%d) from '%s'",
                 encoder_len, bpe_len, special_tokens.size(),
                 BOS_TOKEN_ID, EOS_TOKEN_ID, gguf_path.c_str());
    }
};

}  // namespace HiDreamI1

#endif  // __SD_HIDREAM_LLAMA3_TOKENIZER_H__
