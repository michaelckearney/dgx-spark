# vLLM — Qwen3.6-35B-A3B (NVFP4)

What this model is, and why its flags are what they are.

`nvidia/Qwen3.6-35B-A3B-NVFP4` is served on the DGX Spark over an
OpenAI-compatible API. **You don't start it — the gateway does.** Its lifecycle
belongs to llama-swap, which starts the container on demand when something asks
for this model by name and holds the request until it's ready. The endpoint is
unchanged at `http://localhost:8000/v1`; see
[`../llama-swap/README.md`](../llama-swap/README.md).

The flag list lives once, in
[`../llama-swap/config.yaml`](../llama-swap/config.yaml). This file is where
the flags are *explained*.

This model can die mid-request — it once hit `CUBLAS_STATUS_INTERNAL_ERROR`
after ~13h and the API server shut itself down cleanly. The gateway is what
makes that survivable: it relaunches on the next request and holds that
request until the model is ready. See
[The one daemon](../../README.md#the-one-daemon).

## Why this isn't Ollama

Ollama's CUDA backend is llama.cpp, which speaks GGUF and has no NVFP4
implementation. NVFP4 is a Blackwell-native tensor format consumed by vLLM and
TensorRT-LLM. The `qwen3.6:35b-a3b-nvfp4` tag in Ollama's registry is an MLX
(Apple Silicon) build and fails on this machine with
`this model requires MLX support`.

Ollama stays installed and is still the right tool for everyday interactive
use. This is the specialist path for NVFP4, long context, and tool calling.

## Use it

Just ask for it by name. The gateway starts it if it isn't running:

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

The first such request after a boot pays the load: a few minutes, held open by
the gateway. Warm it deliberately before an overnight run so that wait happens
once, where you can watch it. Free the memory again with
`curl -X POST http://localhost:8000/api/models/unload`.

### First run: pull the weights by hand

A cold start downloads **21.85 GiB** (three safetensors shards) into
`~/.cache/huggingface/hub`, then loads and compiles — the compile phase is
silent and takes several minutes. **The gateway is deliberately not sized for
that**, so do it once, by hand, before relying on the model:

```bash
docker run --rm --init --name vllm-qwen3-35b \
  --gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 \
  -p 127.0.0.1:5800:8000 \
  -v "$HOME/.cache/huggingface/hub:/root/.cache/huggingface/hub" \
  --entrypoint vllm vllm/vllm-openai:v0.28.0 \
  serve nvidia/Qwen3.6-35B-A3B-NVFP4 --trust-remote-code \
  --kv-cache-dtype=fp8 --attention-backend=flashinfer --moe-backend=marlin \
  --gpu-memory-utilization=0.5 --max-model-len=262144 --max-num-seqs=8 \
  --max-num-batched-tokens=8192 --enable-chunked-prefill --async-scheduling \
  --enable-prefix-caching --load-format=fastsafetensors \
  --enable-auto-tool-choice --tool-call-parser=qwen3_xml --reasoning-parser=qwen3
```

Watch the download:

```bash
du -sb ~/.cache/huggingface/hub | awk '{printf "%.2f / 21.85 GiB (%.0f%%)\n", $1/1073741824, $1/1073741824/21.85*100}'
```

This is also the **standalone bypass** — the way to run vLLM with no gateway
in the path when you're debugging the model rather than the gateway. It binds
5800, so it doesn't collide with llama-swap on 8000, but it does collide with
a gateway-started container of the same name: unload first.

**"Connection reset by peer" during startup is normal, not an error.** Docker
publishes the port as soon as the container exists, so `docker-proxy` accepts
your TCP connection and then has nothing to forward to until vLLM binds inside
the container. `/health` is what distinguishes the two states, and it is what
the gateway waits on:

```bash
until curl -sf http://127.0.0.1:5800/health; do sleep 5; done
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

**Memory pressure even within capacity.** Check Ollama first — it runs natively
as a systemd service and competes for the same unified memory, and the
gateway's one-model-at-a-time rule only covers *its own* models:

```bash
ollama ps
```

Otherwise it's the known unified-memory quirk. Flush the buffer cache:

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```

**`nvidia-smi` reports `N/A` for memory.** Expected under unified memory, not a
fault.

**Freeing memory for text-only work.** This is a multimodal model.
`--language-model-only` skips the vision encoder and gives that memory to the
KV cache. Not part of the verified profile, so treat it as tuning.

## Using it with Hermes

Hermes is installed by the `hermes` Ansible role but left unconfigured:

```bash
hermes model    # Custom endpoint → http://localhost:8000/v1 → blank API key
hermes tools    # enable capabilities
```

The model picker lists whatever `/v1/models` reports. That is now the gateway,
which answers with the full catalogue whether or not anything is loaded — so
nothing needs starting first.

Nothing else to configure. Hermes leaves the OpenAI client timeout unset, and
the gateway's `healthCheckTimeout` is set just under openai-python's 600s
default so a model load is held to completion. See the timeout ladder in
[`../llama-swap/README.md`](../llama-swap/README.md).

## Full cleanup

```bash
curl -X POST http://localhost:8000/api/models/unload
docker rmi vllm/vllm-openai:v0.28.0
rm -rf ~/.cache/huggingface/hub/models--nvidia--Qwen3.6-35B-A3B-NVFP4
```

Then remove the entry from
[`../llama-swap/config.yaml`](../llama-swap/config.yaml) and re-run
`./setup.sh`, or the gateway will keep advertising a model it can no longer
load without a 21.85 GiB download.
