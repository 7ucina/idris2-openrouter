||| Responses and errors, decoded from JSON.
|||
||| Decoding is lenient: OpenRouter fronts hundreds of providers, and they do
||| not all fill in the same fields. A field that is missing or has an
||| unexpected type reads as `Nothing`, `""` or an empty list rather than
||| failing the whole response, and every record keeps the `raw` JSON it was
||| read from.
module OpenRouter.Response

import Data.List
import Data.Maybe
import Data.String
import OpenRouter.HTTP
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Schema

%default total

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

||| An error reported by OpenRouter or by the provider behind it.
public export
record ApiError where
  constructor MkApiError
  ||| The HTTP status. When the error arrived inside a 200 response or in the
  ||| middle of a stream, the error's own code.
  status     : Int
  message    : String
  ||| The provider that failed, when OpenRouter names one.
  provider   : Maybe String
  ||| Whatever else the error carried: moderation reasons, the provider's raw
  ||| error, and so on. `JNull` when there was nothing.
  metadata   : JSON
  ||| How many seconds the server asked to wait before trying again.
  retryAfter : Maybe Nat

public export
data Error : Type where
  ||| No response came back.
  Transport : Failure -> Error
  ||| OpenRouter or the provider refused or failed.
  Api       : ApiError -> Error
  ||| The response was not the JSON the API documents.
  Malformed : (reason : String) -> (body : String) -> Error
  ||| A structured reply did not fit its schema. `text` is what the model wrote.
  Mismatched : Mismatch -> (text : String) -> Error

clip : Nat -> String -> String
clip n s = if length s > n then substr 0 n s ++ "..." else s

export
Show ApiError where
  show e = "HTTP " ++ show e.status ++ ": " ++ e.message
        ++ maybe "" (\p => " (provider: " ++ p ++ ")") e.provider

export
Show Error where
  show (Transport f)     = "no response: " ++ show f
  show (Api e)           = show e
  show (Malformed why b) = "unreadable response (" ++ why ++ "): " ++ clip 200 b
  show (Mismatched m t)  = "the reply does not fit the schema (" ++ show m ++ "): " ++ clip 200 t

||| Whether the same request might succeed if sent again: a transport
||| failure, a timeout, a rate limit, or a server-side error. A bad request,
||| a bad key, a lack of credits and a moderation block are not.
export
retryable : Error -> Bool
retryable (Transport _) = True
retryable (Api e)       = e.status == 408 || e.status == 429 || e.status >= 500
retryable _             = False

errorFromJSON : (httpStatus : Int) -> (retryAfter : Maybe Nat) -> JSON -> ApiError
errorFromJSON status after e =
  let code = case get "code" e of
               JString s => parseInteger {a = Integer} s
               j         => asInteger j
      meta = get "metadata" e
   in MkApiError
        (if status >= 200 && status < 300 then maybe status cast code else status)
        (case e of
           JString s => s
           _         => fromMaybe ("HTTP " ++ show status) (asString (get "message" e)))
        (asString (get "provider_name" meta))
        meta
        after

||| The error a chunk or a response body carries in its `error` field.
export
embeddedError : JSON -> Maybe ApiError
embeddedError j = case get "error" j of
  JNull => Nothing
  e     => Just (errorFromJSON 200 Nothing e)

||| Turn a status and a body into the JSON of a successful response, or the
||| error. An error object counts as an error whatever the status: OpenRouter
||| answers 200 when a provider fails after the response has begun.
export
interpret : (status : Int) -> (retryAfter : Maybe Nat) -> (body : String) -> Either Error JSON
interpret status after body =
  let ok = status >= 200 && status < 300
   in if ok && trim body == "" then Right JNull   -- a success with nothing to say
      else case parse body of
        Left e =>
          if ok then Left (Malformed (show e) body)
          else Left (Api (MkApiError status
                 (if trim body == "" then "HTTP " ++ show status else clip 500 (trim body))
                 Nothing JNull after))
        Right j => case get "error" j of
          JNull => if ok then Right j
                   else Left (Api (MkApiError status (clip 500 body) Nothing JNull after))
          e     =>
            -- Inside a success, only an error object counts: a job that
            -- failed reports why in an `error` string, and is still an answer.
            if ok && not (isErrorObject e) then Right j
            else Left (Api (errorFromJSON status after e))
  where
    isErrorObject : JSON -> Bool
    isErrorObject e = not (isNull (get "message" e)) || not (isNull (get "code" e))

