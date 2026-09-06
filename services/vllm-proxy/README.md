<!--
SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
SPDX-License-Identifier: Apache-2.0
-->

# vllm-proxy

Experimental standalone loopback proxy for a local vLLM OpenAI-compatible
server. It forwards `/v1/*` requests to vLLM and supplies the API key configured
by PAIR's bundled vLLM engine manifest.

```bash
vllm-proxy --backend-url http://127.0.0.1:8000 \
  --backend-api-key vllm-local --port 8001
curl http://127.0.0.1:8001/v1/models
```

Both the public listener and configured backend are restricted to loopback.
Pass an empty `--backend-api-key` if the local server does not use API-key
authentication. `/health` reports that the proxy process is alive; `/ready`
returns success only while the configured vLLM `/health` endpoint responds.
The service is not supervised by `nvpair-ui-broker` yet, does not participate in
cluster discovery or scheduling, and is not exposed in the desktop application.
