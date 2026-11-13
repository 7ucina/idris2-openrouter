||| The client against test/mock.py: every request path, with the failures a
||| real server produces. Needs no API key and spends nothing.
module Mock

import Data.IORef
import Data.List
import Data.String
import Harness
import OpenRouter
import OpenRouter.HTTP
import System.Clock

%default covering
%ambiguity_depth 10

outcome : Either Error a -> String
outcome (Right _)                         = "ok"
outcome (Left (Transport (TimedOut _)))   = "timed out"
outcome (Left (Transport (Unreachable _))) = "unreachable"
outcome (Left (Api e))                    = "api " ++ show e.status ++ " " ++ e.message
outcome (Left (Malformed _ _))            = "malformed"
outcome (Left (Mismatched m _))           = "mismatched " ++ show m

replyText : Either Error ChatResponse -> String
replyText (Right r) = text r
replyText e         = "<<" ++ outcome e ++ ">>"

millis : IO Integer
millis = do
  t <- clockTime Monotonic
  pure (toNano t `div` 1000000)

||| How many requests the mock has had for a model that counts them.
seen : Client -> String -> IO (Maybe Integer)
seen c model = do
  Right j <- call c GET "/../../_seen" [] Nothing
    | Left _ => pure Nothing
  pure (asInteger (get model j))

--------------------------------------------------------------------------------

basics : Tally => Client -> IO ()
basics c = do
  section "Mock: requests"
  r <- chat ({ appTitle := Just "T" } c) (chatRequest "mock/plain" ["hi"] [Temperature 0.5])
  same "a plain reply, with a header and an option on the wire" (replyText r) "You said: hi | title=T | temp=0.5"
  same "response fields" (map (\x => (x.id, x.provider, finish x, map totalTokens x.usage, x.usage >>= cost)) r |> either (const Nothing) Just)
    (Just ("gen-mock-1", Just "Mock", Just FinishStop, Just 10, Just 0.000012))

  a <- ask c "mock/plain" "héllo 😀"
  same "ask returns the text, non-ASCII intact" (either (const "") id a) "You said: héllo 😀 | title=None | temp=None"

  let c' = { appUrl := Just "https://example.com", headers := [("X-Extra", "yes")] } c
  e <- chat c' (chatRequest "mock/echo" [system "s", "u"] [MaxTokens 5, Provider [Sort Price]])
  let echoed = either (const JNull) id (parse (replyText e))
  same "the body the server received"
    (render (get "body" echoed))
    #"{"model":"mock/echo","messages":[{"role":"system","content":"s"},{"role":"user","content":"u"}],"max_tokens":5,"provider":{"sort":"price"}}"#
  same "the headers the server received"
    (asString (get "referer" echoed), asString (get "agent" echoed), asString (get "extra" echoed))
    (Just "https://example.com", Just "idris2-openrouter/0.2.0", Just "yes")

  u <- chat c (chatRequest "mock/unknown" ["hi"] [])
  same "a bad request is an API error" (outcome u) "api 400 unknown mock model mock/unknown"

failures : Tally => Client -> IO ()
failures c = do
  section "Mock: failures and retries"
  t0 <- millis
  r <- chat c (chatRequest "mock/429" ["hi"] [])
  t1 <- millis
  same "a 429 is retried" (replyText r) "ok after 429, attempt 2"
  check "Retry-After is honored" (t1 - t0 >= 900)

  r <- chat c (chatRequest "mock/200err" ["hi"] [])
  same "an error inside a 200 is retried" (replyText r) "ok after hidden 502, attempt 2"

  r <- chat c (chatRequest "mock/down" ["hi"] [])
  same "a 503 that does not pass is returned" (outcome r) "api 503 No provider available"
  n <- seen c "mock/down"
  same "after the first try and two retries" n (Just 3)

  r <- chat ({ retries := 0 } c) (chatRequest "mock/down" ["hi"] [])
  n <- seen c "mock/down"
  same "no retries when retries is 0" (outcome r, n) ("api 503 No provider available", Just 4)

  r <- chat c (chatRequest "mock/402" ["hi"] [])
  same "a lack of credits is returned at once" (outcome r) "api 402 Insufficient credits"
  same "and is not worth retrying" (either retryable (const True) r) False

  r <- chat c (chatRequest "mock/garbage" ["hi"] [])
  same "a 200 that is not JSON" (outcome r) "malformed"

  r <- chat ({ apiKey := "wrong" } c) (chatRequest "mock/plain" ["hi"] [])
  same "a wrong key" (outcome r) "api 401 No auth credentials found"

  r <- chat ({ baseUrl := "http://127.0.0.1:9/api/v1", retries := 1, backoff := 10 } c) (chatRequest "mock/plain" ["hi"] [])
  same "a port nobody listens on" (outcome r) "unreachable"

  t0 <- millis
  r <- chat ({ requestTimeout := 500, retries := 0 } c) (chatRequest "mock/slow" ["hi"] [])
  t1 <- millis
  same "a request that takes too long" (outcome r) "timed out"
  check "is given up on in time" (t1 - t0 < 2000)

