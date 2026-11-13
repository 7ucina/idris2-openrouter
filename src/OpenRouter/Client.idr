||| The client: every function that talks to OpenRouter.
|||
||| Each one returns `Either Error a` and never throws. A request that fails
||| in a way that may pass (see `retryable`) is sent again, with a growing
||| pause, before the error is returned.
module OpenRouter.Client

import Data.IORef
import Data.List
import Data.List1
import Data.Maybe
import Data.So
import Data.String
import OpenRouter.HTTP
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Model
import OpenRouter.Request
import OpenRouter.Response
import OpenRouter.SSE
import OpenRouter.Schema
import OpenRouter.Stream
import System

%default total

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

public export
record Client where
  constructor MkClient
  ||| The API key. May be empty for the endpoints that need none, such as
  ||| the model list.
  apiKey         : String
  ||| Where the API lives. Change it to reach a proxy or a test server.
  baseUrl        : String
  ||| Your app's URL, sent as `HTTP-Referer`. With `appTitle`, it is how an
  ||| app is listed on openrouter.ai.
  appUrl         : Maybe String
  ||| Your app's name, sent as `X-Title`.
  appTitle       : Maybe String
  ||| Further headers to send with every request.
  headers        : List (String, String)
  ||| How many times to send a request again after a failure that may pass.
  retries        : Nat
  ||| The pause before the first retry, in milliseconds. It doubles each
  ||| time, up to 30 seconds. A `Retry-After` from the server takes
  ||| precedence, up to 60 seconds.
  backoff        : Nat
  ||| Milliseconds allowed to connect.
  connectTimeout : Nat
  ||| Milliseconds allowed for a whole request that is not streamed.
  requestTimeout : Nat
  ||| A stream is given up on when it is silent for this many milliseconds.
  idleTimeout    : Nat

||| A client with the defaults: two retries starting half a second apart, 10
||| seconds to connect, 10 minutes for a request, and 2 minutes of silence
||| on a stream.
public export
newClient : (apiKey : String) -> Client
newClient key = MkClient
  { apiKey         = key
  , baseUrl        = "https://openrouter.ai/api/v1"
  , appUrl         = Nothing
  , appTitle       = Nothing
  , headers        = []
  , retries        = 2
  , backoff        = 500
  , connectTimeout = 10000
  , requestTimeout = 600000
  , idleTimeout    = 120000
  }

||| A client for the key in the environment variable `OPENROUTER_API_KEY`, or
||| `Nothing` when it is unset or empty. `OPENROUTER_BASE_URL`, when set,
||| replaces the base URL.
export
fromEnv : HasIO io => io (Maybe Client)
fromEnv = do
  Just key <- getEnv "OPENROUTER_API_KEY"
    | Nothing => pure Nothing
  base <- getEnv "OPENROUTER_BASE_URL"
  pure $ if trim key == "" then Nothing
         else Just ({ baseUrl $= \b => fromMaybe b base } (newClient (trim key)))

--------------------------------------------------------------------------------
-- URLs
--------------------------------------------------------------------------------

utf8 : Char -> List Int
utf8 c =
  let n = ord c
   in if n < 0x80 then [n]
      else if n < 0x800 then [0xC0 + n `div` 64, 0x80 + n `mod` 64]
      else if n < 0x10000 then [0xE0 + n `div` 4096, 0x80 + (n `div` 64) `mod` 64, 0x80 + n `mod` 64]
      else [0xF0 + n `div` 262144, 0x80 + (n `div` 4096) `mod` 64, 0x80 + (n `div` 64) `mod` 64, 0x80 + n `mod` 64]

||| Percent-encode a string for use in a query.
export
urlEncode : String -> String
urlEncode s = pack (concatMap enc (unpack s))
  where
    hex : Int -> Char
    hex n = if n < 10 then chr (ord '0' + n) else chr (ord 'A' + n - 10)

    enc : Char -> List Char
    enc c =
      if isAlphaNum c && ord c < 0x80 || c == '-' || c == '_' || c == '.' || c == '~'
         then [c]
         else concatMap (\b => ['%', hex (b `div` 16), hex (b `mod` 16)]) (utf8 c)