--------------------------------------------------------------------------------
-- Usage
--------------------------------------------------------------------------------

public export
record Usage where
  constructor MkUsage
  promptTokens     : Nat
  completionTokens : Nat
  totalTokens      : Nat
  ||| The part of `completionTokens` spent on reasoning, when reported.
  reasoningTokens  : Maybe Nat
  ||| The part of `promptTokens` read from a cache, when reported.
  cachedTokens     : Maybe Nat
  ||| The part of `promptTokens` written to a cache, when reported.
  cacheWriteTokens : Maybe Nat
  ||| What the request cost, in credits (US dollars).
  cost             : Maybe Double
  raw              : JSON

export
usageFromJSON : JSON -> Maybe Usage
usageFromJSON JNull = Nothing
usageFromJSON j = Just $ MkUsage
  (fromMaybe 0 (asNat (get "prompt_tokens" j)))
  (fromMaybe 0 (asNat (get "completion_tokens" j)))
  (fromMaybe 0 (asNat (get "total_tokens" j)))
  (asNat (path ["completion_tokens_details", "reasoning_tokens"] j))
  (asNat (path ["prompt_tokens_details", "cached_tokens"] j))
  (asNat (path ["prompt_tokens_details", "cache_write_tokens"] j))
  (asDouble (get "cost" j))
  j

--------------------------------------------------------------------------------
-- Chat responses
--------------------------------------------------------------------------------

||| Why a model stopped.
public export
data FinishReason : Type where
  ||| It was done, or it reached a stop string.
  FinishStop          : FinishReason
  ||| It ran out of tokens.
  FinishLength        : FinishReason
  ||| It wants tools run.
  FinishToolCalls     : FinishReason
  ||| A content filter cut it off.
  FinishContentFilter : FinishReason
  ||| The provider failed midway.
  FinishError         : FinishReason
  FinishOther         : String -> FinishReason

export
Show FinishReason where
  show FinishStop          = "stop"
  show FinishLength        = "length"
  show FinishToolCalls     = "tool_calls"
  show FinishContentFilter = "content_filter"
  show FinishError         = "error"
  show (FinishOther s)     = s

export
Eq FinishReason where
  a == b = show a == show b

export
parseFinishReason : String -> FinishReason
parseFinishReason "stop"           = FinishStop
parseFinishReason "length"         = FinishLength
parseFinishReason "tool_calls"     = FinishToolCalls
parseFinishReason "content_filter" = FinishContentFilter
parseFinishReason "error"          = FinishError
parseFinishReason s                = FinishOther s

||| A generated token, its log probability, and the likeliest tokens at its
||| position (when `TopLogprobs` asked for them).
public export
record TokenLogprob where
  constructor MkTokenLogprob
  token   : String
  logprob : Double
  top     : List (String, Double)

export
logprobsFromJSON : JSON -> List TokenLogprob
logprobsFromJSON j = mapMaybe one (asList (get "content" j))
  where
    alt : JSON -> Maybe (String, Double)
    alt a = [| MkPair (asString (get "token" a)) (asDouble (get "logprob" a)) |]

    one : JSON -> Maybe TokenLogprob
    one t = [| MkTokenLogprob (asString (get "token" t)) (asDouble (get "logprob" t))
                              (pure (mapMaybe alt (asList (get "top_logprobs" t)))) |]

||| A source a model cited, from a web search or a file.
public export
record Citation where
  constructor MkCitation
  url   : String
  title : Maybe String
  ||| The stretch of the reply's text the citation supports, as character
  ||| offsets, when given.
  span  : Maybe (Nat, Nat)

||| The URL citations in a message's or a content part's `annotations`.
export
citationsFromJSON : JSON -> List Citation
citationsFromJSON = mapMaybe one . asList
  where
    one : JSON -> Maybe Citation
    one a =
      -- chat nests the fields under "url_citation"; the Responses API does not
      let c = case get "url_citation" a of
                JNull => a
                inner => inner
       in if asString (get "type" a) /= Just "url_citation" then Nothing
          else (\u => MkCitation u (asString (get "title" c))
                        [| MkPair (asNat (get "start_index" c)) (asNat (get "end_index" c)) |])
                 <$> asString (get "url" c)

