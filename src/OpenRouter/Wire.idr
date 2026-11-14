||| The few plain types that requests and errors are described with: HTTP
||| methods, the parts of a form, and why a request got no response.
module OpenRouter.Wire

%default total

public export
data Method = GET | POST | PUT | PATCH | DELETE

export
Show Method where
  show GET    = "GET"
  show POST   = "POST"
  show PUT    = "PUT"
  show PATCH  = "PATCH"
  show DELETE = "DELETE"

||| One part of a multipart form.
public export
data FormPart : Type where
  ||| A text field.
  FormField : (name : String) -> (value : String) -> FormPart
  ||| A file, read from disk as the request is sent.
  FormFile  : (name : String) -> (path : String) -> FormPart
  ||| A file, sent under another name and with a stated media type.
  FormFileAs : (name : String) -> (path : String) -> (filename : String) -> (mediaType : String) -> FormPart

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
