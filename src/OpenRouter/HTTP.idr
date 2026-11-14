||| HTTP over libcurl: the only module that touches the network.
|||
||| A response body is pulled piece by piece, so a server-sent event stream can
||| be read as it arrives. Everything above this module is pure.
module OpenRouter.HTTP

import Data.String
import public OpenRouter.Wire

%default total

--------------------------------------------------------------------------------
-- FFI
--------------------------------------------------------------------------------

lib : String -> String
lib f = "C:" ++ f ++ ",libidris2_openrouter"

-- For the calls that wait on the network. A thread inside one is set aside
-- from garbage collection, so the program's other threads keep running
-- while it waits. Chez allows no strings across such a call, which is why
-- waiting for a piece and fetching it are two calls.
waiting : String -> String
waiting f = "C__collect_safe:" ++ f ++ ",libidris2_openrouter"

%foreign lib "or_new"
prim__new : String -> String -> PrimIO AnyPtr

%foreign lib "or_header"
prim__header : AnyPtr -> String -> PrimIO ()

%foreign lib "or_body"
prim__body : AnyPtr -> String -> PrimIO ()

%foreign lib "or_form_field"
prim__formField : AnyPtr -> String -> String -> PrimIO ()

%foreign lib "or_form_file"
prim__formFile : AnyPtr -> String -> String -> String -> String -> PrimIO ()

%foreign lib "or_timeouts"
prim__timeouts : AnyPtr -> Int -> Int -> Int -> PrimIO ()

%foreign waiting "or_start"
prim__start : AnyPtr -> PrimIO Int

%foreign lib "or_status"
prim__status : AnyPtr -> PrimIO Int

%foreign waiting "or_wait"
prim__wait : AnyPtr -> PrimIO ()

%foreign lib "or_next"
prim__next : AnyPtr -> PrimIO String

%foreign lib "or_done"
prim__done : AnyPtr -> PrimIO Int

%foreign lib "or_error"
prim__error : AnyPtr -> PrimIO String

%foreign lib "or_timed_out"
prim__timedOut : AnyPtr -> PrimIO Int

%foreign lib "or_response_header"
prim__responseHeader : AnyPtr -> String -> PrimIO String

%foreign lib "or_save_to"
prim__saveTo : AnyPtr -> String -> PrimIO Int

%foreign waiting "or_save_run"
prim__saveRun : AnyPtr -> PrimIO Int

%foreign lib "or_file_base64"
prim__fileBase64 : String -> PrimIO String

%foreign lib "or_file_ok"
prim__fileOk : String -> PrimIO Int

%foreign lib "or_base64_file"
prim__base64File : String -> String -> PrimIO Int

%foreign lib "or_pcm_to_wav"
prim__pcmToWav : String -> String -> Int -> Int -> PrimIO Int

%foreign lib "or_free"
prim__free : AnyPtr -> PrimIO ()

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

||| Time limits, in milliseconds. `0` turns a limit off.
public export
record Timeouts where
  constructor MkTimeouts
  ||| Time allowed to connect.
  connect : Nat
  ||| Time allowed for the whole request, body included.
  overall : Nat
  ||| Give up when nothing arrives for this long.
  idle    : Nat

public export
record Request where
  constructor MkRequest
  method   : Method
  url      : String
  headers  : List (String, String)
  body     : Maybe String
  ||| When not empty, the body is these parts as `multipart/form-data`, and
  ||| `body` is ignored.
  form     : List FormPart
  timeouts : Timeouts

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

||| A response whose body is still arriving. It must be closed.
export
record Response where
  constructor MkResponse
  ptr     : AnyPtr
  ||| The HTTP status code.
  status' : Int

export
status : Response -> Int
status = status'

failure : HasIO io => AnyPtr -> io Failure
failure p = do
  why <- primIO (prim__error p)
  t   <- primIO (prim__timedOut p)
  pure (if t /= 0 then TimedOut why else Unreachable why)