queryString : List (String, String) -> String
queryString [] = ""
queryString qs = "?" ++ joinBy "&" (map (\(k, v) => urlEncode k ++ "=" ++ urlEncode v) qs)

--------------------------------------------------------------------------------
-- One request
--------------------------------------------------------------------------------

httpRequest : Client -> (stream : Bool) -> Method -> (path : String) -> List (String, String)
           -> Maybe JSON -> HTTP.Request
httpRequest c stream method path query body = MkRequest
  { method   = method
  , url      = c.baseUrl ++ path ++ queryString query
  , headers  = (if c.apiKey == "" then [] else [("Authorization", "Bearer " ++ c.apiKey)])
            ++ (if isJust body then [("Content-Type", "application/json")] else [])
            ++ [("Accept", if stream then "text/event-stream" else "application/json")]
            ++ [("User-Agent", "idris2-openrouter/0.3.0")]
            ++ maybe [] (\u => [("HTTP-Referer", u)]) c.appUrl
            ++ maybe [] (\t => [("X-Title", t)]) c.appTitle
            ++ c.headers
  , body     = render <$> body
  , timeouts = if stream then MkTimeouts c.connectTimeout 0 c.idleTimeout
                         else MkTimeouts c.connectTimeout c.requestTimeout 0
  }

retryAfter : HasIO io => HTTP.Response -> io (Maybe Nat)
retryAfter r = do
  Just v <- header r "Retry-After"
    | Nothing => pure Nothing
  pure (parsePositive (trim v))

sleepMs : HasIO io => Nat -> io ()
sleepMs ms =
  let us = the Int (cast (ms * 1000))
   in case choose (us >= 0) of
        Left _  => usleep us
        Right _ => pure ()

-- Run an action, and run it again while it fails in a way that may pass.
retrying : HasIO io => (left : Nat) -> (pause : Nat) -> io (Either Error a) -> io (Either Error a)
retrying Z     _     act = act
retrying (S k) pause act = do
  Left e <- act
    | Right x => pure (Right x)
  if retryable e
     then do sleepMs (wait e)
             retrying k (min 30000 (pause * 2)) act
     else pure (Left e)
  where
    wait : Error -> Nat
    wait (Api e) = maybe pause (\s => min 60000 (s * 1000)) e.retryAfter
    wait _       = pause

covering
once : HasIO io => HTTP.Request -> io (Either Error JSON)
once req = do
  Right r <- send req
    | Left f => pure (Left (Transport f))
  after <- retryAfter r
  body  <- rest r
  close r
  pure $ case body of
    Left f  => Left (Transport f)
    Right b => interpret (status r) after b

||| Call any endpoint: a method, a path under the base URL such as
||| `"/models"`, query parameters, and a JSON body. The answer is the
||| response's JSON, or the error it carried. For endpoints this module has
||| no function for.
export covering
call : HasIO io => Client -> Method -> (path : String) -> (query : List (String, String))
    -> (body : Maybe JSON) -> io (Either Error JSON)
call c method path query body =
  retrying c.retries c.backoff (once (httpRequest c False method path query body))

covering
getData : HasIO io => Client -> (path : String) -> List (String, String) -> (JSON -> a)
       -> io (Either Error a)
getData c path query f = map (f . get "data") <$> call c GET path query Nothing

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

||| Send a chat request and wait for the whole reply.
export covering
chat : HasIO io => Client -> ChatRequest -> io (Either Error ChatResponse)
chat c r = map chatResponseFromJSON <$> call c POST "/chat/completions" [] (Just (chatBody False r))

||| Ask one question and get the text of the answer.
export covering
ask : HasIO io => Client -> (model : String) -> (prompt : String) -> io (Either Error String)
ask c model prompt = map text <$> chat c (chatRequest model [user prompt] [])

-- Models sometimes wrap JSON in a Markdown code fence despite being told not to.
unfence : String -> String
unfence s =
  let t = trim s
   in if isPrefixOf "```" t && isSuffixOf "```" t && length t >= 6
         then let inner = substr 3 (length t `minus` 6) t
               in trim (if isPrefixOf "json" inner then substr 4 (length inner) inner else inner)
         else t

