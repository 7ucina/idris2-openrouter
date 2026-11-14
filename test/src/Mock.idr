||| The client against test/mock.py: every request path, with the failures a
||| real server produces. Needs no API key and spends nothing.
module Mock

import Data.IORef
import Data.List
import Data.String
import Harness
import OpenRouter
import OpenRouter.API as API
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
    (Just "https://example.com", Just "idris2-openrouter/0.4.0", Just "yes")

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

together : Tally => Client -> IO ()
together c = do
  section "Mock: requests at the same time"
  let wait : String -> ChatRequest
      wait n = chatRequest "mock/wait" [user n] []
      peak : IO (Maybe Integer)
      peak = seen c "_peak"
      reset : IO ()
      reset = ignore (call c GET "/../../_reset" [] Nothing)

  reset
  t0 <- millis
  rs <- chatAll c 0 (map wait ["a", "b", "c", "d", "e", "f"])
  t1 <- millis
  p <- peak
  same "replies come back in the requests' order" (map replyText rs)
    (map ("waited for " ++) ["a", "b", "c", "d", "e", "f"])
  check ("six one-second requests take about a second, not six (" ++ show (t1 - t0) ++ " ms)") (t1 - t0 < 3000)
  same "all six were in flight together" p (Just 6)

  reset
  t0 <- millis
  rs <- chatAll c 2 (map wait ["a", "b", "c", "d"])
  t1 <- millis
  p <- peak
  same "with a limit of two, two at a time" (p, map replyText rs) (Just 2, map ("waited for " ++) ["a", "b", "c", "d"])
  check ("so four take about two seconds (" ++ show (t1 - t0) ++ " ms)") (t1 - t0 >= 1900 && t1 - t0 < 4000)

  rs <- chatAll c 0 [wait "ok", chatRequest "mock/402" ["x"] [], chatRequest "mock/garbage" ["x"] []]
  same "one failure does not disturb the others" (map outcome rs) ["ok", "api 402 Insufficient credits", "malformed"]
  rs <- concurrently 3 (the (List (IO Nat)) [])
  same "nothing to run" rs []

  t0 <- millis
  slow <- async (chat c (wait "task"))
  early <- poll slow
  quick <- ask c "mock/plain" "meanwhile"
  t1 <- millis
  r <- await slow
  again <- await slow
  late <- poll slow
  same "a task runs while the caller carries on"
    (map replyText early, either (const "") id quick, t1 - t0 < 900)
    (Nothing, "You said: meanwhile | title=None | temp=None", True)
  same "await gives its result, as often as asked" (replyText r, replyText again, map replyText late)
    ("waited for task", "waited for task", Just "waited for task")

  texts <- concurrently 0 $ map (\n => do
             out <- newIORef ""
             r <- chatStreamText c (chatRequest "mock/stream" [user n] []) (\t => modifyIORef out (++ t))
             o <- readIORef out
             pure (o, replyText r)) ["1", "2", "3", "4", "5", "6", "7", "8"]
  same "eight streams at once keep their text apart" texts (replicate 8 ("Streamed héllo 😀 done", "Streamed héllo 😀 done"))

  big <- concurrently 8 (replicate 40 (models c []))
  same "forty requests through eight threads" (map (either (const 0) length) big) (replicate 40 2)

