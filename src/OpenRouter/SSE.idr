||| Server-sent events, decoded incrementally.
|||
||| Network reads cut a stream anywhere: in the middle of a line, or between
||| the `\r` and the `\n` of a line ending. The decoder keeps whatever is
||| incomplete and hands back only whole events.
module OpenRouter.SSE

import Data.List
import Data.SnocList
import Data.String

%default total

||| One event: its `event:` name, if it had one, and its `data:` lines joined
||| by newlines.
public export
record Event where
  constructor MkEvent
  name    : Maybe String
  payload : String

export
Eq Event where
  a == b = a.name == b.name && a.payload == b.payload

export
Show Event where
  show e = "MkEvent " ++ show e.name ++ " " ++ show e.payload

||| What has arrived but does not yet make a whole event.
export
record Decoder where
  constructor MkDecoder
  ||| The characters of an unfinished line.
  line  : String
  ||| The `data:` lines of an unfinished event.
  lines : SnocList String
  name  : Maybe String

||| A decoder that has seen nothing.
export
start : Decoder
start = MkDecoder "" [<] Nothing

-- The whole lines in some text, and the unfinished line after them. A lone
-- "\r" at the very end is kept back: the next piece may begin with its "\n".
split : SnocList String -> SnocList Char -> List Char -> (List String, String)
split ls cur []                   = (ls <>> [], pack (cur <>> []))
split ls cur ['\r']               = (ls <>> [], pack (cur <>> ['\r']))
split ls cur ('\r' :: '\n' :: cs) = split (ls :< pack (cur <>> [])) [<] cs
split ls cur ('\r' :: cs)         = split (ls :< pack (cur <>> [])) [<] cs
split ls cur ('\n' :: cs)         = split (ls :< pack (cur <>> [])) [<] cs
split ls cur (c :: cs)            = split ls (cur :< c) cs

-- A field's value, less the one space that may follow the colon.
value : List Char -> String
value (' ' :: cs) = pack cs
value cs          = pack cs

step : (Decoder, SnocList Event) -> String -> (Decoder, SnocList Event)
step (d, out) "" =
  -- a blank line ends the event; one with no data is dropped
  case d.lines of
    [<] => ({ name := Nothing } d, out)
    ls  => ({ lines := [<], name := Nothing } d, out :< MkEvent d.name (joinBy "\n" (ls <>> [])))
step (d, out) l =
  case break (== ':') (unpack l) of
    ([], _)          => (d, out)                                -- a comment
    (f, [])          => field (pack f) ""
    (f, _ :: v)      => field (pack f) (value v)
  where
    field : String -> String -> (Decoder, SnocList Event)
    field "data"  v = ({ lines $= (:< v) } d, out)
    field "event" v = ({ name := Just v } d, out)
    field _       _ = (d, out)                                  -- id, retry, and unknown fields

||| Add a piece of the stream, and get the events it completed.
export
feed : String -> Decoder -> (Decoder, List Event)
feed piece d =
  let (ls, unfinished) = split [<] [<] (unpack (d.line ++ piece))
      (d', out)     = foldl step ({ line := "" } d, [<]) ls
   in ({ line := unfinished } d', out <>> [])

||| The stream is over: get the event it was in the middle of, if it had data.
||| A well-formed stream ends with a blank line and leaves nothing here.
export
finish : Decoder -> List Event
finish d =
  let (ls, last) = split [<] [<] (unpack d.line ++ ['\n'])   -- ends a line that was cut short
      (d', out)  = foldl step ({ line := "" } d, [<]) (ls ++ (if last == "" then [] else [last]))
      (_, out')  = step (d', out) ""
   in out' <>> []