||| Send a chat request whose reply must fit a schema, and get the reply as a
||| value of the schema's type. The schema is sent as a strict `json_schema`
||| response format under the given name; use a model that supports
||| structured outputs.
export covering
chatAs : HasIO io => Client -> (name : String) -> Schema a -> ChatRequest
      -> io (Either Error (a, ChatResponse))
chatAs c name schema r = do
  Right resp <- chat c (withOptions [ResponseFormat (schemaFormat name schema)] r)
    | Left e => pure (Left e)
  pure $ case decodeText schema (unfence (text resp)) of
    Left m  => Left (Mismatched m (text resp))
    Right x => Right (x, resp)

--------------------------------------------------------------------------------
-- Streams
--------------------------------------------------------------------------------

||| A chat reply that is still arriving. Close it when done with it.
export
record ChatStream where
  constructor MkChatStream
  http    : HTTP.Response
  decoder : IORef Decoder
  ||| Events decoded but not yet handed out.
  queue   : IORef (List Event)
  acc     : IORef Accumulator
  ||| The body is over (or failed); only the queue is left.
  ended   : IORef Bool
  closed  : IORef Bool

covering
openStream : HasIO io => Client -> (path : String) -> JSON -> io (Either Error ChatStream)
openStream c path body = retrying c.retries c.backoff $ do
  Right r <- send (httpRequest c True POST path [] (Just body))
    | Left f => pure (Left (Transport f))
  kind <- header r "Content-Type"
  if status r >= 200 && status r < 300 && maybe False (isInfixOf "text/event-stream" . toLower) kind
     then do
       s <- [| MkChatStream (pure r) (newIORef start) (newIORef []) (newIORef emptyAccumulator)
                            (newIORef False) (newIORef False) |]
       pure (Right s)
     else do
       -- not a stream: an error, sent as an ordinary response
       after <- retryAfter r
       b     <- rest r
       close r
       pure $ case b of
         Left f     => Left (Transport f)
         Right text => case interpret (status r) after text of
           Left e  => Left e
           Right _ => Left (Malformed "expected an event stream" text)

||| Begin a streamed chat request. The request is retried, like any other,
||| until the stream opens; once it has, a failure is returned as it is.
export covering
openChatStream : HasIO io => Client -> ChatRequest -> io (Either Error ChatStream)
openChatStream c r = openStream c "/chat/completions" (chatBody True r)

||| Close a stream. Closing one that has not ended cancels the request;
||| whether the provider then stops generating (and billing) is up to the
||| provider. Closing twice is harmless.
export
closeStream : HasIO io => ChatStream -> io ()
closeStream s = do
  False <- readIORef s.closed
    | True => pure ()
  writeIORef s.closed True
  writeIORef s.ended True
  writeIORef s.queue []
  close s.http

