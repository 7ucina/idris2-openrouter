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
import Data.SnocList
import Data.So
import Data.String
import OpenRouter.HTTP
import public OpenRouter.Wire
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
  ||| Your app's name, sent as `X-OpenRouter-Title` (and as `X-Title`, its
  ||| older name).
  appTitle       : Maybe String
  ||| Categories your app is listed under, as `["cli-agent"]`, sent as
  ||| `X-OpenRouter-Categories`.
  appCategories  : List String
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
  , appCategories  = []
  , headers        = []
  , retries        = 2
  , backoff        = 500
  , connectTimeout = 10000
  , requestTimeout = 600000
  , idleTimeout    = 120000
  }

||| The client, sending these headers as well with every request. For the
||| few endpoints that take a header of their own, such as `idempotency-key`.
export
withHeaders : List (String, String) -> Client -> Client
withHeaders hs = { headers $= (++ hs) }

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

-- "https://openrouter.ai/api/v1" gives "https://openrouter.ai".
origin : String -> String
origin url = case break (== '/') (unpack (snd (breakOn "://" url))) of
  (_, [])   => url
  (_, _)    => let (scheme, rest) = breakOn "://" url
                   host = pack (takeWhile (/= '/') (unpack (substr 3 (length rest) rest)))
                in scheme ++ "://" ++ host
  where
    breakOn : String -> String -> (String, String)
    breakOn sep str = go [<] (unpack str)
      where
        go : SnocList Char -> List Char -> (String, String)
        go acc []        = (pack (acc <>> []), "")
        go acc (c :: cs) = if isPrefixOf sep (pack (c :: cs)) then (pack (acc <>> []), pack (c :: cs))
                           else go (acc :< c) cs

-- A path under the base URL, except the few that the API serves from the
-- host's root (`/api/alpha/...`).
urlFor : Client -> (path : String) -> List (String, String) -> String
urlFor c path query =
  (if isPrefixOf "/api/" path then origin c.baseUrl else c.baseUrl) ++ path ++ queryString query

data Payload = NoBody | JSONBody JSON | FormBody (List (String, String)) | Multipart (List FormPart)

httpRequest : Client -> (stream : Bool) -> Method -> (path : String) -> List (String, String)
           -> Payload -> HTTP.Request
