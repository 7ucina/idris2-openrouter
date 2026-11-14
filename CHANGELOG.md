# Changelog

## 0.4.0

The whole API.

- `OpenRouter.API`: a function for every one of the API's 174 operations, generated from
  OpenRouter's OpenAPI description by `tools/generate_api.py`.
- `OpenRouter.Responses`: the Responses API, with streaming, typed replies and a tool loop.
- `OpenRouter.Anthropic`: the Anthropic Messages API, with streaming.
- Rerank (`rerank`), video (`submitVideo`, `awaitVideo`, `downloadVideo`), stored files
  (`storeFile` and friends), batches (`createBatch`, `awaitBatch`), key management,
  activity, generation content and feedback, and sign-in with PKCE.
- Chat: server tools (`ServerTools`, `serverTool`), citations (`replyCitations`), video
  input, and the remaining request parameters (`SessionId`, `Metadata`, `ServiceTier`,
  `Prediction`, `PromptCacheKey`, `AutoCache`, `EchoUpstream`, grammar formats, more
  effort levels and provider preferences).
- The client: `callText`, `callForm`, `upload` (multipart) and `download` beside `call`;
  `openEventStream` for any streaming endpoint; `appCategories`; `withHeaders`.
- Changed: `Client` has a new field, `appCategories`. `Usage` has a new field,
  `cacheWriteTokens`. `KeyInfo` has new fields `name`, `hash` and `disabled`. `Choice` has
  a new field, `citations`. A successful response whose `error` is a string (a failed job)
  is now returned rather than treated as an API error.

## 0.3.0

- `OpenRouter.Async`: `async`, `await`, `poll`, `concurrently` and `chatAll` run requests
  on threads of their own. A thread waiting on the network no longer stalls the others.

## 0.2.0

- Images (`generateImage`, `replyImages`), speech (`speech`), transcription
  (`transcribe`), spoken chat replies (`spoken`, `replyAudio`), and helpers for base64
  files, data URIs and WAV headers.

## 0.1.0

- Chat, streaming, tools with typed arguments, structured output with typed results, text
  completions, embeddings, and the catalog and account endpoints.