||| Audio a chat model spoke.
public export
record SpokenAudio where
  constructor MkSpokenAudio
  ||| The audio's bytes in base64, in the format the request asked for.
  ||| `writeBase64` from `OpenRouter.HTTP` saves it to a file.
  base64     : String
  ||| What was said.
  transcript : String

public export
record Choice where
  constructor MkChoice
  index              : Nat
  ||| The assistant's message, ready to be appended to the conversation.
  message            : Message
  finishReason       : Maybe FinishReason
  ||| The provider's own word for why it stopped.
  nativeFinishReason : Maybe String
  ||| The model's reasoning, when it reasoned and the reasoning was not excluded.
  reasoning          : Maybe String
  ||| Set when the model declined to answer.
  refusal            : Maybe String
  logprobs           : List TokenLogprob
  ||| Images the model made, each as a `data:image/png;base64,...` URI.
  images             : List String
  ||| What the model spoke, when the request asked for audio.
  audio              : Maybe SpokenAudio
  ||| The sources the reply cites, when the model searched the web.
  citations          : List Citation
  ||| The choice as it arrived; `JNull` when it was assembled from a stream.
  raw                : JSON

nonBlank : JSON -> Maybe String
nonBlank j = asString j >>= \s => if s == "" then Nothing else Just s

||| The URLs in a message's or a delta's `images` array.
export
imageURLs : JSON -> List String
imageURLs = mapMaybe (\i => asString (path ["image_url", "url"] i)) . asList

spokenAudio : JSON -> Maybe SpokenAudio
spokenAudio JNull = Nothing
spokenAudio a     = Just (MkSpokenAudio (fromMaybe "" (asString (get "data" a)))
                                        (fromMaybe "" (asString (get "transcript" a))))

export
choiceFromJSON : JSON -> Choice
choiceFromJSON j =
  let m = get "message" j
   in MkChoice
        (fromMaybe 0 (asNat (get "index" j)))
        (messageFromJSON m)
        (parseFinishReason <$> asString (get "finish_reason" j))
        (asString (get "native_finish_reason" j))
        (nonBlank (get "reasoning" m))
        (nonBlank (get "refusal" m))
        (logprobsFromJSON (get "logprobs" j))
        (imageURLs (get "images" m))
        (spokenAudio (get "audio" m))
        (citationsFromJSON (get "annotations" m))
        j

public export
record ChatResponse where
  constructor MkChatResponse
  ||| The generation id, which `generation` looks up afterwards.
  id       : String
  ||| The model that answered. A fallback or a router can make it differ from
  ||| the one asked for.
  model    : String
  ||| The provider that served the request.
  provider : Maybe String
  ||| When the response was made, in seconds since 1970.
  created  : Maybe Integer
  choices  : List Choice
  usage    : Maybe Usage
  ||| The response as it arrived; `JNull` when it was assembled from a stream.
  raw      : JSON

export
chatResponseFromJSON : JSON -> ChatResponse
chatResponseFromJSON j = MkChatResponse
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "model" j)))
  (asString (get "provider" j))
  (asInteger (get "created" j))
  (map choiceFromJSON (asList (get "choices" j)))
  (usageFromJSON (get "usage" j))
  j

||| The first choice, which is the only one unless more were asked for.
export
firstChoice : ChatResponse -> Maybe Choice
firstChoice r = head' r.choices

||| The text of the reply, or `""` when there is none (a reply that only
||| calls tools, for one).
export
text : ChatResponse -> String
text r = maybe "" (messageText . message) (firstChoice r)

||| The assistant's message, to append to the conversation.
export
reply : ChatResponse -> Maybe Message
reply r = message <$> firstChoice r

||| The tools the model asked to run.
export
requestedTools : ChatResponse -> List ToolCall
requestedTools r = maybe [] (toolCalls . message) (firstChoice r)

||| Why the model stopped.
export
finish : ChatResponse -> Maybe FinishReason
finish r = firstChoice r >>= finishReason

||| The model's reasoning, or `""`.
export
reasoningText : ChatResponse -> String
reasoningText r = fromMaybe "" (firstChoice r >>= reasoning)