everyEndpoint : Tally => Client -> IO ()
everyEndpoint c = do
  section "Mock: the generated endpoint functions"
  let echo  = withHeaders [("X-Echo", "json")] c
      said  : Either Error JSON -> List String -> String
      said r keys = either (\e => "<<" ++ outcome (the (Either Error ()) (Left e)) ++ ">>") (\j => joinBy " " (map (\k => render (get k j)) keys)) r
  r <- API.listGuardrails echo [("limit", "20"), ("q", "a b")]
  same "a list, with its query" (said r ["method", "path"]) #""GET" "/api/v1/guardrails?limit=20&q=a%20b""#
  r <- API.getGuardrail echo "g/1 x"
  same "a path parameter is encoded" (said r ["method", "path"]) #""GET" "/api/v1/guardrails/g%2F1%20x""#
  r <- API.updateGuardrail echo "g1" (JObject [("name", JString "n")])
  same "a PATCH with a body" (said r ["method", "path", "type", "body"]) #""PATCH" "/api/v1/guardrails/g1" "application/json" {"name":"n"}"#
  r <- API.deleteGuardrail echo "g1"
  same "a DELETE" (said r ["method", "path", "auth"]) #""DELETE" "/api/v1/guardrails/g1" "Bearer test-key""#
  r <- API.getGeneration echo "gen-1"
  same "a required query parameter is an argument" (said r ["path"]) #""/api/v1/generation?id=gen-1""#
  r <- API.listImageModelEndpoints echo "openai" "gpt-image"
  same "two path parameters" (said r ["path"]) #""/api/v1/images/models/openai/gpt-image/endpoints""#
  r <- API.listVideosContent echo "job1" [("index", "0")] "test/build/echo.bin"
  same "a download that gets JSON instead of a file is an error" (outcome r) "malformed"
  r <- API.listVideosContent (withHeaders [("X-Echo", "bytes")] c) "job1" [("index", "0")] "test/build/echo.bin"
  back <- readBase64 "test/build/echo.bin"
  same "a download is written to its file" (either (const 0) id r, back)
    (39, Just "AP/+AS9hcGkvdjEvdmlkZW9zL2pvYjEvY29udGVudD9pbmRleD0w")
  r <- API.createAudioSpeech (withHeaders [("X-Echo", "bytes")] c) (JObject [("model", JString "m")]) "test/build/echo.bin"
  same "a download with a request body" (either (const 0) id r) 24
  r <- API.getCreditPurchasesSetupGuide (withHeaders [("X-Echo", "text")] c)
  same "an endpoint that answers with text" (either (const "") id r) "# /api/v1/credits/purchases"
  r <- API.deleteBatch (withHeaders [("X-Echo", "empty")] c) "b1"
  same "an empty success is null" (either (const "error") render r) "null"
  _ <- saveBase64 "test/build/upload.bin" "AAECAwQF"
  r <- API.uploadFile echo [("provider", "openai")] [FormFile "file" "test/build/upload.bin", FormField "purpose" "user_data"]
  same "a multipart upload" (said r ["method", "path", "type", "parts", "files"])
    #""POST" "/api/v1/files?provider=openai" "multipart/form-data" ["file","purpose"] ["upload.bin"]"#
  r <- API.uploadFile echo [] [FormFileAs "file" "test/build/upload.bin" "notes.pdf" "application/pdf"]
  same "an upload under another name and type" (said r ["files", "types"]) #"["notes.pdf"] ["application/pdf"]"#
  r <- API.createOauthToken echo [("grant_type", "client credentials"), ("a&b", "c=d")]
  same "form fields are encoded" (said r ["type", "body"])
    #""application/x-www-form-urlencoded" "grant_type=client%20credentials&a%26b=c%3Dd""#
  r <- API.createApiAlphaExtractions echo (JObject [])
  same "an endpoint outside /api/v1 is reached at the host's root" (said r ["path"]) #""/api/alpha/extractions""#
  r <- API.getModels (withHeaders [("X-Echo", "json")] ({ appTitle := Just "T", appUrl := Just "https://a.b", appCategories := ["x", "y"] } c)) []
  same "the generated functions go through the same client" (said r ["path", "auth"]) #""/api/v1/models" "Bearer test-key""#
  r <- API.listGuardrails ({ apiKey := "wrong" } c) []
  same "and report errors the same way" (said r []) "<<api 401 No auth credentials found>>"