||| The next chunk of a stream: `Right Nothing` once it is over. Keep-alive
||| comments are skipped. An error in the middle of a stream is returned as
||| `Left`, and ends it.
export covering
nextChunk : HasIO io => ChatStream -> io (Either Error (Maybe Chunk))
nextChunk s = do
  ev :: evs <- readIORef s.queue
    | [] => do
        False <- readIORef s.ended
          | True => pure (Right Nothing)
        Right piece <- next s.http
          | Left f => do writeIORef s.ended True
                         pure (Left (Transport f))
        d <- readIORef s.decoder
        case piece of
          Just text => do let (d', evs) = feed text d
                          writeIORef s.decoder d'
                          writeIORef s.queue evs
          Nothing   => do writeIORef s.queue (finish d)
                          writeIORef s.ended True
        nextChunk s
  writeIORef s.queue evs
  if trim ev.payload == "[DONE]" then nextChunk s else
    case parse ev.payload of
      Left e  => do writeIORef s.ended True
                    writeIORef s.queue []
                    pure (Left (Malformed (show e) ev.payload))
      Right j =>
        let chunk = chunkFromJSON j
         in case chunk.error of
              Just e  => do writeIORef s.ended True
                            writeIORef s.queue []
                            pure (Left (Api e))
              Nothing => do modifyIORef s.acc (`accumulate` chunk)
                            pure (Right (Just chunk))

||| The response that the chunks read so far add up to.
export
streamed : HasIO io => ChatStream -> io ChatResponse
streamed s = accumulated <$> readIORef s.acc

covering
drain : HasIO io => ChatStream -> (Chunk -> io ()) -> io (Either Error ChatResponse)
drain s onChunk = do
  Right (Just chunk) <- nextChunk s
    | Right Nothing => do r <- streamed s
                          closeStream s
                          pure (Right r)
    | Left e        => do closeStream s
                          pure (Left e)
  onChunk chunk
  drain s onChunk

||| Send a chat request, hand each chunk to `onChunk` as it arrives, and
||| return the whole reply at the end: the same value `chat` would have
||| returned, tool calls included.
export covering
chatStream : HasIO io => Client -> ChatRequest -> (onChunk : Chunk -> io ())
          -> io (Either Error ChatResponse)
chatStream c r onChunk = do
  Right s <- openChatStream c r
    | Left e => pure (Left e)
  drain s onChunk

||| `chatStream` for the common case: `onText` gets each piece of the
||| reply's text.
export covering
chatStreamText : HasIO io => Client -> ChatRequest -> (onText : String -> io ())
              -> io (Either Error ChatResponse)
chatStreamText c r onText =
  chatStream c r $ \chunk => let t = chunkText chunk in when (t /= "") (onText t)

--------------------------------------------------------------------------------
-- Text completions
--------------------------------------------------------------------------------

||| Continue a prompt, with no chat template applied.
export covering
complete : HasIO io => Client -> CompletionRequest -> io (Either Error CompletionResponse)
complete c r = map completionResponseFromJSON <$> call c POST "/completions" [] (Just (completionBody False r))

||| Continue a prompt, handing each piece of text to `onText` as it arrives,
||| and return the whole text at the end.
export covering
completeStream : HasIO io => Client -> CompletionRequest -> (onText : String -> io ())
              -> io (Either Error String)
completeStream c r onText = do
  Right s <- openStream c "/completions" (completionBody True r)
    | Left e => pure (Left e)
  map text <$> drain s (\chunk => let t = chunkText chunk in when (t /= "") (onText t))

--------------------------------------------------------------------------------
-- Embeddings
--------------------------------------------------------------------------------

||| Embed some texts: one vector per input, in order.
export covering
embed : HasIO io => Client -> EmbeddingRequest -> io (Either Error EmbeddingResponse)
embed c r = map embeddingResponseFromJSON <$> call c POST "/embeddings" [] (Just (toJSON r))

--------------------------------------------------------------------------------
-- Images
--------------------------------------------------------------------------------

||| Make images from a prompt, with a model built for it (the catalog lists
||| them under `[("output_modalities", "image")]`). Chat models that draw
||| return their pictures in the reply instead: see `replyImages`.
export covering
generateImage : HasIO io => Client -> ImageRequest -> io (Either Error ImageResponse)
generateImage c r = map imageResponseFromJSON <$> call c POST "/images" [] (Just (toJSON r))

||| Decode base64 data, such as a `GeneratedImage` or `SpokenAudio` holds,
||| into a file. The result is the number of bytes written, or `Nothing`
||| when the data is not base64 or the file cannot be written.
export
saveBase64 : HasIO io => (path : String) -> (base64 : String) -> io (Maybe Nat)
saveBase64 = writeBase64

||| Save a `data:...;base64,...` URI, such as `replyImages` returns, to a file.
export
saveDataURI : HasIO io => (path : String) -> (uri : String) -> io (Maybe Nat)
saveDataURI path uri = case fromDataURI uri of
  Just (_, payload) => writeBase64 path payload
  Nothing           => pure Nothing

||| A file as a data URI of the given media type, to send as an `Image`, a
||| `File` or one of the `References`. `Nothing` when the file cannot be read.
export
fileDataURI : HasIO io => (mediaType : String) -> (path : String) -> io (Maybe String)
fileDataURI mediaType path = map (dataURI mediaType) <$> readBase64 path

--------------------------------------------------------------------------------
-- Speech
--------------------------------------------------------------------------------

||| Read a text aloud into a file: mp3 with `SpeechFormat "mp3"`, otherwise
||| headerless 16-bit PCM. The result is the number of bytes written.
export covering
speech : HasIO io => Client -> SpeechRequest -> (path : String) -> io (Either Error Nat)
speech c r path = retrying c.retries c.backoff $ do
  Right resp <- send (httpRequest c False POST "/audio/speech" [] (Just (toJSON r)))
    | Left f => pure (Left (Transport f))
  kind <- header resp "Content-Type"
  if status resp >= 200 && status resp < 300 && maybe True (not . isInfixOf "json" . toLower) kind
     then do
       n <- save resp path
       close resp
       pure (mapFst Transport n)
     else do
       -- not audio: an error, as JSON
       after <- retryAfter resp
       b     <- rest resp
       close resp
       pure $ case b of
         Left f     => Left (Transport f)
         Right text => case interpret (status resp) after text of
           Left e  => Left e
           Right _ => Left (Malformed "expected audio" text)

||| Wrap headerless 16-bit PCM in a WAV file, which players and
||| transcription models accept. `speech` without `SpeechFormat "mp3"`, and a
||| spoken chat reply in `"pcm16"`, are headerless PCM: mono, and 24000
||| samples a second from most providers. The result is the WAV file's size,
||| or `Nothing` on failure.
export
saveWav : HasIO io => (pcmPath : String) -> (wavPath : String) -> (sampleRate : Nat) -> io (Maybe Nat)
saveWav pcm wav rate = pcmToWav pcm wav rate 1

||| A file as audio to transcribe or to send in a chat message. The format
||| is the file's extension. `Nothing` when the file cannot be read.
export
audioFile : HasIO io => (path : String) -> io (Maybe AudioSource)
audioFile path = map (\b => AudioData b extension) <$> readBase64 path
  where
    extension : String
    extension = case split (== '.') path of
      (_ ::: [])   => "wav"
      (_ ::: rest) => toLower (last ("wav" :: rest))

||| Turn speech into text.
export covering
transcribe : HasIO io => Client -> TranscriptionRequest -> io (Either Error Transcription)
transcribe c r = map transcriptionFromJSON <$> call c POST "/audio/transcriptions" [] (Just (toJSON r))

--------------------------------------------------------------------------------
-- The catalog
--------------------------------------------------------------------------------

||| The models on offer. The query narrows the list, as OpenRouter documents:
||| `[("category", "programming")]`, `[("supported_parameters", "tools")]`.
||| With no query the list is long (several hundred models). Needs no key.
export covering
models : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List Model))
models c query = getData c "/models" query (map modelFromJSON . asList)