httpRequest c stream method path query payload = MkRequest
  { method   = method
  , url      = urlFor c path query
  , headers  = (if c.apiKey == "" then [] else [("Authorization", "Bearer " ++ c.apiKey)])
            ++ (case payload of
                  JSONBody _ => [("Content-Type", "application/json")]
                  FormBody _ => [("Content-Type", "application/x-www-form-urlencoded")]
                  _          => [])
            ++ [("Accept", if stream then "text/event-stream" else "application/json")]
            ++ [("User-Agent", "idris2-openrouter/0.4.0")]
            ++ maybe [] (\u => [("HTTP-Referer", u)]) c.appUrl
            ++ maybe [] (\t => [("X-OpenRouter-Title", t), ("X-Title", t)]) c.appTitle
            ++ (if null c.appCategories then [] else [("X-OpenRouter-Categories", joinBy "," c.appCategories)])
            ++ c.headers
  , body     = case payload of
                 JSONBody j  => Just (render j)
                 FormBody fs => Just (joinBy "&" (map (\(k, v) => urlEncode k ++ "=" ++ urlEncode v) fs))
                 _           => Nothing
  , form     = case payload of
                 Multipart ps => ps
                 _            => []
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

-- The whole response as text, with its status.
covering
whole : HasIO io => HTTP.Request -> io (Either Error (Int, Maybe Nat, String))
whole req = do
  Right r <- send req
    | Left f => pure (Left (Transport f))
  after <- retryAfter r
  body  <- rest r
  close r
  pure $ case body of
    Left f  => Left (Transport f)
    Right b => Right (status r, after, b)

covering
once : HasIO io => HTTP.Request -> io (Either Error JSON)
once req = do
  Right (status, after, b) <- whole req
    | Left e => pure (Left e)
  pure (interpret status after b)

||| Call any endpoint: a method, a path under the base URL such as
||| `"/models"`, query parameters, and a JSON body. The answer is the
||| response's JSON (`JNull` when the response is empty), or the error it
||| carried. `OpenRouter.API` has a function made this way for every
||| endpoint.
export covering
call : HasIO io => Client -> Method -> (path : String) -> (query : List (String, String))
    -> (body : Maybe JSON) -> io (Either Error JSON)
call c method path query body =
  retrying c.retries c.backoff (once (httpRequest c False method path query (maybe NoBody JSONBody body)))

||| `call` for an endpoint that answers with text rather than JSON.
export covering
callText : HasIO io => Client -> Method -> (path : String) -> (query : List (String, String))
        -> io (Either Error String)
callText c method path query = retrying c.retries c.backoff $ do
  Right (status, after, b) <- whole (httpRequest c False method path query NoBody)
    | Left e => pure (Left e)
  pure $ if status >= 200 && status < 300 then Right b
         else case interpret status after b of
                Left e  => Left e
                Right _ => Left (Malformed "expected an error" b)

||| `call` with a body of form fields (`application/x-www-form-urlencoded`).
export covering
callForm : HasIO io => Client -> (path : String) -> (fields : List (String, String))
        -> io (Either Error JSON)
callForm c path fields = retrying c.retries c.backoff (once (httpRequest c False POST path [] (FormBody fields)))

||| `call` with a `multipart/form-data` body: how files are uploaded.
export covering
upload : HasIO io => Client -> (path : String) -> (query : List (String, String)) -> List FormPart
      -> io (Either Error JSON)
upload c path query parts = retrying c.retries c.backoff (once (httpRequest c False POST path query (Multipart parts)))

||| `call` for an endpoint that answers with a file's bytes: they are written
||| to `file` untouched, and the result is how many there were. An error
||| arrives as JSON and is returned as usual.
export covering
download : HasIO io => Client -> Method -> (path : String) -> (query : List (String, String))
        -> (body : Maybe JSON) -> (file : String) -> io (Either Error Nat)
download c method path query body file = retrying c.retries c.backoff $ do
  Right resp <- send (httpRequest c False method path query (maybe NoBody JSONBody body))
    | Left f => pure (Left (Transport f))
  kind <- header resp "Content-Type"
  if status resp >= 200 && status resp < 300 && maybe True (not . isInfixOf "json" . toLower) kind
     then do
       n <- save resp file
       close resp
       pure (mapFst Transport n)
     else do
       after <- retryAfter resp
       b     <- rest resp
       close resp
       pure $ case b of
         Left f     => Left (Transport f)
         Right text => case interpret (status resp) after text of
           Left e  => Left e
           Right _ => Left (Malformed "expected a file" text)

covering
getData : HasIO io => Client -> (path : String) -> List (String, String) -> (JSON -> a)
       -> io (Either Error a)
getData c path query f = map (f . get "data") <$> call c GET path query Nothing

--------------------------------------------------------------------------------
-- Event streams
--------------------------------------------------------------------------------

||| A response arriving as server-sent events. Close it when done with it.
export
record EventStream where
  constructor MkEventStream
  http    : HTTP.Response
  decoder : IORef Decoder
  ||| Events decoded but not yet handed out.
  queue   : IORef (List Event)
  ||| The body is over (or failed); only the queue is left.
  ended   : IORef Bool
  closed  : IORef Bool

||| Begin a streamed request to any endpoint that answers with server-sent
||| events. The request is retried, like any other, until the stream opens;
||| once it has, a failure is returned as it is.
export covering
openEventStream : HasIO io => Client -> (path : String) -> (body : JSON) -> io (Either Error EventStream)
openEventStream c path body = retrying c.retries c.backoff $ do
  Right r <- send (httpRequest c True POST path [] (JSONBody body))
    | Left f => pure (Left (Transport f))
  kind <- header r "Content-Type"
  if status r >= 200 && status r < 300 && maybe False (isInfixOf "text/event-stream" . toLower) kind
     then do
       s <- [| MkEventStream (pure r) (newIORef start) (newIORef []) (newIORef False) (newIORef False) |]
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

||| Close a stream. Closing one that has not ended cancels the request;
||| whether the provider then stops generating (and billing) is up to the
||| provider. Closing twice is harmless.
export
closeEventStream : HasIO io => EventStream -> io ()
closeEventStream s = do
  False <- readIORef s.closed
    | True => pure ()
  writeIORef s.closed True
  writeIORef s.ended True
  writeIORef s.queue []
  close s.http

-- Stop handing out events: after an error, nothing more is wanted.
abandon : HasIO io => EventStream -> io ()
abandon s = do
  writeIORef s.ended True
  writeIORef s.queue []

||| The next event of a stream: `Right Nothing` once it is over. Keep-alive
||| comments are skipped, and so is the `[DONE]` marker.
export covering
nextEvent : HasIO io => EventStream -> io (Either Error (Maybe Event))
nextEvent s = do
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
        nextEvent s
  writeIORef s.queue evs
  if trim ev.payload == "[DONE]" then nextEvent s else pure (Right (Just ev))

||| The next event of a stream, with its data read as JSON. An event that
||| carries an `error` is returned as `Left`, and ends the stream.
export covering
nextJSON : HasIO io => EventStream -> io (Either Error (Maybe (Maybe String, JSON)))
nextJSON s = do
  Right (Just ev) <- nextEvent s
    | Right Nothing => pure (Right Nothing)
    | Left e        => pure (Left e)
  case parse ev.payload of
    Left e  => do abandon s
                  pure (Left (Malformed (show e) ev.payload))
    Right j => case embeddedError j of
      Just e  => do abandon s
                    pure (Left (Api e))
      Nothing => pure (Right (Just (ev.name, j)))

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
-- Chat streams
--------------------------------------------------------------------------------

||| A chat reply that is still arriving. Close it when done with it.
export
record ChatStream where
  constructor MkChatStream
  events : EventStream
  acc    : IORef Accumulator

covering
openStream : HasIO io => Client -> (path : String) -> JSON -> io (Either Error ChatStream)
openStream c path body = do
  Right events <- openEventStream c path body
    | Left e => pure (Left e)
  acc <- newIORef emptyAccumulator
  pure (Right (MkChatStream events acc))

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
closeStream s = closeEventStream s.events

||| The next chunk of a stream: `Right Nothing` once it is over. Keep-alive
||| comments are skipped. An error in the middle of a stream is returned as
||| `Left`, and ends it.
export covering
nextChunk : HasIO io => ChatStream -> io (Either Error (Maybe Chunk))
nextChunk s = do
  Right (Just (_, j)) <- nextJSON s.events
    | Right Nothing => pure (Right Nothing)
    | Left e        => pure (Left e)
  let chunk = chunkFromJSON j
  modifyIORef s.acc (`accumulate` chunk)
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
speech c r path = download c POST "/audio/speech" [] (Just (toJSON r)) path

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
-- Reranking
--------------------------------------------------------------------------------

||| Order documents by how well they answer a query, best first.
export covering
rerank : HasIO io => Client -> RerankRequest -> io (Either Error RerankResponse)
rerank c r = map rerankResponseFromJSON <$> call c POST "/rerank" [] (Just (toJSON r))

--------------------------------------------------------------------------------
-- Video
--------------------------------------------------------------------------------

||| Start making a video. This returns at once with a job; the video takes
||| minutes. Follow the job with `videoJob` or `awaitVideo`.
export covering
submitVideo : HasIO io => Client -> VideoRequest -> io (Either Error VideoJob)
submitVideo c r = map videoJobFromJSON <$> call c POST "/videos" [] (Just (toJSON r))

||| How a video job is getting on.
export covering
videoJob : HasIO io => Client -> (id : String) -> io (Either Error VideoJob)
videoJob c i = map videoJobFromJSON <$> call c GET ("/videos/" ++ urlEncode i) [] Nothing

||| Look at a video job every `every` seconds until it has finished, or
||| until it has been looked at `tries` times. The result is the job as last
||| seen: check its `status`.
export covering
awaitVideo : HasIO io => Client -> (id : String) -> (every : Nat) -> (tries : Nat)
          -> io (Either Error VideoJob)
awaitVideo c i every Z     = videoJob c i
awaitVideo c i every (S k) = do
  Right job <- videoJob c i
    | Left e => pure (Left e)
  if finished job.status || k == 0 then pure (Right job) else do
    sleepMs (every * 1000)
    awaitVideo c i every k

||| Download one of a finished job's videos (the first is 0) into a file.
||| The result is the number of bytes written.
export covering
downloadVideo : HasIO io => Client -> (id : String) -> (index : Nat) -> (file : String)
             -> io (Either Error Nat)
downloadVideo c i index file =
  download c GET ("/videos/" ++ urlEncode i ++ "/content") [("index", show index)] Nothing file

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

||| Upload a file to OpenRouter, to refer to by its id in later requests. Its type is
||| worked out from its contents.
export covering
storeFile : HasIO io => Client -> (path : String) -> io (Either Error FileInfo)
storeFile c path = map fileInfoFromJSON <$> upload c "/files" [] [FormFile "file" path]

||| The files you have stored. The query pages through them: `limit`, `after`.
export covering
storedFiles : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List FileInfo))
storedFiles c query = getData c "/files" query (map fileInfoFromJSON . asList)