responsesAPI : Tally => Client -> IO ()
responsesAPI c = do
  section "Mock: the Responses API"
  r <- respond c (responsesRequest "mock/r-plain" [say User "Hi"] [])
  same "a response: text, reasoning, citations, usage"
    (either (const Nothing) (\x => Just (outputText x, outputReasoning x, map url (outputCitations x), x.status, map totalTokens x.usage, x.usage >>= cost)) r)
    (Just ("Hello from the Responses API.", "Greeting.", ["https://example.com/a"], "completed", Just 18, Just 0.00003))
  r <- respond c (responsesRequest "mock/r-echo" [say User "Hi"] [MaxTokens 7, Instructions "Be brief."])
  same "the request on the wire"
    (either (const "") (\x => render (either (const JNull) id (parse (outputText x)))) r)
    #"{"model":"mock/r-echo","input":[{"type":"message","role":"user","content":"Hi"}],"max_output_tokens":7,"instructions":"Be brief."}"#
  pieces <- newIORef (the (List String) [])
  r <- respondStream c (responsesRequest "mock/r-plain" [say User "Hi"] []) $ \event =>
         modifyIORef pieces ((case event of
           TextDelta t => "text:" ++ t; ReasoningDelta t => "think:" ++ t; ArgumentsDelta t => "args:" ++ t
           ItemDone _ => "item"; OtherEvent t _ => t) ::)
  ps <- readIORef pieces
  same "a streamed response, event by event" (reverse ps)
    ["response.created", "think:Greeting.", "item", "text:Hello from ", "text:the Responses API.", "item", "args:{}"]
  same "ends with the whole response" (either (const Nothing) (\x => Just (outputText x, length x.output, map totalTokens x.usage)) r)
    (Just ("Hello from the Responses API.", 3, Just 18))
  out <- newIORef ""
  r <- respondStreamText c (responsesRequest "mock/r-plain" [say User "Hi"] []) (\t => modifyIORef out (++ t))
  o <- readIORef out
  same "respondStreamText hands over only text" o "Hello from the Responses API."
  r <- respondStream c (responsesRequest "mock/r-fail" [say User "Hi"] []) (\_ => pure ())
  same "a response that fails in the stream" (outcome r) "api 502 Upstream failed"
  r <- respond ({ retries := 0 } c) (responsesRequest "mock/r-fail" [say User "Hi"] [])
  same "a response that fails outright" (outcome r) "api 502 Upstream failed"
  calls <- newIORef (the (List (List Double)) [])
  let add = handler "add" "Add numbers." (object [prop "numbers" (array number)]) $ \[ns] => do
              modifyIORef calls (ns ::)
              pure (show (sum ns))
  r <- respondWithTools c [add] 3 (responsesRequest "mock/r-tools" [say User "Add 1, 2 and 3.5"] [])
  cs <- readIORef calls
  same "tools: called with typed arguments, results and reasoning sent back" (cs, either (const "") outputText r)
    ([[1.0, 2.0, 3.5]], "The sum is 6.5 (2 items came back).")
  r <- respondAs c "forecast" forecast (responsesRequest "mock/r-json" [say User "Oslo?"] [])
  case r of
    Right ([city, celsius, advice, tags], _) =>
      same "a typed reply" (city, celsius, advice, tags) ("Oslo", -3.5, Just "forecast", ["json_schema", "True"])
    Left e => check ("a typed reply: " ++ show e) False

