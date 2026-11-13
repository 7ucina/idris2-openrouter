||| Tests of everything that does no IO: JSON, schemas, the request and
||| response codecs, the event-stream decoder and the stream accumulator.
module Pure

import Data.List
import Data.String
import Harness
import OpenRouter
import OpenRouter.SSE

%default total
%ambiguity_depth 10

parsed : String -> JSON
parsed s = either (const (JString "<<not JSON>>")) id (parse s)

parseFails : String -> Maybe Nat
parseFails s = either (Just . offset) (const Nothing) (parse s)

--------------------------------------------------------------------------------
-- JSON
--------------------------------------------------------------------------------

jsonTests : Tally => IO ()
jsonTests = do
  section "JSON"
  let doc = #"{"a":[1,2.5,-300.0,true,false,null,"x"],"b":{},"c":[],"d":{"e":"\"\\\n"}}"#
  same "render . parse is the identity on compact text" (render (parsed doc)) doc
  same "whitespace is skipped" (parsed " { \"a\" :\n[ 1 ,\t2 ] } ") (parsed #"{"a":[1,2]}"#)
  same "an integer stays an integer" (render (parsed "256")) "256"
  same "a big integer keeps every digit" (render (parsed "123456789012345678901234567890")) "123456789012345678901234567890"
  check "1 is JInt" (case parsed "1" of JInt 1 => True; _ => False)
  check "1.0 is JNum" (case parsed "1.0" of JNum _ => True; _ => False)
  check "1e3 is JNum" (case parsed "1e3" of JNum x => x == 1000; _ => False)
  check "-0.5E-2 parses" (case parsed "-0.5E-2" of JNum x => x == -0.005; _ => False)
  same "JInt and JNum compare by value" (parsed "3") (parsed "3.0")
  same "a small double survives a round trip" (parsed (render (JNum 1.0e-7))) (JNum 1.0e-7)
  same "0.2 renders plainly" (render (JNum 0.2)) "0.2"
  same "NaN renders as null" (render (JNum (0.0 / 0.0))) "null"
  same "infinity renders as null" (render (JNum (1.0 / 0.0))) "null"

  same "escapes are written" (quote ("a\"b\\c\nd\te" ++ singleton (chr 1))) #""a\"b\\c\nd\te\u0001""#
  same "escapes are read" (parsed #""A\n\t\/\b\f\r\\\"""#) (JString "A\n\t/\b\f\r\\\"")
  same "non-ASCII passes through" (render (JString "héllo 😀")) "\"héllo 😀\""
  same "a surrogate pair is one character" (parsed #""😀""#) (JString "😀")
  same "a lone surrogate is replaced" (parsed #""a\ud83db""#) (JString ("a" ++ singleton (chr 0xFFFD) ++ "b"))
  same "a lone low surrogate is replaced" (parsed #""\ude00""#) (JString (singleton (chr 0xFFFD)))

  same "a missing value fails where it is missing" (parseFails #"{"a":}"#) (Just 5)
  same "a trailing comma fails" (parseFails "[1,]") (Just 3)
  same "a leading zero fails" (parseFails "01") (Just 0)
  same "an unterminated string fails" (parseFails "\"abc") (Just 4)
  same "a bad literal fails" (parseFails "tru") (Just 0)
  same "two values fail" (parseFails "1 2") (Just 2)
  same "an empty text fails" (parseFails "  ") (Just 2)
  same "a bare point fails" (parseFails "1.") (Just 2)
  same "a bare exponent fails" (parseFails "1e") (Just 2)
  same "a raw newline in a string fails" (parseFails "\"a\nb\"") (Just 2)
  same "a bad escape fails" (parseFails #""\q""#) (Just 2)

  let deep = replicate 20000 '[' ++ replicate 20000 ']'
  check "20,000 levels of nesting parse" (parseFails deep == Nothing)

  same "get on a missing key is null" (get "x" (parsed #"{"a":1}"#)) JNull
  same "get on a non-object is null" (get "x" (JInt 1)) JNull
  same "path walks down" (asString (path ["a", "b"] (parsed #"{"a":{"b":"c"}}"#))) (Just "c")
  same "asInteger takes 3.0" (asInteger (JNum 3.0)) (Just 3)
  same "asInteger refuses 3.5" (asInteger (JNum 3.5)) Nothing
  same "asNat refuses -1" (asNat (JInt (-1))) Nothing
  same "asAmount reads a price string" (asAmount (JString "0.00000015")) (Just 1.5e-7)
  same "asAmount refuses words" (asAmount (JString "free")) Nothing
  same "lastWins keeps the first position and the last value"
    (render (JObject (lastWins [("a", JInt 1), ("b", JInt 2), ("a", JInt 3)]))) #"{"a":3,"b":2}"#
  same "objectOf drops what is absent"
    (render (objectOf [field "a" (the Nat 1), optional "b" (the (Maybe String) Nothing), nonEmpty "c" (the (List String) []), optional "d" (Just True)]))
    #"{"a":1,"d":true}"#
  same "pretty indents" (pretty (parsed #"{"a":[1,{"b":null}],"c":{},"d":[]}"#))
    "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {},\n  \"d\": []\n}"

--------------------------------------------------------------------------------
-- Schemas
--------------------------------------------------------------------------------

Forecast : Type
Forecast = HList [String, Double, Maybe String, List String, Nat, String]

forecast : Schema Forecast
forecast = object
  [ prop "city" (string `describe` "The city's name")
  , prop "celsius" number
  , prop "advice" (nullable string)
  , prop "tags" (array string)
  , prop "days" natural
  , prop "unit" (enum ["c", "f"])
  ]

decoded : Schema a -> String -> Either String a
decoded s t = mapFst show (decodeText s t)

mismatch : Schema a -> String -> String
mismatch s t = either id (const "<<decoded>>") (decoded s t)

schemaTests : Tally => IO ()
schemaTests = do
  section "Schema"
  same "the JSON Schema of an object" (render (jsonSchema forecast))
    (#"{"type":"object","properties":{"city":{"type":"string","description":"The city's name"},"#
      ++ #""celsius":{"type":"number"},"advice":{"type":["string","null"]},"#
      ++ #""tags":{"type":"array","items":{"type":"string"}},"days":{"type":"integer"},"#
      ++ #""unit":{"type":"string","enum":["c","f"]}},"#
      ++ #""required":["city","celsius","advice","tags","days","unit"],"additionalProperties":false}"#)
  same "a nullable enum allows null" (render (jsonSchema (nullable (enum ["a"]))))
    #"{"type":["string","null"],"enum":["a",null]}"#
  same "a nullable object allows null" (render (jsonSchema (nullable (object [prop "x" boolean]))))
    #"{"type":["object","null"],"properties":{"x":{"type":"boolean"}},"required":["x"],"additionalProperties":false}"#
  same "a nullable raw schema is wrapped" (render (jsonSchema (nullable (SRaw (JObject [("const", JInt 1)])))))
    #"{"anyOf":[{"const":1},{"type":"null"}]}"#

  case decodeText forecast #"{"city":"Oslo","celsius":-3,"tags":["a","b"],"days":2,"unit":"c","extra":1}"# of
    Right [city, celsius, advice, tags, days, unit] => do
      same "a string property" city "Oslo"
      same "an integer is accepted as a number" celsius (-3.0)
      same "an absent nullable property is Nothing" advice Nothing
      same "an array property" tags ["a", "b"]
      same "a refined property" days 2
      same "an enum property" unit "c"
    Left m => check ("a fitting object decodes: " ++ show m) False

  same "a missing property" (mismatch forecast #"{"celsius":1}"#) "$.city: missing"
  same "a wrong type, with its place"
    (mismatch forecast #"{"city":"x","celsius":1,"tags":["a",2],"days":1,"unit":"c"}"#)
    "$.tags[1]: expected a string, found an integer"
  same "a value outside an enum"
    (mismatch forecast #"{"city":"x","celsius":1,"tags":[],"days":1,"unit":"k"}"#)
    #"$.unit: "k" is not one of "c", "f""#
  same "a refinement that rejects"
    (mismatch forecast #"{"city":"x","celsius":1,"tags":[],"days":-1,"unit":"c"}"#)
    "$.days: expected a number that is not negative"
  same "a fraction is not an integer" (mismatch integer "1.5") "$: expected an integer, found a number"
  same "text that is not JSON" (mismatch integer "one") "$: not JSON: unexpected character at character 0"
  same "map changes what is read" (decoded (map length (array boolean)) "[true,false]") (Right 2)
  same "a nested array of objects"
    (decoded (array (object [prop "n" integer])) #"[{"n":1},{"n":2}]"# <&> map (\[n] => n))
    (Right [1, 2])

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

requestTests : Tally => IO ()
requestTests = do
  section "Request"
  same "a minimal request"
    (render (toJSON (chatRequest "m" ["Hi"] [])))
    #"{"model":"m","messages":[{"role":"user","content":"Hi"}]}"#
  same "sampling options, in the order given"
    (render (toJSON (chatRequest "m" [] [Temperature 0.5, TopP 0.9, TopK 40, Seed 7, MaxTokens 256, Stop ["a", "b"]])))
    #"{"model":"m","messages":[],"temperature":0.5,"top_p":0.9,"top_k":40,"seed":7,"max_tokens":256,"stop":["a","b"]}"#
  same "a later option replaces an earlier one"
    (render (toJSON (withOptions [Temperature 1.0] (chatRequest "m" [] [Temperature 0.5, Seed 1]))))
    #"{"model":"m","messages":[],"temperature":1.0,"seed":1}"#
  same "Field sets anything, the model included"
    (render (toJSON (chatRequest "m" [] [Field "model" (JString "n"), Field "x" JNull])))
    #"{"model":"n","messages":[],"x":null}"#
  same "stream is added when streaming"
    (render (chatBody True (chatRequest "m" [] [])))
    #"{"model":"m","messages":[],"stream":true}"#
  same "reasoning and provider objects"
    (render (toJSON (chatRequest "m" []
       [ Reasoning [Effort High, Exclude True]
       , Provider [Order ["a", "b"], AllowFallbacks False, DataCollection Deny, Sort Throughput, MaxPrice [("prompt", 1.5)]]
       , Fallbacks ["x/y"] ])))
    (#"{"model":"m","messages":[],"reasoning":{"effort":"high","exclude":true},"#
      ++ #""provider":{"order":["a","b"],"allow_fallbacks":false,"data_collection":"deny","sort":"throughput","max_price":{"prompt":1.5}},"#
      ++ #""models":["x/y"]}"#)
  same "tools and tool choice"
    (render (toJSON (chatRequest "m" []
       [ Tools [tool "get" "Gets." (object [prop "q" string])], ToolChoice (Function "get"), ParallelToolCalls False ])))
    (#"{"model":"m","messages":[],"tools":[{"type":"function","function":{"name":"get","description":"Gets.","#
      ++ #""parameters":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"],"additionalProperties":false}}}],"#
      ++ #""tool_choice":{"type":"function","function":{"name":"get"}},"parallel_tool_calls":false}"#)
  same "a strict tool says so"
    (render (toJSON (strictTool (tool "t" "d" boolean))))
    #"{"type":"function","function":{"name":"t","description":"d","parameters":{"type":"boolean"},"strict":true}}"#
  same "response formats"
    (render (toJSON (chatRequest "m" [] [ResponseFormat JSONObject, ResponseFormat (schemaFormat "n" integer)])))
    #"{"model":"m","messages":[],"response_format":{"type":"json_schema","json_schema":{"name":"n","strict":true,"schema":{"type":"integer"}}}}"#
  same "logprobs, logit bias, plugins"
    (render (toJSON (chatRequest "m" [] [Logprobs True, TopLogprobs 3, LogitBias [(50256, -100)], Plugins [webSearch], EndUser "u1"])))
    #"{"model":"m","messages":[],"logprobs":true,"top_logprobs":3,"logit_bias":{"50256":-100.0},"plugins":[{"id":"web"}],"user":"u1"}"#

  same "message roles"
    (render (toJSON [system "s", developer "d", user "u", assistant "a"]))
    #"[{"role":"system","content":"s"},{"role":"developer","content":"d"},{"role":"user","content":"u"},{"role":"assistant","content":"a"}]"#
  same "content parts"
    (render (toJSON (userParts [Text "t", Image "http://i", ImageAt LowDetail "data:x", File "a.pdf" "data:y", Audio "QUJD" "wav"])))
    (#"{"role":"user","content":[{"type":"text","text":"t"},{"type":"image_url","image_url":{"url":"http://i"}},"#
      ++ #"{"type":"image_url","image_url":{"url":"data:x","detail":"low"}},"#
      ++ #"{"type":"file","file":{"filename":"a.pdf","file_data":"data:y"}},"#
      ++ #"{"type":"input_audio","input_audio":{"data":"QUJD","format":"wav"}}]}"#)
  same "a cache breakpoint on plain text"
    (render (toJSON (cached (system "long"))))
    #"{"role":"system","content":[{"type":"text","text":"long","cache_control":{"type":"ephemeral"}}]}"#
  same "a cache breakpoint goes on the last part"
    (render (toJSON (cached (userParts [Text "a", Text "b"]))))
    #"{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b","cache_control":{"type":"ephemeral"}}]}"#
  same "an assistant message that calls a tool, and its result"
    (render (toJSON [MkMessage Assistant Nothing Nothing [MkToolCall "c1" "get" "{}"] Nothing [], toolResult "c1" "42"]))
    (#"[{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get","arguments":"{}"}}]},"#
      ++ #"{"role":"tool","content":"42","tool_call_id":"c1"}]"#)
  same "completion and embedding requests"
    (render (toJSON (completionRequest "m" "Once" [MaxTokens 5])) ++ render (toJSON (embeddingRequest "e" ["a", "b"] [Field "dimensions" (JInt 8)])))
    #"{"model":"m","prompt":"Once","max_tokens":5}{"model":"e","input":["a","b"],"dimensions":8}"#

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

sample : String
sample = """
  {"id":"gen-1","provider":"Acme","model":"a/b","object":"chat.completion","created":1700000000,
   "choices":[{"index":0,"finish_reason":"tool_calls","native_finish_reason":"tool_use",
     "logprobs":{"content":[{"token":"Hi","logprob":-0.25,"top_logprobs":[{"token":"Hi","logprob":-0.25},{"token":"Yo","logprob":-2}]}]},
     "message":{"role":"assistant","content":"Hi","reasoning":"thought","refusal":null,
       "reasoning_details":[{"type":"reasoning.text","text":"thought"}],
       "tool_calls":[{"id":"c1","type":"function","function":{"name":"get","arguments":"{\\"q\\":1}"}},
                     {"id":"c2","type":"function","function":{"name":"put","arguments":{"k":true}}}]}}],
   "usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"cost":0.00012,
     "completion_tokens_details":{"reasoning_tokens":2},"prompt_tokens_details":{"cached_tokens":4}}}
  """

describeError : Either Error a -> String
describeError (Right _)                  = "ok"
describeError (Left (Transport f))       = "transport"
describeError (Left (Api e))             = "api " ++ show e.status ++ " " ++ e.message
                                           ++ maybe "" (" by " ++) e.provider
                                           ++ maybe "" ((" after " ++) . show) e.retryAfter
describeError (Left (Malformed why _))   = "malformed"
describeError (Left (Mismatched m _))    = "mismatched " ++ show m

responseTests : Tally => IO ()
responseTests = do
  section "Response"
  let r = chatResponseFromJSON (parsed sample)
  same "id, model, provider" (r.id, r.model, r.provider) ("gen-1", "a/b", Just "Acme")
  same "created" r.created (Just 1700000000)
  same "text" (text r) "Hi"
  same "reasoning" (reasoningText r) "thought"
  same "finish reason" (finish r) (Just FinishToolCalls)
  same "native finish reason" (firstChoice r >>= nativeFinishReason) (Just "tool_use")
  same "tool calls, with object arguments rendered"
    (map (\c => (c.id, c.name, c.arguments)) (requestedTools r))
    [("c1", "get", #"{"q":1}"#), ("c2", "put", #"{"k":true}"#)]
  same "usage" (map (\u => (u.promptTokens, u.completionTokens, u.totalTokens, u.reasoningTokens, u.cachedTokens, u.cost)) r.usage)
    (Just (10, 5, 15, Just 2, Just 4, Just 0.00012))
  same "log probabilities" (map (\l => (l.token, l.logprob, l.top)) (maybe [] logprobs (firstChoice r)))
    [("Hi", -0.25, [("Hi", -0.25), ("Yo", -2.0)])]
  same "the reply keeps reasoning_details for the next request"
    (render (toJSON (reply r) |> get "reasoning_details")) #"[{"type":"reasoning.text","text":"thought"}]"#
  same "content given as parts is joined"
    (text (chatResponseFromJSON (parsed #"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"x"},{"type":"text","text":"b"}]}}]}"#)))
    "ab"
  same "an empty response has no text" (text (chatResponseFromJSON (parsed "{}"))) ""

  same "a 200 with JSON is fine" (describeError (interpret 200 Nothing "{}")) "ok"
  same "an error body with its status"
    (describeError (interpret 429 (Just 3) #"{"error":{"code":429,"message":"Slow down","metadata":{"provider_name":"Acme"}}}"#))
    "api 429 Slow down by Acme after 3"
  same "an error inside a 200 takes the error's code"
    (describeError (interpret 200 Nothing #"{"error":{"code":502,"message":"Provider returned error"}}"#))
    "api 502 Provider returned error"
  same "a string code is read" (describeError (interpret 200 Nothing #"{"error":{"code":"503","message":"x"}}"#)) "api 503 x"
  same "an error that is only a string" (describeError (interpret 400 Nothing #"{"error":"nope"}"#)) "api 400 nope"
  same "an HTML error page" (describeError (interpret 502 Nothing "<html>Bad Gateway</html>")) "api 502 <html>Bad Gateway</html>"
  same "an empty error body" (describeError (interpret 503 Nothing "")) "api 503 HTTP 503"
  same "a 200 that is not JSON" (describeError (interpret 200 Nothing "<html>")) "malformed"
  same "what is worth retrying"
    (map (\s => retryable (Api (MkApiError s "" Nothing JNull Nothing))) [400, 401, 402, 403, 404, 408, 422, 429, 500, 502, 503, 529])
    [False, False, False, False, False, True, False, True, True, True, True, True]

  let c = completionResponseFromJSON (parsed #"{"id":"g","model":"m","choices":[{"text":" blue","finish_reason":"length"}],"usage":{"prompt_tokens":1}}"#)
  same "a text completion" (completionText c, map finishReason c.choices) (" blue", [Just FinishLength])
  let e = embeddingResponseFromJSON (parsed #"{"model":"e","data":[{"index":1,"embedding":[3,4]},{"index":0,"embedding":[1,2.5]}]}"#)
  same "embeddings come back in input order" e.embeddings [[1.0, 2.5], [3.0, 4.0]]

  let m = modelFromJSON (parsed #"{"id":"a/b","name":"B","context_length":1000,"pricing":{"prompt":"0.000001","completion":"0.000002"},"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"top_provider":{"max_completion_tokens":50,"is_moderated":true},"supported_parameters":["tools"]}"#)
  same "a model" (m.id, m.contextLength, m.maxCompletionTokens, m.pricing.prompt, m.inputModalities, m.moderated, supports "tools" m, supports "seed" m)
    ("a/b", Just 1000, Just 50, Just 1.0e-6, ["text", "image"], True, True, False)
  let k = keyInfoFromJSON (parsed #"{"label":"sk-or-...","usage":2.5,"limit":null,"limit_remaining":null,"is_free_tier":true}"#)
  same "a key with no limit" (k.label, k.usage, k.limit, k.freeTier) ("sk-or-...", Just 2.5, Nothing, True)
  same "credits left" (remaining (creditsFromJSON (parsed #"{"total_credits":25,"total_usage":3.25}"#))) 21.75

mediaTests : Tally => IO ()
mediaTests = do
  section "Images and audio"
  same "an image request"
    (render (toJSON (imageRequest "m" "a cat" [AspectRatio "16:9", Resolution "2K", Quality "high", ImageFormat "webp", Count 2, Background "transparent", Seed 7, References ["https://x/y.png"]])))
    (#"{"model":"m","prompt":"a cat","aspect_ratio":"16:9","resolution":"2K","quality":"high","output_format":"webp","n":2,"background":"transparent","seed":7,"#
      ++ #""input_references":[{"type":"image_url","image_url":{"url":"https://x/y.png"}}]}"#)
  same "a speech request"
    (render (toJSON (speechRequest "m" "Hello" [Voice "alloy", SpeechFormat "mp3", Speed 1.25, Instructions "Warmly."])))
    #"{"model":"m","input":"Hello","voice":"alloy","response_format":"mp3","speed":1.25,"instructions":"Warmly."}"#
  same "a transcription request, from data and from a URL"
    (render (toJSON (transcriptionRequest "m" (AudioData "UklG" "wav") [Language "en", Keyterms ["Idris"], Verbose True]))
       ++ render (toJSON (transcriptionRequest "m" (AudioURL "https://x/a.mp3") [])))
    (#"{"model":"m","input_audio":{"data":"UklG","format":"wav"},"language":"en","keyterms":["Idris"],"response_format":"verbose_json"}"#
      ++ #"{"model":"m","input_audio":{"url":"https://x/a.mp3"}}"#)
  same "a chat request for a spoken reply"
    (render (toJSON (chatRequest "m" [] (spoken "alloy" "wav"))))
    #"{"model":"m","messages":[],"modalities":["text","audio"],"audio":{"voice":"alloy","format":"wav"}}"#

  let i = imageResponseFromJSON (parsed #"{"created":1,"data":[{"b64_json":"iVBOR","media_type":"image/png"},{"b64_json":"AAAA"},{"url":"x"}],"usage":{"cost":0.04}}"#)
  same "an image response" (map (\g => (g.base64, g.mediaType)) i.images, i.usage >>= cost)
    ([("iVBOR", Just "image/png"), ("AAAA", Nothing)], Just 0.04)
  let t = transcriptionFromJSON (parsed #"{"text":"Hi there.","language":"english","duration":1.5,"segments":[{"start":0,"end":1.5,"text":"Hi there."},{"start":2}],"usage":{"cost":0.0002,"seconds":1.5}}"#)
  same "a verbose transcription" (t.text, t.language, t.duration, map (\g => (g.start, g.end, g.text)) t.segments, t.cost)
    ("Hi there.", Just "english", Just 1.5, [(0.0, 1.5, "Hi there.")], Just 0.0002)
  let t' = transcriptionFromJSON (parsed #"{"text":"Hi.","usage":{"seconds":2.5}}"#)
  same "a plain transcription takes its duration from usage" (t'.text, t'.language, t'.duration, length t'.segments) ("Hi.", Nothing, Just 2.5, 0)

  let r = chatResponseFromJSON (parsed #"{"choices":[{"message":{"content":"A cat.","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBOR"}}],"audio":{"id":"a1","data":"UklG","transcript":"A cat."}}}]}"#)
  same "images in a chat reply" (replyImages r) ["data:image/png;base64,iVBOR"]
  same "audio in a chat reply" (map (\a => (a.base64, a.transcript)) (replyAudio r)) (Just ("UklG", "A cat."))
  same "a reply with neither" (replyImages (chatResponseFromJSON (parsed sample)), map transcript (replyAudio (chatResponseFromJSON (parsed sample)))) ([], Nothing)
  same "a data URI splits into type and payload" (fromDataURI "data:image/png;base64,iVBOR") (Just ("image/png", "iVBOR"))
  same "and is put back together" (dataURI "image/png" "iVBOR") "data:image/png;base64,iVBOR"
  same "a URL is not a data URI" (fromDataURI "https://example.com/a.png") Nothing
  same "a data URI that is not base64 is refused" (fromDataURI "data:text/plain,hello") Nothing

  let s = collectChunks $ map (chunkFromJSON . parsed)
        [ #"{"choices":[{"index":0,"delta":{"audio":{"data":"UklG","transcript":"Hel"}}}]}"#
        , #"{"choices":[{"index":0,"delta":{"audio":{"transcript":"lo"}}}]}"#
        , #"{"choices":[{"index":0,"delta":{"audio":{"data":"AAA="},"images":[{"image_url":{"url":"data:image/png;base64,AA"}}]}}]}"# ]
  same "streamed audio and images are collected"
    (map (\a => (a.base64, a.transcript)) (replyAudio s), replyImages s)
    (Just ("UklGAAA=", "Hello"), ["data:image/png;base64,AA"])

--------------------------------------------------------------------------------
-- Server-sent events
--------------------------------------------------------------------------------

feedAll : List String -> List Event
feedAll pieces =
  let (d, evs) = foldl (\(d, acc), p => let (d', es) = feed p d in (d', acc ++ es)) (start, []) pieces
   in evs ++ finish d

splitAt' : Nat -> String -> List String
splitAt' n s = [substr 0 n s, substr n (length s) s]

sseTests : Tally => IO ()
sseTests = do
  section "SSE"
  let stream = ": keep-alive\n\ndata: one\n\nevent: note\r\ndata: two\r\ndata: three\r\n\r\ndata:four\rid: 7\r\rretry: 5\n\ndata: {\"é\":\"😀\"}\n\n"
      want   = [ MkEvent Nothing "one", MkEvent (Just "note") "two\nthree", MkEvent Nothing "four"
               , MkEvent Nothing "{\"é\":\"😀\"}" ]
  same "a whole stream at once" (feedAll [stream]) want
  same "one character at a time" (feedAll (map singleton (unpack stream))) want
  check "cut in two at every position"
    (all (\n => feedAll (splitAt' n stream) == want) [0 .. length stream])
  same "an event cut off by the end of the stream is still delivered" (feedAll ["data: tail"]) [MkEvent Nothing "tail"]
  same "a line cut off after its carriage return" (feedAll ["data: x\r"]) [MkEvent Nothing "x"]
  same "an event with no data is dropped" (feedAll ["event: ping\n\n"]) []
  same "a data line with no colon is empty data" (feedAll ["data\n\n"]) [MkEvent Nothing ""]
  same "only one space after the colon is dropped" (feedAll ["data:  x\n\n"]) [MkEvent Nothing " x"]
  same "nothing in, nothing out" (feedAll []) []

--------------------------------------------------------------------------------
-- Streams
--------------------------------------------------------------------------------

chunks : List String -> List Chunk
chunks = map (chunkFromJSON . parsed)

streamTests : Tally => IO ()
streamTests = do
  section "Stream"
  let r = collectChunks $ chunks
        [ #"{"id":"g1","model":"a/b","provider":"Acme","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"hm. "}}]}"#
        , #"{"id":"g1","choices":[{"index":0,"delta":{"content":"Hel"}}]}"#
        , #"{"id":"g1","choices":[{"index":0,"delta":{"content":"lo","reasoning_details":[{"type":"reasoning.text","text":"hm. "}]}}]}"#
        , #"{"id":"g1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get","arguments":"{\"q\":"}}]}}]}"#
        , #"{"id":"g1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"put","arguments":""}},{"index":0,"function":{"arguments":"1}"}}]}}]}"#
        , #"{"id":"g1","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{}"}}]},"finish_reason":"tool_calls","native_finish_reason":"tool_use"}]}"#
        , #"{"id":"g1","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5,"cost":0.5}}"#
        ]
  same "id, model, provider" (r.id, r.model, r.provider) ("g1", "a/b", Just "Acme")
  same "text is joined" (text r) "Hello"
  same "reasoning is joined" (reasoningText r) "hm. "
  same "tool call fragments are merged by index"
    (map (\c => (c.id, c.name, c.arguments)) (requestedTools r))
    [("c1", "get", #"{"q":1}"#), ("c2", "put", "{}")]
  same "finish reasons" (finish r, firstChoice r >>= nativeFinishReason) (Just FinishToolCalls, Just "tool_use")
  same "usage from the last chunk" (map totalTokens r.usage, r.usage >>= cost) (Just 5, Just 0.5)
  same "reasoning_details are kept on the reply"
    (render (toJSON (reply r) |> get "reasoning_details")) #"[{"type":"reasoning.text","text":"hm. "}]"#

  let two = collectChunks $ chunks
        [ #"{"choices":[{"index":1,"delta":{"content":"B1"}}]}"#
        , #"{"choices":[{"index":0,"delta":{"content":"A1"}},{"index":1,"delta":{"content":"B2"},"finish_reason":"length"}]}"#
        , #"{"choices":[{"index":0,"delta":{"content":"A2"},"finish_reason":"stop"}]}"# ]
  same "choices are kept apart, in index order"
    (map (\c => (c.index, messageText c.message, c.finishReason)) two.choices)
    [(0, "A1A2", Just FinishStop), (1, "B1B2", Just FinishLength)]

  let noIndex = collectChunks $ chunks
        [ #"{"choices":[{"delta":{"tool_calls":[{"id":"x","function":{"name":"f","arguments":"{"}}]}}]}"#
        , #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"}"}}]}}]}"#
        , #"{"choices":[{"delta":{"tool_calls":[{"id":"y","function":{"name":"g","arguments":"[]"}}]}}]}"# ]
  same "tool calls without an index: an id starts a new call"
    (map (\c => (c.id, c.name, c.arguments)) (requestedTools noIndex))
    [("x", "f", "{}"), ("y", "g", "[]")]
  same "a reply that only calls tools has no content"
    (render (toJSON (reply noIndex) |> get "content")) "null"

  let bad = chunkFromJSON (parsed #"{"id":"g","error":{"code":502,"message":"Provider disconnected"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#)
  same "an error chunk is recognized" (map (\e => (e.status, e.message)) bad.error) (Just (502, "Provider disconnected"))
  same "a text completion chunk" (chunkText (chunkFromJSON (parsed #"{"choices":[{"index":0,"text":" blue"}]}"#))) " blue"
  same "nothing streamed is an empty response" (text (collectChunks []), length (collectChunks []).choices) ("", 0)

export
pureTests : Tally => IO ()
pureTests = do
  jsonTests
  schemaTests
  requestTests
  responseTests
  mediaTests
  sseTests
  streamTests