||| What is known about a stored file.
export covering
fileInfo : HasIO io => Client -> (id : String) -> io (Either Error FileInfo)
fileInfo c i = map fileInfoFromJSON <$> call c GET ("/files/" ++ urlEncode i) [] Nothing

||| Delete a stored file. This cannot be undone.
export covering
removeFile : HasIO io => Client -> (id : String) -> io (Either Error ())
removeFile c i = map (const ()) <$> call c DELETE ("/files/" ++ urlEncode i) [] Nothing

||| Download a stored file's content into a local file. Only files made on
||| the server can be downloaded; ones you uploaded cannot.
export covering
downloadFile : HasIO io => Client -> (id : String) -> (file : String) -> io (Either Error Nat)
downloadFile c i file = download c GET ("/files/" ++ urlEncode i ++ "/content") [] Nothing file

--------------------------------------------------------------------------------
-- Batches
--------------------------------------------------------------------------------

||| Submit requests to run in the background, at a discount, within a day.
||| `endpoint` says what kind they are: `"/v1/chat/completions"`,
||| `"/v1/responses"`, `"/v1/messages"`, `"/v1/embeddings"` or
||| `"/v1/audio/speech"`. All of them go to the one model. Follow the batch
||| with `batchStatus` or `awaitBatch`.
export covering
createBatch : HasIO io => Client -> (endpoint : String) -> (model : String) -> List BatchItem
           -> io (Either Error Batch)