streams : Tally => Client -> IO ()
streams c = do
  section "Mock: streams"
  pieces <- newIORef (the (List String) [])
  count  <- newIORef (the Nat 0)
  r <- chatStream c (chatRequest "mock/stream" ["hi"] []) $ \chunk => do
         modifyIORef count S
         modifyIORef pieces (chunkText chunk ::)
  ps <- readIORef pieces
  n  <- readIORef count
  same "the pieces add up, though the bytes were cut mid-line and mid-character"
    (concat (reverse ps)) "Streamed héllo 😀 done"
  same "keep-alive comments and [DONE] are not chunks" n 8
  same "the accumulated reply" (replyText r) "Streamed héllo 😀 done"
  same "its reasoning, tool call, finish reason and usage"
    (map (\x => (reasoningText x, map (\t => (t.id, t.name, t.arguments)) (requestedTools x), finish x, map totalTokens x.usage)) r
       |> either (const Nothing) Just)
    (Just ("thinking. ", [("call_s", "lookup", #"{"q":"x"}"#)], Just FinishStop, Just 13))

  out <- newIORef ""
  r <- chatStreamText c (chatRequest "mock/stream" ["hi"] []) (\t => modifyIORef out (++ t))
  o <- readIORef out
  same "chatStreamText hands over only text" (o, replyText r) ("Streamed héllo 😀 done", "Streamed héllo 😀 done")

  out <- newIORef ""
  r <- chatStreamText c (chatRequest "mock/stream-err" ["hi"] []) (\t => modifyIORef out (++ t))
  o <- readIORef out
  same "a stream that fails midway: the text so far, then the error" (o, outcome r) ("partial ", "api 502 Provider disconnected")

  r <- chatStream c (chatRequest "mock/stream-402" ["hi"] []) (\_ => pure ())
  same "a stream that is refused" (outcome r) "api 402 Insufficient credits"

  r <- chatStream c (chatRequest "mock/stream-n2" ["hi"] []) (\_ => pure ())
  same "two choices, CRLF line ends, no [DONE]"
    (either (const []) (map (\x => (x.index, messageText x.message, x.finishReason)) . choices) r)
    [(0, "A1A2", Just FinishStop), (1, "B1B2", Just FinishLength)]

  out <- newIORef ""
  t0 <- millis
  r <- chatStreamText ({ idleTimeout := 1000 } c) (chatRequest "mock/stream-stall" ["hi"] []) (\t => modifyIORef out (++ t))
  t1 <- millis
  o <- readIORef out
  same "a stream that goes silent" (o, outcome r) ("one ", "timed out")
  check "is given up on in time" (t1 - t0 < 5000)

  Right s <- openChatStream c (chatRequest "mock/stream" ["hi"] [])
    | Left e => check ("a stream opens: " ++ show e) False
  first <- nextChunk s
  same "reading a stream by hand" (map (map chunkReasoning) first |> either (const Nothing) id) (Just "thinking. ")
  closeStream s
  closeStream s
  after <- nextChunk s
  same "a closed stream is over, and closing twice is harmless" (map (map chunkText) after |> either (const (Just "error")) id) Nothing
  soFar <- streamed s
  same "what was read before closing is kept" (reasoningText soFar) "thinking. "

Weather : Type
Weather = HList [String, Maybe Nat]

weather : Schema Weather
weather = object [prop "city" string, prop "days" (nullable natural)]

tools : Tally => Client -> IO ()
tools c = do
  section "Mock: tools"
  let get = tool "get_time" "The time in a city." (object [prop "city" string])
      req = chatRequest "mock/tools" ["What time is it in Paris?"] [Tools [get]]
  Right r1 <- chat c req
    | Left e => check ("a tool call comes back: " ++ show e) False
  same "the model asks for a tool"
    (finish r1, map (\t => (t.id, t.name, t.arguments)) (requestedTools r1), text r1)
    (Just FinishToolCalls, [("call_1", "get_time", #"{"city":"Paris"}"#)], "")
  r2 <- chat c (withMessages (toList (reply r1) ++ [toolResult "call_1" "noon"]) req)
  same "and answers once it has the result" (replyText r2) "It is noon in Paris."

  calls <- newIORef (the (List String) [])
  let h = handler "get_weather" "The forecast for a city." weather $ \[city, days] => do
            modifyIORef calls (city ::)
            pure (city ++ " for " ++ maybe "today" show days ++ " days")
  run <- runTools c [h] 5 (chatRequest "mock/typed" ["Forecast?"] [])
  cs <- readIORef calls
  same "the loop ends with the model's answer" (either (const "") (text . response) run) "Forecast: Paris for 2 days"
  same "arguments that do not fit never reach the function" cs ["Paris"]
  same "the model was told why"
    (either (const []) (map messageText . filter ((== ToolResult) . role) . messages) run)
    [ "Error: the arguments do not fit the tool's schema. $.city: expected a string, found an integer"
    , "Paris for 2 days" ]
  same "the transcript: question, two calls with results, answer"
    (either (const []) (map role . messages) run)
    [User, Assistant, ToolResult, Assistant, ToolResult, Assistant]
  same "usage adds up over the three responses"
    (either (const Nothing) (\x => Just (length x.responses, (totalUsage x).totalTokens)) run) (Just (3, 30))

  run <- runTools c [h] 2 (chatRequest "mock/loop" ["Go"] [])
  same "a model that never stops is cut off after maxRounds"
    (either (const Nothing) (\x => Just (length x.responses, finish x.response)) run) (Just (3, Just FinishToolCalls))
  same "a call to an unknown tool is answered with an error"
    (either (const Nothing) (map messageText . find ((== ToolResult) . role) . messages) run)
    (Just "Error: there is no tool named nope.")

Forecast : Type
Forecast = HList [String, Double, Maybe String, List String]

forecast : Schema Forecast
forecast = object [prop "city" string, prop "celsius" number, prop "advice" (nullable string), prop "tags" (array string)]

structured : Tally => Client -> IO ()
structured c = do
  section "Mock: structured output"
  r <- chatAs c "forecast" forecast (chatRequest "mock/structured" ["Oslo?"] [])
  case r of
    Right ([city, celsius, advice, tags], _) =>
      same "a typed reply, from JSON in a code fence" (city, celsius, advice, tags) ("Oslo", -3.5, Nothing, ["cold", "forecast"])
    Left e => check ("a typed reply: " ++ show e) False
  r <- chatAs c "forecast" forecast (chatRequest "mock/structured-bad" ["Oslo?"] [])
  same "a reply that does not fit" (outcome r) "mismatched $.celsius: expected a number, found a string"

others : Tally => Client -> IO ()
others c = do
  section "Mock: completions, embeddings, catalog, account"
  r <- complete c (completionRequest "mock/text" "The sky is" [MaxTokens 1])
  same "a text completion" (either (const "") completionText r) "The sky is blue"
  out <- newIORef (the (List String) [])
  r <- completeStream c (completionRequest "mock/text" "The sky" []) (\t => modifyIORef out (t ::))
  o <- readIORef out
  same "a streamed text completion" (reverse o, either (const "") id r) ([" is", " blue"], " is blue")

  r <- embed c (embeddingRequest "mock/embed" ["a", "bbb"] [])
  same "embeddings, in input order" (either (const []) embeddings r) [[1.0, 0.5, -0.001], [3.0, 0.5, -0.001]]
  same "embedding usage" (either (const Nothing) (map promptTokens . usage) r) (Just 5)

  r <- models c [("q", "a b&c=é")]
  same "the model list" (either (const []) (map (\m => (m.id, m.contextLength, m.pricing.completion))) r)
    [("mock/plain", Just 128000, Just 2.0e-6), ("mock/tiny", Nothing, Nothing)]
  same "the query is percent-encoded" (either (const "") (concatMap description . take 1) r) "query=q=a%20b%26c%3D%C3%A9"
  r <- modelCount c
  same "the model count" (either (const 0) id r) 2
  r <- keyInfo c
  same "the key" (either (const Nothing) (\k => Just (k.label, k.limit, k.limitRemaining, k.usage, k.freeTier)) r)
    (Just ("sk-or-v1-abc...xyz", Just 10.0, Just 7.5, Just 2.5, False))
  r <- credits c
  same "credits" (either (const Nothing) (\x => Just (x.purchased, x.used, remaining x)) r) (Just (25.0, 3.25, 21.75))
  r <- generation c "gen-mock-1"
  same "a generation" (either (const Nothing) (\g => Just (g.model, g.provider, g.cost, g.promptTokens, g.latency, g.streamed)) r)
    (Just ("mock/plain", Just "Mock", Just 0.000012, Just 7, Just 120.0, False))
  r <- generation c "gen-nope"
  same "a generation that does not exist" (outcome r) "api 404 Not found"
  r <- call c GET "/models/count" [] Nothing
  same "call reaches any endpoint" (either (const "") render r) #"{"data":{"count":2}}"#

media : Tally => Client -> IO ()
media c = do
  section "Mock: images and audio"
  let out = "test/build/media.bin"
  r <- generateImage c (imageRequest "mock/image" "a cat" [Count 2])
  same "an image request returns images" (either (const []) (map mediaType . images) r) [Just "image/png", Just "image/png"]
  n <- maybe (pure Nothing) (saveBase64 out . base64) (either (const Nothing) (head' . images) r)
  back <- readBase64 out
  same "an image is saved byte for byte" (n, back) (Just 16, Just "iVBORw0KGgoA//5hIGNhdA==")
  r <- generateImage c (imageRequest "mock/no-image" "a cat" [])
  same "an image request that is refused" (outcome r) "api 400 Model cannot make images"

  r <- speech c (speechRequest "mock/voice" "Hello" [Voice "v", SpeechFormat "mp3"]) out
  back <- readBase64 out
  same "speech is saved byte for byte, though it is not text" (either (const 0) id r) (768 + length "v|mp3|Hello")
  same "every byte value survives"
    (map (\b => (substr 0 12 b, substr 1016 8 b, substr 1024 16 b)) back)
    (Just ("AAECAwQFBgcI", "+vv8/f7/", "dnxtcDN8SGVsbG8="))
  r <- speech c (speechRequest "mock/mute" "Hello" []) out
  same "a speech request that is refused" (outcome r) "api 402 Insufficient credits"

  Just audio <- audioFile out
    | Nothing => check "a file is read as audio" False
  r <- transcribe c (transcriptionRequest "mock/ears" audio [Language "en", Verbose True])
  same "a transcription, with the audio sent whole"
    (either (const Nothing) (\t => Just (t.text, t.language, t.duration, map text t.segments, t.cost)) r)
    (Just ("heard 779 bytes of bin in en", Just "english", Just 1.5, ["heard"], Just 0.0002))
  r <- transcribe c (transcriptionRequest "mock/ears" (AudioURL "https://x/a.mp3") [])
  same "a transcription from a URL" (either (const "") text r) "heard 15 bytes of None in None"
  missing <- audioFile "test/build/no-such-file.wav"
  same "a file that is not there" (map (const ()) missing) Nothing

  r <- chatStream c (chatRequest "mock/media" ["Say hello and draw."] (spoken "alloy" "wav")) (\_ => pure ())
  same "a spoken reply: text, transcript and pictures"
    (either (const Nothing) (\x => Just (text x, map transcript (replyAudio x), map fromDataURI (replyImages x))) r)
    (Just ("Here. ", Just "Hello there", [Just ("image/png", "iVBORwBwaWM=")]))
  n <- maybe (pure Nothing) (saveBase64 out . base64) (either (const Nothing) replyAudio r)
  back <- readBase64 out
  same "audio streamed in separately encoded pieces decodes as one" (n, back) (Just 12, Just "UklGRgD//mFsbG95")
  r <- chat c (chatRequest "mock/media" ["Draw."] [Modalities ["image", "text"]])
  same "pictures in a plain reply" (either (const []) replyImages r) ["data:image/png;base64,iVBORw0KGgo=", "https://example.com/cat.png"]
  n <- maybe (pure Nothing) (saveDataURI out) (either (const Nothing) (head' . replyImages) r)
  u <- fileDataURI "image/png" out
  same "a data URI is saved, and a file becomes a data URI" (n, u) (Just 8, Just "data:image/png;base64,iVBORw0KGgo=")
  _ <- saveBase64 out "AAEC/w=="
  n <- saveWav out "test/build/media.wav" 24000
  w <- readBase64 "test/build/media.wav"
  same "PCM is wrapped in a WAV header" (n, w) (Just 48, Just "UklGRigAAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YQQAAAAAAQL/")
  n <- saveBase64 out "not base64!"
  same "text that is not base64 is refused" n Nothing

export
mockTests : Tally => (url : String) -> IO ()
mockTests url = do
  let c = { baseUrl := url, backoff := 50 } (newClient "test-key")
  basics c
  failures c
  streams c
  tools c
  structured c
  others c
  media c