||| Send a request and wait for the response to begin.
export
send : HasIO io => Request -> io (Either Failure Response)
send r = do
  p <- primIO (prim__new (show r.method) r.url)
  if prim__nullAnyPtr p /= 0 then pure (Left (Unreachable "libcurl could not start a request")) else do
    for_ r.headers $ \(k, v) => primIO (prim__header p (k ++ ": " ++ v))
    case r.form of
      [] => for_ r.body $ \b => primIO (prim__body p b)
      ps => for_ ps $ \part => case part of
        FormField n v        => primIO (prim__formField p n v)
        FormFile n f         => primIO (prim__formFile p n f "" "")
        FormFileAs n f fn ty => primIO (prim__formFile p n f fn ty)
    primIO (prim__timeouts p (cast r.timeouts.connect) (cast r.timeouts.overall) (cast r.timeouts.idle))
    ok <- primIO (prim__start p)
    if ok == 0
       then do e <- failure p
               primIO (prim__free p)
               pure (Left e)
       else do s <- primIO (prim__status p)
               pure (Right (MkResponse p s))

||| The value of a response header, by its case-insensitive name.
export
header : HasIO io => Response -> String -> io (Maybe String)
header r name = do
  v <- primIO (prim__responseHeader r.ptr name)
  pure (if v == "" then Nothing else Just v)

||| The next piece of the body: `Right Nothing` once the body is over. A piece
||| never ends in the middle of a character.
export
next : HasIO io => Response -> io (Either Failure (Maybe String))
next r = do
  primIO (prim__wait r.ptr)
  s <- primIO (prim__next r.ptr)
  if s /= "" then pure (Right (Just s)) else do
    e <- primIO (prim__error r.ptr)
    if e /= "" then Left <$> failure r.ptr else do
      d <- primIO (prim__done r.ptr)
      pure (Right (if d /= 0 then Nothing else Just ""))

||| Free the connection. The response must not be used afterwards. Closing
||| before the body is over cancels the request.
export
close : HasIO io => Response -> io ()
close r = primIO (prim__free r.ptr)

||| Write the rest of the body to a file, byte for byte: for a body that is
||| not text, such as audio. The result is the number of bytes written.
export
save : HasIO io => Response -> (path : String) -> io (Either Failure Nat)
save r path = do
  ok <- primIO (prim__saveTo r.ptr path)
  if ok == 0 then pure (Left (Unreachable ("could not write " ++ path))) else do
    n <- primIO (prim__saveRun r.ptr)
    e <- primIO (prim__error r.ptr)
    if e /= "" then Left <$> failure r.ptr
      else if n < 0 then pure (Left (Unreachable ("could not write " ++ path)))
      else pure (Right (cast n))

||| The rest of the body.
export
covering
rest : HasIO io => Response -> io (Either Failure String)
rest r = go [<]
  where
    go : SnocList String -> io (Either Failure String)
    go acc = do
      Right (Just s) <- next r
        | Right Nothing => pure (Right (concat acc))
        | Left e        => pure (Left e)
      go (acc :< s)

||| Send a request and read the whole response: its status and body.
export
covering
fetch : HasIO io => Request -> io (Either Failure (Int, String))
fetch req = do
  Right r <- send req
    | Left e => pure (Left e)
  b <- rest r
  close r
  pure (map (status r,) b)

--------------------------------------------------------------------------------
-- Binary files
--------------------------------------------------------------------------------

||| The contents of a file as base64, which is how images and audio travel
||| inside JSON. `Nothing` when the file cannot be read.
export
readBase64 : HasIO io => (path : String) -> io (Maybe String)
readBase64 path = do
  ok <- primIO (prim__fileOk path)
  if ok == 0 then pure Nothing else Just <$> primIO (prim__fileBase64 path)

||| Decode base64 text into a file. The result is the number of bytes
||| written, or `Nothing` when the text is not base64 or the file cannot be
||| written. Pieces that were encoded one by one and then joined, as audio
||| arrives from a stream, decode correctly.
export
writeBase64 : HasIO io => (path : String) -> (base64 : String) -> io (Maybe Nat)
writeBase64 path text = do
  n <- primIO (prim__base64File path text)
  pure (if n < 0 then Nothing else Just (cast n))

||| Copy headerless 16-bit PCM, which is what speech models produce by
||| default, into a WAV file that players and transcription models accept.
||| The result is the size of the WAV file, or `Nothing` on failure.
export
pcmToWav : HasIO io => (pcmPath : String) -> (wavPath : String) -> (sampleRate : Nat) -> (channels : Nat)
        -> io (Maybe Nat)
pcmToWav pcm wav rate channels = do
  n <- primIO (prim__pcmToWav pcm wav (cast rate) (cast channels))
  pure (if n < 0 then Nothing else Just (cast n))