messagesAPI : Tally => Client -> IO ()
messagesAPI c = do
  section "Mock: the Anthropic Messages API"
  r <- createMessage c (messagesRequest "mock/a-plain" 100 [userTurn "Hi"] [])
  same "a message" (either (const Nothing) (\x => Just (blocksText x.content, x.stopReason, map totalTokens x.usage, x.usage >>= cachedTokens)) r)
    (Just ("Hello from the Messages API.", Just "end_turn", Just 14, Just 2))
  r <- createMessage c (messagesRequest "mock/a-echo" 50 [userTurn "Hi"] [Instructions "Be brief.", Temperature 0.5])
  same "the request on the wire"
    (either (const "") (\x => render (either (const JNull) id (parse (blocksText x.content)))) r)
    #"{"model":"mock/a-echo","max_tokens":50,"messages":[{"role":"user","content":[{"type":"text","text":"Hi"}]}],"system":"Be brief.","temperature":0.5}"#
  let time = tool "get_time" "The time in a city." (object [prop "city" string])
      req  = messagesRequest "mock/a-tools" 100 [userTurn "What time is it in Paris?"] [Tools [time]]
  Right r1 <- createMessage c req
    | Left e => check ("a tool use comes back: " ++ show e) False
  same "the model asks for a tool" (map (\t => (t.id, t.name, t.arguments)) (toolUses r1.content), r1.stopReason)
    ([("toolu_1", "get_time", #"{"city":"Paris"}"#)], Just "tool_use")
  r2 <- createMessage c ({ messages $= (++ [replyTurn r1, MkTurn User [ToolOutput "toolu_1" "noon" False]]) } req)
  same "and answers once it has the result" (either (const "") (blocksText . content) r2) "It is noon."
  events <- newIORef (the (List String) [])
  r <- streamMessage c (messagesRequest "mock/a-plain" 100 [userTurn "Hi"] []) $ \event =>
         modifyIORef events ((case event of
           TextPiece t => "text:" ++ t; ThinkingPiece t => "think:" ++ t; InputPiece t => "input:" ++ t
           BlockDone _ => "block"; OtherMessageEvent t _ => t) ::)
  es <- readIORef events
  same "a streamed message, event by event" (reverse es)
    ["think:Greet ", "think:them.", "block", "text:Hello from ", "text:the Messages API.", "block", #"input:{"q": "#, #"input:"x"}"#, "block"]
  same "ends with the whole message, its blocks assembled"
    (either (const Nothing) (\x => Just (render (toJSON x.content), x.stopReason, map (\u => (u.promptTokens, u.completionTokens)) x.usage)) r)
    (Just ( #"[{"type":"thinking","thinking":"Greet them.","signature":"sig9"},{"type":"text","text":"Hello from the Messages API."},{"type":"tool_use","id":"toolu_2","name":"lookup","input":{"q":"x"}}]"#
          , Just "tool_use", Just (9, 5) ))
  out <- newIORef ""
  _ <- streamMessageText c (messagesRequest "mock/a-plain" 100 [userTurn "Hi"] []) (\t => modifyIORef out (++ t))
  o <- readIORef out
  same "streamMessageText hands over only text" o "Hello from the Messages API."
  r <- streamMessage c (messagesRequest "mock/a-overloaded" 100 [userTurn "Hi"] []) (\_ => pure ())
  same "an error in the stream" (outcome r) "api 200 Overloaded"

jobs : Tally => Client -> IO ()
jobs c = do
  section "Mock: rerank, video, files, batches"
  r <- rerank c (rerankRequest "mock/rerank" "capital of France" ["Berlin is in Germany.", "Paris is the capital of France.", "France makes wine."] [TopN 2])
  same "documents come back best first" (either (const []) (map (\x => (x.index, x.document)) . results) r)
    [(1, Just "Paris is the capital of France."), (2, Just "France makes wine.")]

  _ <- call c GET "/../../_reset" [] Nothing
  Right job <- submitVideo c (videoRequest "mock/video" "a cat" [Duration 4])
    | Left e => check ("a video job starts: " ++ show e) False
  same "a video job starts pending" (job.id, job.status) ("job-1", Pending)
  early <- videoJob c job.id
  same "and is in progress" (either (const Nothing) (Just . status) early) (Just InProgress)
  done <- awaitVideo c job.id 0 10
  same "awaitVideo waits for it" (either (const Nothing) (\x => Just (x.status, x.urls, x.cost)) done)
    (Just (Completed, ["http://127.0.0.1/v/job-1/0.mp4"], Just 0.25))
  n <- downloadVideo c job.id 0 "test/build/video.mp4"
  back <- readBase64 "test/build/video.mp4"
  same "and the video downloads" (either (const 0) id n, back) (19, Just "AAAAGGZ0eXBtcDQyaW5kZXg9MA==")
  Right bad <- submitVideo c (videoRequest "mock/video" "refuse this" [])
    | Left e => check ("a second job starts: " ++ show e) False
  failed <- awaitVideo c bad.id 0 10
  same "a job that fails says why" (either (const Nothing) (\x => Just (x.status, x.error)) failed) (Just (Failed, Just "Prompt was refused"))
  stuck <- awaitVideo c "job-1" 0 0
  same "awaiting with no tries just looks" (either (const Nothing) (Just . status) stuck) (Just Completed)
  r <- submitVideo c (videoRequest "mock/no-video" "a cat" [])
  same "a video request that is refused" (outcome r) "api 400 Model cannot make videos"
  r <- videoJob c "job-nope"
  same "a job that does not exist" (outcome r) "api 404 Job not found"

  _ <- saveBase64 "test/build/notes.txt" "aGVsbG8gZmlsZQ=="
  Right f <- storeFile c "test/build/notes.txt"
    | Left e => check ("a file uploads: " ++ show e) False
  same "an uploaded file" (f.id, f.filename, f.mediaType, f.size, f.downloadable) ("file-1", "notes.txt", Just "text/plain", Just 10, False)
  fs <- storedFiles c []
  i <- fileInfo c "file-1"
  same "is listed and looked up" (either (const []) (map (.id)) fs, either (const "") filename i) (["file-1"], "notes.txt")
  d <- downloadFile c "file-1" "test/build/dl.bin"
  same "an uploaded file cannot be downloaded" (outcome d) "api 400 Uploaded files cannot be downloaded"
  x <- removeFile c "file-1"
  fs <- storedFiles c []
  same "and is deleted" (outcome x, either (const [""]) (map (.id)) fs) ("ok", [])
  x <- removeFile c "file-1"
  same "deleting it again fails" (outcome x) "api 404 Not found"
  r <- storeFile c "test/build/no-such-file"
  same "uploading a file that is not there" (outcome r) "unreachable"

  let item : String -> String -> BatchItem
      item i q = MkBatchItem i (toJSON (chatRequest "mock/plain" [user q] []))
  Right b <- createBatch c "/v1/chat/completions" "mock/plain" [item "a" "one", item "b" "two", item "c" "three"]
    | Left e => check ("a batch is created: " ++ show e) False
  same "a new batch" (b.id, b.status, b.requests, b.completed, batchFinished b) ("batch-1", "validating", 3, 0, False)
  done <- awaitBatch c b.id 0 10
  same "awaitBatch waits for the results"
    (either (const Nothing) (\x => Just (x.status, x.completed, x.failed, map (\r => (r.customId, text (chatResponseFromJSON r.body), r.error)) x.results)) done)
    (Just ("completed", 2, 1, [("a", "batched: one", Nothing), ("b", "batched: two", Nothing), ("c", "", Just "Bad request in batch")]))
  bs <- batches c []
  x <- cancelBatch c b.id
  bs' <- batches c []
  same "batches are listed and deleted" (either (const []) (map (.id)) bs, outcome x, either (const [""]) (map (.id)) bs') (["batch-1"], "ok", [])

management : Tally => Client -> IO ()
management c = do
  section "Mock: catalog, keys, sign-in"
  m <- modelInfo c "mock/plain"
  same "one model, with its voices" (either (const Nothing) (\x => Just (x.name, x.contextLength, x.voices)) m) (Just ("Mock Plain", Just 128000, ["ada", "bo"]))
  ms <- availableModels c []
  z <- zdrEndpoints c
  ts <- serverTools c
  same "the models an account may use, ZDR endpoints, server tools"
    (either (const []) (map (.id)) ms, either (const []) (map providerName) z, either (const []) (mapMaybe (asString . get "type")) ts)
    (["mock/allowed"], ["Mock"], ["openrouter:web_search", "openrouter:datetime"])
  g <- generationContent c "gen-mock-1"
  same "a generation's stored content" (either (const "") (render . path ["output", "completion"]) g) #""You said: hi""#
  x <- reportGeneration c "gen-mock-1" "latency" "too slow"
  y <- reportGeneration c "gen-nope" "other" ""
  same "feedback on a generation" (outcome x, outcome y) ("ok", "api 404 Generation not found")
  a <- activity c [("date", "2026-01-01")]
  same "activity rows" (either (const []) (map (\r => (asString (get "model" r), asDouble (get "usage" r), asString (get "query" r)))) a)
    [(Just "mock/plain", Just 0.5, Just "date=2026-01-01")]

  Right (k, secret) <- createKey c "ci" (Just 5)
    | Left e => check ("a key is created: " ++ show e) False
  same "a new key, with its secret shown once" (k.name, k.hash, k.limit, k.disabled, secret) (Just "ci", Just "hash1", Just 5.0, False, "sk-or-v1-secret-hash1")
  _ <- createKey c "dev" Nothing
  ks <- apiKeys c []
  same "keys are listed" (either (const []) (map (\x => (x.name, x.limit))) ks) [(Just "ci", Just 5.0), (Just "dev", Nothing)]
  u <- updateKey c "hash1" [("disabled", JBool True), ("name", JString "ci-old")]
  one <- apiKeyInfo c "hash1"
  same "a key is changed" (either (const Nothing) (\x => Just (x.name, x.disabled)) u, either (const Nothing) (\x => Just (x.name, x.disabled)) one)
    (Just (Just "ci-old", True), Just (Just "ci-old", True))
  x <- deleteKey c "hash1"
  gone <- apiKeyInfo c "hash1"
  same "and deleted" (outcome x, outcome gone) ("ok", "api 404 Key not found")

  k <- exchangeAuthCode ({ apiKey := "" } c) "good-code" (Just ("verif", "S256"))
  same "a sign-in code is exchanged for the user's key" (either (const "") id k) "sk-or-v1-user-verif-S256"
  k <- exchangeAuthCode ({ apiKey := "" } c) "bad-code" Nothing
  same "a bad code is refused" (outcome k) "api 403 Invalid code"

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
  together c
  everyEndpoint c
  responsesAPI c
  messagesAPI c
  jobs c
  management c