||| The images in the reply, each as a data URI.
export
replyImages : ChatResponse -> List String
replyImages r = maybe [] images (firstChoice r)

||| The sources the reply cites.
export
replyCitations : ChatResponse -> List Citation
replyCitations r = maybe [] citations (firstChoice r)

||| The audio of the reply, when the request asked for one.
export
replyAudio : ChatResponse -> Maybe SpokenAudio
replyAudio r = firstChoice r >>= audio

||| Split a data URI into its media type and its base64 payload:
||| `"data:image/png;base64,iVBOR..."` gives `("image/png", "iVBOR...")`.
||| `Nothing` for anything else, an `https:` URL included.
export
fromDataURI : String -> Maybe (String, String)
fromDataURI s =
  if not (isPrefixOf "data:" s) then Nothing
  else case break (== ',') (unpack (substr 5 (length s) s)) of
    (meta, ',' :: payload) =>
      let m = pack meta
       in if isSuffixOf ";base64" m
             then Just (substr 0 (length m `minus` 7) m, pack payload)
             else Nothing
    _ => Nothing

||| A data URI for base64 data of the given media type, for `Image`, `File`
||| and `References`.
export
dataURI : (mediaType : String) -> (base64 : String) -> String
dataURI m b = "data:" ++ m ++ ";base64," ++ b

--------------------------------------------------------------------------------
-- Text completion responses
--------------------------------------------------------------------------------

public export
record Completion where
  constructor MkCompletion
  index        : Nat
  text         : String
  finishReason : Maybe FinishReason
  raw          : JSON

public export
record CompletionResponse where
  constructor MkCompletionResponse
  id       : String
  model    : String
  provider : Maybe String
  choices  : List Completion
  usage    : Maybe Usage
  raw      : JSON

export
completionResponseFromJSON : JSON -> CompletionResponse
completionResponseFromJSON j = MkCompletionResponse
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "model" j)))
  (asString (get "provider" j))
  (map one (asList (get "choices" j)))
  (usageFromJSON (get "usage" j))
  j
  where
    one : JSON -> Completion
    one c = MkCompletion
      (fromMaybe 0 (asNat (get "index" c)))
      (fromMaybe "" (asString (get "text" c)))
      (parseFinishReason <$> asString (get "finish_reason" c))
      c

