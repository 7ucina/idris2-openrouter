||| HTTP over libcurl: the only module that touches the network.
|||
||| A response body is pulled piece by piece, so a server-sent event stream can
||| be read as it arrives. Everything above this module is pure.
module OpenRouter.HTTP

import Data.String

%default total

--------------------------------------------------------------------------------
-- FFI
--------------------------------------------------------------------------------

lib : String -> String
lib f = "C:" ++ f ++ ",libidris2_openrouter"

%foreign lib "or_new"
prim__new : String -> String -> PrimIO AnyPtr

%foreign lib "or_header"
prim__header : AnyPtr -> String -> PrimIO ()

%foreign lib "or_body"
prim__body : AnyPtr -> String -> PrimIO ()

%foreign lib "or_timeouts"
prim__timeouts : AnyPtr -> Int -> Int -> Int -> PrimIO ()

%foreign lib "or_start"
prim__start : AnyPtr -> PrimIO Int

%foreign lib "or_status"
prim__status : AnyPtr -> PrimIO Int

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

%foreign lib "or_free"
prim__free : AnyPtr -> PrimIO ()

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

public export
data Method = GET | POST | PUT | PATCH | DELETE

export
Show Method where
  show GET    = "GET"
  show POST   = "POST"
  show PUT    = "PUT"
  show PATCH  = "PATCH"
  show DELETE = "DELETE"

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
  timeouts : Timeouts

||| Why no response came back.
public export
data Failure : Type where
  ||| The request ran out of time.
  TimedOut   : (why : String) -> Failure
  ||| Anything else: no route, a refused connection, a TLS failure, a
  ||| connection that dropped.
  Unreachable : (why : String) -> Failure

export
Show Failure where
  show (TimedOut why)    = "timed out: " ++ why
  show (Unreachable why) = why

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
    for_ r.body $ \b => primIO (prim__body p b)
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
