# vLLM — Qwen3.6-35B-A3B (NVFP4)

Serves `nvidia/Qwen3.6-35B-A3B-NVFP4` on the DGX Spark over an
OpenAI-compatible API at `http://localhost:8000/v1`.

**Nothing starts this for you.** No Ansible role, no systemd unit, no restart
policy. It runs when you run it.

## Why this isn't Ollama

Ollama's CUDA backend is llama.cpp, which speaks GGUF and has no NVFP4
implementation. NVFP4 is a Blackwell-native tensor format consumed by vLLM and
TensorRT-LLM. The `qwen3.6:35b-a3b-nvfp4` tag in Ollama's registry is an MLX
(Apple Silicon) build and fails on this machine with
`this model requires MLX support`.

Ollama stays installed and is still the right tool for everyday interactive
use. This is the specialist path for NVFP4, long context, and tool calling.

## Run it

```bash
docker compose -f workloads/vllm/compose.yaml up -d
docker compose -f workloads/vllm/compose.yaml logs -f
```

Wait for `Application startup complete.` First launch downloads ~21 GB into
`~/.cache/huggingface/hub`.

Verify:

```bash
curl -sS http://localhost:8000/v1/models
```

Test:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/Qwen3.6-35B-A3B-NVFP4",
    "messages": [{"role": "user", "content": "Explain quantum computing simply."}],
    "max_tokens": 2048
  }'
```

Reasoning is enabled, so part of the token budget is spent on a thinking pass
before the answer — keep `max_tokens` generous or replies look truncated.

Stop it:

```bash
docker compose -f workloads/vllm/compose.yaml down
```

## Where the flags come from

They are the verified `dgx_spark_gb10` hardware profile from the vLLM recipe,
copied rather than invented:

<https://recipes.vllm.ai/Qwen/Qwen3.6-35B-A3B?hardware=dgx_spark_gb10&features=tool_calling%2Creasoning>

Two are worth understanding before you touch anything:

- **`--gpu-memory-utilization=0.5`** is Spark-specific and not a typo. Other
  Blackwell profiles use `0.92`; Spark is capped at `0.5` because the GB10
  shares unified memory with the host. On 119 GB that is roughly 60 GB for
  ~21 GB of weights plus KV cache.
- **`vllm/vllm-openai:v0.28.0` is pinned.** NVFP4 needs vLLM >= 0.28.0. Do not
  substitute `:latest`. The tag does publish a `linux/arm64` build — the
  playbook's own troubleshooting lists "missing ARM64 image" as a known Spark
  failure mode, so verify before bumping the pin.

The last three flags (`--enable-auto-tool-choice`, `--tool-call-parser`,
`--reasoning-parser`) are the recipe's `tool_calling` and `reasoning` features.
Hermes needs them; they're harmless otherwise.

## Troubleshooting

**Memory pressure even within capacity.** A known unified-memory quirk. Flush
the buffer cache:

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```

**`nvidia-smi` reports `N/A` for memory.** Expected under unified memory, not a
fault.

**Freeing memory for text-only work.** This is a multimodal model.
`--language-model-only` skips the vision encoder and gives that memory to the
KV cache. Not part of the verified profile, so treat it as tuning.

## Using it with Hermes

Hermes is installed by the `hermes` Ansible role but left unconfigured. Start
this server first, then:

```bash
hermes model    # Custom endpoint → http://localhost:8000/v1 → blank API key
hermes tools    # enable capabilities
```

The model picker lists whatever `/v1/models` reports, so the server must be
running or you'll get an empty list.

## Full cleanup

```bash
docker compose -f workloads/vllm/compose.yaml down
docker rmi vllm/vllm-openai:v0.28.0
rm -rf ~/.cache/huggingface/hub/models--nvidia--Qwen3.6-35B-A3B-NVFP4
```