||| The text of the first completion, or `""`.
export
completionText : CompletionResponse -> String
completionText r = maybe "" (.text) (head' r.choices)

--------------------------------------------------------------------------------
-- Embedding responses
--------------------------------------------------------------------------------

public export
record EmbeddingResponse where
  constructor MkEmbeddingResponse
  model      : String
  ||| One vector per input, in the order the inputs were given.
  embeddings : List (List Double)
  usage      : Maybe Usage
  raw        : JSON

export
embeddingResponseFromJSON : JSON -> EmbeddingResponse
embeddingResponseFromJSON j =
  let rows = sortBy (\a, b => compare (fst a) (fst b)) (zipWith row [0 .. length items] items)
   in MkEmbeddingResponse
        (fromMaybe "" (asString (get "model" j)))
        (map snd rows)
        (usageFromJSON (get "usage" j))
        j
  where
    items : List JSON
    items = asList (get "data" j)

    row : Nat -> JSON -> (Nat, List Double)
    row i e = (fromMaybe i (asNat (get "index" e)), mapMaybe asDouble (asList (get "embedding" e)))

--------------------------------------------------------------------------------
-- Image responses
--------------------------------------------------------------------------------

public export
record GeneratedImage where
  constructor MkGeneratedImage
  ||| The image's bytes in base64. `writeBase64` from `OpenRouter.HTTP`
  ||| saves them to a file.
  base64    : String
  ||| As `"image/png"`, when the provider says.
  mediaType : Maybe String

public export
record ImageResponse where
  constructor MkImageResponse
  images : List GeneratedImage
  usage  : Maybe Usage
  raw    : JSON

export
imageResponseFromJSON : JSON -> ImageResponse
imageResponseFromJSON j = MkImageResponse
  (mapMaybe one (asList (get "data" j)))
  (usageFromJSON (get "usage" j))
  j
  where
    one : JSON -> Maybe GeneratedImage
    one i = (\b => MkGeneratedImage b (asString (get "media_type" i))) <$> asString (get "b64_json" i)

--------------------------------------------------------------------------------
-- Transcriptions
--------------------------------------------------------------------------------

||| A stretch of a transcript, with its times in seconds.
public export
record Segment where
  constructor MkSegment
  start : Double
  end   : Double
  text  : String

public export
record Transcription where
  constructor MkTranscription
  text     : String
  ||| The language heard. With `Verbose True`.
  language : Maybe String
  ||| The length of the audio, in seconds. With `Verbose True`, or from usage.
  duration : Maybe Double
  ||| Timed segments. With `Verbose True`.
  segments : List Segment
  ||| What the request cost, in credits.
  cost     : Maybe Double
  raw      : JSON

export
transcriptionFromJSON : JSON -> Transcription
transcriptionFromJSON j = MkTranscription
  (fromMaybe "" (asString (get "text" j)))
  (asString (get "language" j))
  (asDouble (get "duration" j) <|> asDouble (path ["usage", "seconds"] j))
  (mapMaybe segment (asList (get "segments" j)))
  (asDouble (path ["usage", "cost"] j))
  j
  where
    segment : JSON -> Maybe Segment
    segment s = [| MkSegment (asDouble (get "start" s)) (asDouble (get "end" s)) (asString (get "text" s)) |]

--------------------------------------------------------------------------------
-- Rerank responses
--------------------------------------------------------------------------------

public export
record RerankResult where
  constructor MkRerankResult
  ||| Which of the request's documents this is, counting from 0.
  index    : Nat
  ||| How well it answers the query; higher is better.
  score    : Double
  document : Maybe String

public export
record RerankResponse where
  constructor MkRerankResponse
  model   : String
  ||| The documents, best first.
  results : List RerankResult
  cost    : Maybe Double
  raw     : JSON

export
rerankResponseFromJSON : JSON -> RerankResponse
rerankResponseFromJSON j = MkRerankResponse
  (fromMaybe "" (asString (get "model" j)))
  (mapMaybe one (asList (get "results" j)))
  (asDouble (path ["usage", "cost"] j))
  j
  where
    one : JSON -> Maybe RerankResult
    one r = [| MkRerankResult (asNat (get "index" r)) (asDouble (get "relevance_score" r))
                              (pure (asString (path ["document", "text"] r) <|> asString (get "document" r))) |]

--------------------------------------------------------------------------------
-- Video jobs
--------------------------------------------------------------------------------

public export
data JobStatus = Pending | InProgress | Completed | Failed | Cancelled | Expired | OtherStatus String

export
Show JobStatus where
  show Pending         = "pending"
  show InProgress      = "in_progress"
  show Completed       = "completed"
  show Failed          = "failed"
  show Cancelled       = "cancelled"
  show Expired         = "expired"
  show (OtherStatus s) = s

export
Eq JobStatus where
  a == b = show a == show b

export
parseJobStatus : String -> JobStatus
parseJobStatus "pending"     = Pending
parseJobStatus "validating"  = Pending
parseJobStatus "in_progress" = InProgress
parseJobStatus "finalizing"  = InProgress
parseJobStatus "cancelling"  = InProgress
parseJobStatus "completed"   = Completed
parseJobStatus "failed"      = Failed
parseJobStatus "cancelled"   = Cancelled
parseJobStatus "expired"     = Expired
parseJobStatus s             = OtherStatus s

||| Whether a job has stopped, for better or worse.
export
finished : JobStatus -> Bool
finished Pending    = False
finished InProgress = False
finished _          = True

||| A video being made, or made.
public export
record VideoJob where
  constructor MkVideoJob
  id     : String
  status : JobStatus
  ||| Where the finished videos are, once the job has completed.
  urls   : List String
  ||| Why the job failed, when it did.
  error  : Maybe String
  cost   : Maybe Double
  raw    : JSON

export
videoJobFromJSON : JSON -> VideoJob
videoJobFromJSON j = MkVideoJob
  (fromMaybe "" (asString (get "id" j)))
  (maybe (OtherStatus "") parseJobStatus (asString (get "status" j)))
  (case asStrings (get "unsigned_urls" j) of
     [] => asStrings (get "urls" j)
     us => us)
  (asString (get "error" j))
  (asDouble (path ["usage", "cost"] j))
  j
