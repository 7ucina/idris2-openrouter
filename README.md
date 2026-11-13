# idris2-openrouter

[![test](https://github.com/7ucina/idris2-openrouter/actions/workflows/test.yml/badge.svg)](https://github.com/7ucina/idris2-openrouter/actions/workflows/test.yml)

A client for the [OpenRouter](https://openrouter.ai) API in [Idris 2](https://www.idris-lang.org):
chat, streaming, tool calls with typed arguments, structured output with typed results,
images and audio in both directions, text completions, embeddings, and the catalog and
account endpoints.

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

### Everything else

| Function | What it does |
| --- | --- |
| `ask` | One prompt in, the reply's text out. |
| `generateImage`, `speech`, `transcribe` | Images, text to speech and speech to text, as above. |
| `complete`, `completeStream` | Text completions (`/completions`). |
| `embed` | Embeddings: one vector per input, in input order. |
| `models`, `modelCount`, `embeddingModels` | The catalog, with prices, context lengths and supported parameters. No key needed. |
| `modelEndpoints`, `providers` | Who serves a model, at what price and uptime. No key needed. |
| `keyInfo`, `credits` | The key's limit and spending; credits bought and used. |
| `generation` | What a past request cost and how long it took, by the `id` of its response. |
| `call` | Any other endpoint: a method, a path, a query and a JSON body. |

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
  UTF-8 character, and you get libcurl's TLS, HTTP/2, proxy support (`HTTPS_PROXY`) and
  system certificates.

| Module | Contents |
| --- | --- |
| `OpenRouter` | Re-exports everything below except `HTTP` and `SSE`. |
| `OpenRouter.Client` | `Client` and every function that talks to the API. |
| `OpenRouter.Request` | `ChatRequest`, `Option`, tools, response formats, provider routing, and the image, speech and transcription requests. |
| `OpenRouter.Message` | Messages, content parts, tool calls. |
| `OpenRouter.Response` | `ChatResponse`, `Usage`, log probabilities, `Error`. |
| `OpenRouter.Stream` | `Chunk`, and the accumulator that folds chunks into a `ChatResponse`. |
| `OpenRouter.Schema` | Typed JSON Schemas. |
| `OpenRouter.Tools` | `Handler` and `runTools`. |
| `OpenRouter.Model` | Models, endpoints, providers, key, credits, generations. |
| `OpenRouter.JSON` | A JSON value type, parser and printers. |
| `OpenRouter.SSE` | An incremental server-sent event decoder. |
| `OpenRouter.HTTP` | The libcurl binding, and base64 and WAV file helpers. |

`idris2 --mkdoc openrouter.ipkg` builds the API reference from the doc comments.

## Examples

`examples/` has eight programs: `Hello`, `Stream`, `Tools`, `Structured`, `Chat` (a
terminal chat that keeps the conversation), `Image` (makes a picture and saves it),
`Speech` (reads a sentence aloud, then transcribes the recording) and `Models` (the
cheapest models that can call tools; needs no key).

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

The pure tests cover the JSON parser and printers, schemas, the wire format of requests,
response decoding, and the event-stream decoder (including a stream cut in two at every
possible position). The mock tests cover every client function against a local server
that misbehaves on purpose: rate limits with `Retry-After`, provider errors hidden in a
200, repeated 503s, bodies that are not JSON, timeouts, streams cut mid-line and
mid-character, a stream that fails midway, one that goes silent, one that is refused, and
audio whose bytes are not text.
Neither needs a key.

## Status and limits

- **Tested against openrouter.ai** with a handful of models (`openai/gpt-4o-mini`,
  `openai/gpt-5-nano`, `openai/gpt-audio-mini`, `google/gemini-2.5-flash-image`, and one
  model each for embeddings, images, speech and transcription): chat, streaming, a tool
  loop, a streamed tool call, structured output, log probabilities, reasoning, text
  completions, embeddings, image generation, pictures in chat replies, image and audio
  input, speech, a spoken chat reply, transcription, and the key, credits and generation
  endpoints. Other models and providers are covered only by the mock, which follows
  OpenRouter's documented shapes. `test/run.sh --live` repeats nearly all of this when
  `OPENROUTER_API_KEY` is set, for about a cent.
- **Audio formats depend on the provider.** Several speech models refuse
  `SpeechFormat "mp3"`, and OpenAI's audio chat models only stream `"pcm16"`. Free models
  need your account's privacy settings to allow them.
- **Tested with Idris 0.8.0 and the Chez backend**, on macOS (arm64) and, in CI, on Linux
  (x86-64).
- **Requests block.** There is no async interface; a request occupies its thread until
  it returns, and a stream must be closed (`chatStream` and `chatStreamText` close theirs).
- Not covered: the Responses and Anthropic Messages endpoints, video generation,
  streamed partial images from the image endpoint, multipart uploads, API key management,
  and OAuth. `call` reaches any JSON endpoint.

## License

MIT. See `LICENSE`.
