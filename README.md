# idris2-openrouter

[![test](https://github.com/7ucina/idris2-openrouter/actions/workflows/test.yml/badge.svg)](https://github.com/7ucina/idris2-openrouter/actions/workflows/test.yml)

A client for the [OpenRouter](https://openrouter.ai) API in [Idris 2](https://www.idris-lang.org):
the whole of it. Typed functions cover what programs mostly use: chat, streaming, tools with
typed arguments, structured output with typed results, the Responses and Anthropic Messages
APIs, images, audio, video, embeddings, reranking, files, batches and key management. A
generated module has a function for every one of the API's 174 endpoints.

```idris
import OpenRouter

main : IO ()
main = do
  Just client <- fromEnv                       -- reads OPENROUTER_API_KEY
    | Nothing => putStrLn "Set OPENROUTER_API_KEY."
  Right reply <- chat client $ chatRequest "openai/gpt-4o-mini"
                   [system "Answer in one sentence.", "Why is the sky blue?"]
                   [Temperature 0.2, MaxTokens 200]
    | Left err => putStrLn (show err)
  putStrLn (text reply)
```

## Install

You need [pack](https://github.com/stefan-hoeck/idris2-pack), a C compiler, `make`, and
libcurl with its headers (they ship with macOS; on Debian or Ubuntu,
`apt install libcurl4-openssl-dev`). The package has no Idris dependencies beyond `base`.

Add the package to your project's `pack.toml` (or to `~/.config/pack/user/pack.toml`):

```toml
[custom.all.openrouter]
type   = "git"
url    = "https://github.com/7ucina/idris2-openrouter"
commit = "latest:main"
ipkg   = "openrouter.ipkg"
```

and add `openrouter` to the `depends` of your `.ipkg`. pack builds the C shim
(`support/openrouter_curl.c`) and installs it with the package.

## A tour

### Requests are data

A request is a model, a list of messages, and a list of options. A string literal in the
message list is a user message.

```idris
chatRequest "anthropic/claude-sonnet-4.5"
  [ cached (system longInstructions)           -- a prompt cache breakpoint
  , userParts [Text "What is in this picture?", Image "https://example.com/cat.png"]
  ]
  [ MaxTokens 500
  , Reasoning [Effort High]
  , Fallbacks ["openai/gpt-4o"]                -- models to try if the first cannot answer
  , Provider [Sort Throughput, DataCollection Deny]
  , Field "verbosity" (JString "low")          -- any parameter with no constructor of its own
  ]
```

When an option is given twice, the later one wins, so `withOptions` can override a
request's defaults.

### Streaming

`chatStreamText` hands you each piece of text as it arrives, then returns the whole reply:
the same `ChatResponse` that `chat` returns, with tool calls and usage.

```idris
result <- chatStreamText client request $ \piece => putStr piece >> fflush stdout
```

`chatStream` hands over whole chunks (reasoning, tool call fragments, every choice), and
`openChatStream`, `nextChunk` and `closeStream` let you pull chunks at your own pace and
stop early.

### Tools with typed arguments

A `Schema a` is both the JSON Schema a model is shown and the decoder for what the model
sends back. A tool's function therefore takes an Idris value, never JSON:

```idris
weather : Handler IO
weather = handler "get_weather" "The current weather in a city."
  (object
    [ prop "city" (string `describe` "The city's name")
    , prop "unit" (nullable (enum ["celsius", "fahrenheit"]))
    ])
  (\[city, unit] => lookupWeather city unit)   -- city : String, unit : Maybe String

Right run <- runTools client [weather] 5 (chatRequest model ["Is it warm in Lima?"] [])
putStrLn (text run.response)
```

`runTools` sends the request, runs the tools the model calls, sends the results back, and
repeats until the model answers (here, for at most 5 rounds). When a model's arguments do
not fit the schema, the function is not called: the model is told what was wrong
(`$.city: expected a string, found an integer`) and can try again. You can also run the
loop by hand with `Tools`, `requestedTools`, `reply` and `toolResult`.

### Structured output with typed results

```idris
record Planet where
  constructor MkPlanet
  name  : String
  moons : Nat

planet : Schema Planet
planet = map (\[n, m] => MkPlanet n m) $ object [prop "name" string, prop "moons" natural]

Right ([planets], _) <- chatAs client "planets" (object [prop "planets" (array planet)]) request
-- planets : List Planet
```

`chatAs` sends the schema as a strict `json_schema` response format and decodes the reply
by the same schema. A reply that does not fit comes back as `Left (Mismatched ...)` with
the place and the reason. Not every model supports structured output: `models client
[("supported_parameters", "structured_outputs")]` lists the ones that do.

### Images

Models built to make images have their own endpoint:

```idris
Right response <- generateImage client $
    imageRequest "recraft/recraft-v4.1-flash-v2" "a small red fox, flat vector illustration"
      [AspectRatio "16:9"]
for_ response.images $ \image => saveBase64 "fox.webp" image.base64
```

Chat models that draw return pictures in the reply. Ask for the image modality, then read
`replyImages`, which works for streamed replies too:

```idris
Right reply <- chat client $
    chatRequest "google/gemini-2.5-flash-image" ["Draw a red circle."] [Modalities ["image", "text"]]
for_ (replyImages reply) (saveDataURI "circle.png")
```

To send a picture, use an `Image` part with a URL, or with a local file through
`fileDataURI "image/png" "photo.png"`.

### Audio

```idris
-- text to speech, into a file
Right _ <- speech client
    (speechRequest "heygen/heygen-voice-1-turbo:free" "Hello." [Voice "nadine"]) "hello.pcm"
Just _  <- saveWav "hello.pcm" "hello.wav" 24000

-- speech to text
Just audio <- audioFile "hello.wav"
Right heard <- transcribe client (transcriptionRequest "openai/gpt-4o-mini-transcribe" audio [])
putStrLn heard.text
```

Speech arrives as raw bytes and goes straight to the file. Most speech models only
produce headerless 16-bit PCM (the default), so `saveWav` adds the WAV header that
players and transcription models want. A model's voices are in its catalog entry
(`models client [("output_modalities", "speech")]`, then `.voices`).

A chat model with audio output can speak its reply. Audio only arrives on a stream, so
use `chatStream` with the `spoken` options, then read `replyAudio`:

```idris
Right reply <- chatStream client
    (chatRequest "openai/gpt-audio-mini" ["Say hello."] (spoken "alloy" "pcm16")) (\_ => pure ())
for_ (replyAudio reply) $ \audio => do
  putStrLn audio.transcript
  saveBase64 "reply.pcm" audio.base64
```

To send audio to a chat model, use an `Audio` part: `Audio base64 "wav"`.

### Many requests at once

Every client function blocks until it is done. To run several at the same time, put each
on a thread of its own:

```idris
-- a batch, three at a time, replies in the order of the requests
replies <- chatAll client 3 requests

-- any actions at all, at most eight at a time
answers <- concurrently 8 [ask client model q | q <- questions]

-- one task in the background
task  <- async (chat client bigRequest)
...                                   -- carry on with other work
reply <- await task                   -- or `poll task` to look without waiting
```

One request failing does not disturb the others: each result is its own `Either Error`.
Streams can run side by side the same way. These are operating system threads, and a
thread waiting on the network does not hold up the rest of the program. A task cannot be
cancelled from outside; give requests a `requestTimeout` instead.

### Web search and other server tools

OpenRouter can run some tools itself. Pass them as `ServerTools`; they sit beside your own
`Tools` in the request. The sources a reply cites come back as `replyCitations`.

```idris
Right reply <- chat client $ chatRequest model ["What changed in Idris 2 this year?"]
    [ServerTools [serverTool "openrouter:web_search" []]]
for_ (replyCitations reply) $ \source => putStrLn source.url
```

`serverTools client` lists the tools there are.

### The Responses API

OpenAI's newer request shape, which OpenRouter serves for every model. It takes the same
options, tools and schemas as chat:

```idris
Right r <- respond client (responsesRequest model [say User "Hello"] [Instructions "Be brief."])
putStrLn (outputText r)
```

`respondStream` and `respondStreamText` stream it, `respondAs` returns a typed reply, and
`respondWithTools` runs a tool loop with the same `Handler`s as `runTools`. A response's
`output` is a list of typed items (messages, reasoning, tool calls), and `outputItems` turns
it back into input for the next request.

### The Anthropic Messages API

Anthropic's request shape, which OpenRouter also serves for every model:

```idris
Right m <- createMessage client $
    messagesRequest "anthropic/claude-haiku-4.5" 1024 [userTurn "Hello"] [Instructions "Be brief."]
putStrLn (blocksText m.content)
```

Content is a list of typed blocks (`TextBlock`, `ToolUse`, `ToolOutput`, `Thinking`,
`ImageBlock`), `streamMessage` and `streamMessageText` stream it and assemble the blocks,
and `Reasoning [Budget 2048]` turns thinking on.

### Rerank, video, files, batches

```idris
-- order documents by how well they answer a query
Right ranked <- rerank client (rerankRequest "cohere/rerank-v3.5" query documents [TopN 3])

-- make a video: submit, wait, download
Right job   <- submitVideo client (videoRequest model "a paper boat on a pond" [Duration 5])
Right done  <- awaitVideo client job.id 10 60        -- look every 10 s, at most 60 times
Right bytes <- downloadVideo client job.id 0 "boat.mp4"

-- store a file with OpenRouter, to refer to by id
Right file <- storeFile client "report.pdf"

-- run requests in the background, at a discount
Right b    <- createBatch client "/v1/chat/completions" model
                [MkBatchItem "first" (toJSON request1), MkBatchItem "second" (toJSON request2)]
Right done <- awaitBatch client b.id 60 120
for_ done.results $ \r => putStrLn (r.customId ++ ": " ++ text (chatResponseFromJSON r.body))
```

### Everything else

| Function | What it does |
| --- | --- |
| `ask` | One prompt in, the reply's text out. |
| `complete`, `completeStream` | Text completions (`/completions`). |
| `embed` | Embeddings: one vector per input, in input order. |
| `models`, `modelInfo`, `modelCount`, `embeddingModels`, `availableModels` | The catalog, with prices, context lengths and supported parameters. |
| `modelEndpoints`, `zdrEndpoints`, `providers`, `serverTools` | Who serves a model, at what price and uptime; endpoints that keep no data. |
| `keyInfo`, `credits`, `activity` | The key's limit and spending; credits bought and used; spending by day. |
| `generation`, `generationContent`, `reportGeneration` | What a past request cost, what it said, and feedback on it. |
| `apiKeys`, `createKey`, `apiKeyInfo`, `updateKey`, `deleteKey` | Managing API keys (needs a management key). |
| `authorizationURL`, `exchangeAuthCode` | Letting a user sign in and bring their own key (OAuth with PKCE). |
| `storedFiles`, `fileInfo`, `removeFile`, `downloadFile` | Managing stored files. |
| `batches`, `batchStatus`, `cancelBatch` | Managing batches. |

### Every other endpoint

`OpenRouter.API` has a function for each of the API's 174 operations: guardrails,
workspaces, presets, analytics, private endpoints, and the rest. It is generated from
OpenRouter's own OpenAPI description, so it is complete by construction, and running
`tools/generate_api.py` again brings it up to date.

```idris
import OpenRouter
import OpenRouter.API as API

Right guardrails <- API.listGuardrails client [("limit", "20")]
Right created    <- API.createGuardrail client (JObject [("name", JString "No PII")])
Right _          <- API.deleteGuardrail client guardrailId
```

These functions are thin: path parameters and required query parameters are arguments,
optional query parameters are a list, and bodies and results are `JSON` (read with `get`,
`path` and the `as...` functions). They share the client's key, retries, timeouts and
errors. Underneath are five calls you can also use directly: `call` (JSON), `callText`,
`callForm`, `upload` (multipart) and `download` (bytes to a file), plus `openEventStream`
for any endpoint that streams.

## Errors and retries

Every function returns `Either Error a`; nothing throws.

```idris
data Error
  = Transport Failure               -- no response: unreachable, or timed out
  | Api ApiError                    -- OpenRouter or the provider said no
  | Malformed reason body           -- a response that is not the API's JSON
  | Mismatched mismatch text        -- a structured reply that does not fit its schema
```

- **Errors inside a 200.** OpenRouter answers 200 with an error body when a provider fails
  after the response has begun, and a stream can end with an error chunk. Both come back
  as `Left (Api ...)`, never as an empty reply.
- **Retries.** A request that fails in a way that may pass (a transport failure, a
  timeout, 408, 429, or any 5xx, including one hidden in a 200) is sent again, twice by
  default, with a pause that starts at half a second and doubles. A `Retry-After` header
  is honored. A bad request, a bad key, a lack of credits or a moderation block is
  returned at once. A stream is retried only until it opens.
- **Timeouts.** 10 seconds to connect, 10 minutes for a request that is not streamed, and
  2 minutes of silence on a stream. All of these, the retry count and the base URL are
  fields of `Client`:

  ```idris
  client : Client
  client = { retries := 5, requestTimeout := 60000, appTitle := Just "My App" } (newClient key)
  ```

## Design

- **Total where it can be.** Every module is `%default total`. The JSON parser, the
  schema decoder, the event-stream decoder and the stream accumulator are total functions;
  only the functions that wait on the network are marked `covering`.
- **Lenient decoding.** OpenRouter fronts hundreds of providers that do not all fill in
  the same fields. A missing field reads as `Nothing`, `""` or `[]` instead of failing
  the response, and every record keeps the `raw` JSON it came from.
- **Integers stay integers.** `OpenRouter.JSON` keeps `JInt` apart from `JNum`, so
  `MaxTokens 256` goes out as `256`, not `256.0`.
- **HTTP is libcurl**, through a small C shim that Idris pulls the response body from
  piece by piece. No C callback re-enters Idris, pieces never end in the middle of a
  UTF-8 character, a thread waiting on the network does not block the garbage collector
  for other threads, and you get libcurl's TLS, HTTP/2, proxy support (`HTTPS_PROXY`) and
  system certificates.

| Module | Contents |
| --- | --- |
| `OpenRouter` | Re-exports everything below except `API`, `HTTP` and `SSE`. |
| `OpenRouter.Client` | `Client` and every function that talks to the API. |
| `OpenRouter.Request` | `ChatRequest`, `Option`, tools, response formats, provider routing, and the image, speech and transcription requests. |
| `OpenRouter.Message` | Messages, content parts, tool calls. |
| `OpenRouter.Response` | `ChatResponse`, `Usage`, log probabilities, `Error`. |
| `OpenRouter.Stream` | `Chunk`, and the accumulator that folds chunks into a `ChatResponse`. |
| `OpenRouter.Schema` | Typed JSON Schemas. |
| `OpenRouter.Tools` | `Handler` and `runTools`. |
| `OpenRouter.Async` | `async`, `await`, `concurrently`, `chatAll`. |
| `OpenRouter.Responses` | The Responses API. |
| `OpenRouter.Anthropic` | The Anthropic Messages API. |
| `OpenRouter.API` | A function for every endpoint, generated from the OpenAPI description. |
| `OpenRouter.Model` | Models, endpoints, providers, keys, credits, generations, files, batches. |
| `OpenRouter.JSON` | A JSON value type, parser and printers. |
| `OpenRouter.SSE` | An incremental server-sent event decoder. |
| `OpenRouter.Wire` | HTTP methods, form parts, transport failures. |
| `OpenRouter.HTTP` | The libcurl binding, and base64 and WAV file helpers. |

`idris2 --mkdoc openrouter.ipkg` builds the API reference from the doc comments.

## Examples

`examples/` has twelve programs: `Hello`, `Stream`, `Tools`, `Structured`, `Chat` (a
terminal chat that keeps the conversation), `Parallel` (several questions at once),
`Responses` (the Responses API, streamed and with a tool), `Image` (makes a picture and
saves it), `Speech` (reads a sentence aloud, then transcribes the recording), `Rerank`,
and two that need no key: `Models` (the cheapest models that can call tools) and
`Endpoints` (the generated functions).

```sh
export OPENROUTER_API_KEY=sk-or-...
pack exec examples/Hello.idr
```

To try them without a key or any spending, run them against the test server:

```sh
python3 test/mock.py &
OPENROUTER_BASE_URL=http://127.0.0.1:8787/api/v1 OPENROUTER_API_KEY=test-key pack exec examples/Tools.idr
```

## Tests

```sh
test/run.sh          # pure tests, then the client against test/mock.py
test/run.sh --live   # also openrouter.ai: the public endpoints, and paid requests if a key is set
```

The pure tests cover the JSON parser and printers, schemas, the wire format of every kind
of request, response decoding, and the event-stream decoder (including a stream cut in two at every
possible position). The mock tests cover every client function against a local server
that misbehaves on purpose: rate limits with `Retry-After`, provider errors hidden in a
200, repeated 503s, bodies that are not JSON, timeouts, streams cut mid-line and
mid-character, a stream that fails midway, one that goes silent, one that is refused, and
audio whose bytes are not text. They also run requests and streams on several threads at
once and check the timing and the server's count of requests in flight.
Neither needs a key.

## Status and limits

- **Tested against openrouter.ai** with a handful of models: chat, streaming, tool loops,
  structured output, log probabilities, reasoning, server tools, the Responses API
  (plain, streamed, tools, typed), the Anthropic Messages API (plain, streamed, tool use),
  text completions, embeddings, rerank, image generation, pictures in chat replies, image
  and audio input, speech, a spoken reply, transcription, file storage, concurrent
  requests, and the catalog, key, credits and generation endpoints. `test/run.sh --live`
  repeats this when `OPENROUTER_API_KEY` is set, for about a cent.
- **Tested only against the mock:** video generation (a real video costs a quarter or
  more), batches (they need a model with a platform-billed batch endpoint), key
  management, activity and sign-in (they need a management key or a real user), and the
  generated functions for the administrative endpoints, of which a sample is exercised to
  check paths, queries, bodies, uploads and downloads. The mock follows OpenRouter's
  documented shapes.
- **Audio formats depend on the provider.** Several speech models refuse
  `SpeechFormat "mp3"`, and OpenAI's audio chat models only stream `"pcm16"`. Free models
  need your account's privacy settings to allow them.
- **Tested with Idris 0.8.0 and the Chez backend**, on macOS (arm64) and, in CI, on Linux
  (x86-64).
- **Concurrency is threads.** A request occupies its thread until it returns, and
  `OpenRouter.Async` runs requests on threads of their own; there is no event loop and no
  cancellation. It needs a threaded Chez, which is what Idris is normally built with. A
  stream must be closed (`chatStream` and `chatStreamText` close theirs).
- Typed functions stop where the API turns administrative. Guardrails, workspaces,
  presets, analytics and the like are reached through `OpenRouter.API`, with JSON in and
  out. Streamed partial images from the image endpoint are reached with
  `openEventStream`.

## License

MIT. See `LICENSE`.