createBatch c endpoint model items = map batchFromJSON <$> call c POST "/batches" [] (Just body)
  where
    -- the API wants `requests` to be the last field
    body : JSON
    body = JObject
      [ ("endpoint", JString endpoint)
      , ("model", JString model)
      , ("completion_window", JString "24h")
      , ("requests", JArray (map (\i => JObject [("custom_id", JString i.customId), ("body", i.body)]) items)) ]

||| How a batch is getting on, with its results once it has completed.
export covering
batchStatus : HasIO io => Client -> (id : String) -> io (Either Error Batch)
batchStatus c i = map batchFromJSON <$> call c GET ("/batches/" ++ urlEncode i) [] Nothing

||| Your batches. The query narrows and pages through them: `status`,
||| `limit`, `after`.
export covering
batches : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List Batch))
batches c query = getData c "/batches" query (map batchFromJSON . asList)

||| Cancel a batch that is still running, or delete one that has finished.
export covering
cancelBatch : HasIO io => Client -> (id : String) -> io (Either Error ())
cancelBatch c i = map (const ()) <$> call c DELETE ("/batches/" ++ urlEncode i) [] Nothing

||| Look at a batch every `every` seconds until it has finished, or until it
||| has been looked at `tries` times. The result is the batch as last seen.
export covering
awaitBatch : HasIO io => Client -> (id : String) -> (every : Nat) -> (tries : Nat)
          -> io (Either Error Batch)
awaitBatch c i every Z     = batchStatus c i
awaitBatch c i every (S k) = do
  Right b <- batchStatus c i
    | Left e => pure (Left e)
  if batchFinished b || k == 0 then pure (Right b) else do
    sleepMs (every * 1000)
    awaitBatch c i every k

--------------------------------------------------------------------------------
-- The catalog
--------------------------------------------------------------------------------

||| The models on offer. The query narrows the list, as OpenRouter documents:
||| `[("category", "programming")]`, `[("supported_parameters", "tools")]`.
||| With no query the list is long (several hundred models). Needs no key.
export covering
models : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List Model))
models c query = getData c "/models" query (map modelFromJSON . asList)

||| One model, by its id. Needs no key.
export covering
modelInfo : HasIO io => Client -> (id : String) -> io (Either Error Model)
modelInfo c i = getData c ("/model/" ++ i) [] modelFromJSON

||| The models your account can use: the catalog, less whatever your
||| provider preferences, privacy settings and guardrails rule out.
export covering
availableModels : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List Model))
availableModels c query = getData c "/models/user" query (map modelFromJSON . asList)

||| The endpoints that keep no data (zero data retention). Needs no key.
export covering
zdrEndpoints : HasIO io => Client -> io (Either Error (List Endpoint))
zdrEndpoints c = getData c "/endpoints/zdr" [] (map endpointFromJSON . asList)

||| The tools OpenRouter can run on a model's behalf (web search and the
||| like), each as its JSON description. Pass one to a request with
||| `ServerTools [serverTool id []]`, where `id` is its `"id"` here.
export covering
serverTools : HasIO io => Client -> io (Either Error (List JSON))
serverTools c = getData c "/tools" [] asList

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