||| How many models there are. Needs no key.
export covering
modelCount : HasIO io => Client -> io (Either Error Nat)
modelCount c = getData c "/models/count" [] (fromMaybe 0 . asNat . get "count")

||| The models that make embeddings. Needs no key.
export covering
embeddingModels : HasIO io => Client -> io (Either Error (List Model))
embeddingModels c = getData c "/embeddings/models" [] (map modelFromJSON . asList)

||| The providers that serve a model, with each one's price, limits and
||| uptime. Needs no key.
export covering
modelEndpoints : HasIO io => Client -> (model : String) -> io (Either Error (List Endpoint))
modelEndpoints c model =
  getData c ("/models/" ++ model ++ "/endpoints") [] (map endpointFromJSON . asList . get "endpoints")

||| Every provider on OpenRouter. Needs no key.
export covering
providers : HasIO io => Client -> io (Either Error (List ProviderInfo))
providers c = getData c "/providers" [] (map providerInfoFromJSON . asList)

--------------------------------------------------------------------------------
-- The account
--------------------------------------------------------------------------------

||| The key in use: its label, its limit, and what it has spent.
export covering
keyInfo : HasIO io => Client -> io (Either Error KeyInfo)
keyInfo c = getData c "/key" [] keyInfoFromJSON

||| Credits bought and spent.
export covering
credits : HasIO io => Client -> io (Either Error Credits)
credits c = getData c "/credits" [] creditsFromJSON

||| The record of a past request, by the `id` of its response: what it cost
||| and how long it took. The record can take a moment to appear after the
||| request ends.
export covering
generation : HasIO io => Client -> (id : String) -> io (Either Error Generation)
generation c i = getData c "/generation" [("id", i)] generationFromJSON