||| The prompt and the completion of a past request, as OpenRouter stored
||| them. Only for accounts that have turned on storing them.
export covering
generationContent : HasIO io => Client -> (id : String) -> io (Either Error JSON)
generationContent c i = getData c "/generation/content" [("id", i)] id

||| Tell OpenRouter that a generation went wrong. The category is one of
||| `"latency"`, `"incoherence"`, `"incorrect_response"`, `"formatting"`,
||| `"billing"`, `"api_error"` and `"other"`.
export covering
reportGeneration : HasIO io => Client -> (id : String) -> (category : String) -> (comment : String)
                -> io (Either Error ())
reportGeneration c i category comment = map (const ()) <$> call c POST "/generation/feedback" [] (Just body)
  where
    body : JSON
    body = objectOf [ field "generation_id" i, field "category" category
                    , if comment == "" then [] else field "comment" comment ]

||| What the account has spent, grouped by day and model, as JSON rows. The
||| query narrows it: `date` (as `2026-01-31`), `api_key_hash`, `user_id`.
||| Needs a management key.
export covering
activity : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List JSON))
activity c query = getData c "/activity" query asList

--------------------------------------------------------------------------------
-- Managing keys
--------------------------------------------------------------------------------

||| The account's API keys. Needs a management key, like the rest of this
||| section.
export covering
apiKeys : HasIO io => Client -> (query : List (String, String)) -> io (Either Error (List KeyInfo))
apiKeys c query = getData c "/keys" query (map keyInfoFromJSON . asList)

||| Make a new API key, with an optional spending limit in dollars. The
||| result is the key's record and the key itself, which is shown only this
||| once.
export covering
createKey : HasIO io => Client -> (name : String) -> (limit : Maybe Double) -> io (Either Error (KeyInfo, String))
createKey c name limit = do
  Right j <- call c POST "/keys" [] (Just (objectOf [field "name" name, optional "limit" limit]))
    | Left e => pure (Left e)
  pure (Right (keyInfoFromJSON (get "data" j), fromMaybe "" (asString (get "key" j))))

||| One API key, by its hash.
export covering
apiKeyInfo : HasIO io => Client -> (hash : String) -> io (Either Error KeyInfo)
apiKeyInfo c h = getData c ("/keys/" ++ urlEncode h) [] keyInfoFromJSON

||| Change an API key: its `name`, `limit`, `disabled`, and so on, as JSON
||| fields.
export covering
updateKey : HasIO io => Client -> (hash : String) -> (changes : List (String, JSON)) -> io (Either Error KeyInfo)
updateKey c h changes =
  map (keyInfoFromJSON . get "data") <$> call c PATCH ("/keys/" ++ urlEncode h) [] (Just (JObject changes))

||| Delete an API key. This cannot be undone.
export covering
deleteKey : HasIO io => Client -> (hash : String) -> io (Either Error ())
deleteKey c h = map (const ()) <$> call c DELETE ("/keys/" ++ urlEncode h) [] Nothing

--------------------------------------------------------------------------------
-- Signing users in
--------------------------------------------------------------------------------

||| Where to send a user so that they can give your app a key of their own
||| (OAuth with PKCE). `callback` is the URL OpenRouter sends them back to,
||| with a `code` in its query; `challenge`, when given, is the code
||| challenge and its method (`"S256"` or `"plain"`).
export
authorizationURL : (callback : String) -> (challenge : Maybe (String, String)) -> String
authorizationURL callback challenge =
  "https://openrouter.ai/auth?callback_url=" ++ urlEncode callback
    ++ (case challenge of
          Just (ch, how) => "&code_challenge=" ++ urlEncode ch ++ "&code_challenge_method=" ++ urlEncode how
          Nothing        => "")

||| Exchange the `code` a user came back with for their API key. `verifier`
||| is the code verifier and the method the challenge was made with, when a
||| challenge was sent. Needs no key of your own.
export covering
exchangeAuthCode : HasIO io => Client -> (code : String) -> (verifier : Maybe (String, String))
                -> io (Either Error String)
exchangeAuthCode c code verifier = do
  Right j <- call c POST "/auth/keys" [] (Just body)
    | Left e => pure (Left e)
  pure (maybe (Left (Malformed "the response has no key" (render j))) Right (asString (get "key" j)))
  where
    body : JSON
    body = objectOf
      [ field "code" code
      , case verifier of
          Just (v, how) => field "code_verifier" v ++ field "code_challenge_method" how
          Nothing       => [] ]
