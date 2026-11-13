||| Chat messages: what is sent to a model and what comes back.
module OpenRouter.Message

import Data.List
import Data.Maybe
import Data.String
import OpenRouter.JSON

%default total

--------------------------------------------------------------------------------
-- Roles
--------------------------------------------------------------------------------

public export
data Role : Type where
  System     : Role
  ||| The system role under its newer name, which some models expect.
  Developer  : Role
  User       : Role
  Assistant  : Role
  ||| The result of a tool call.
  ToolResult : Role
  OtherRole  : String -> Role

export
Show Role where
  show System        = "system"
  show Developer     = "developer"
  show User          = "user"
  show Assistant     = "assistant"
  show ToolResult    = "tool"
  show (OtherRole r) = r

export
Eq Role where
  a == b = show a == show b

export
parseRole : String -> Role
parseRole "system"    = System
parseRole "developer" = Developer
parseRole "user"      = User
parseRole "assistant" = Assistant
parseRole "tool"      = ToolResult
parseRole r           = OtherRole r

--------------------------------------------------------------------------------
-- Content
--------------------------------------------------------------------------------

||| How closely a model should look at an image.
public export
data Detail = LowDetail | HighDetail | AutoDetail

||| One piece of a message that mixes text with images, files or audio.
public export
data Part : Type where
  Text    : String -> Part
  ||| An image, by URL or as a `data:image/png;base64,...` URI.
  Image   : (url : String) -> Part
  ||| An image, with how closely to look at it.
  ImageAt : Detail -> (url : String) -> Part
  ||| A file such as a PDF, by URL or as a data URI.
  File    : (filename : String) -> (fileData : String) -> Part
  ||| Base64 audio, with its format: `"wav"` or `"mp3"`.
  Audio   : (base64 : String) -> (format : String) -> Part
  ||| The part, marked as a prompt cache breakpoint.
  Cached  : Part -> Part
  ||| A part this type has no constructor for, sent as given.
  RawPart : JSON -> Part

public export
data Content : Type where
  Plain : String -> Content
  Parts : List Part -> Content

partJSON : Part -> JSON
partJSON (Text s)  = JObject [("type", JString "text"), ("text", JString s)]
partJSON (Image u) =
  JObject [("type", JString "image_url"), ("image_url", JObject [("url", JString u)])]
partJSON (ImageAt d u) =
  JObject [ ("type", JString "image_url")
          , ("image_url", JObject [("url", JString u), ("detail", JString (detail d))]) ]
  where
    detail : Detail -> String
    detail LowDetail  = "low"
    detail HighDetail = "high"
    detail AutoDetail = "auto"
partJSON (File n d) =
  JObject [ ("type", JString "file")
          , ("file", JObject [("filename", JString n), ("file_data", JString d)]) ]
partJSON (Audio b f) =
  JObject [ ("type", JString "input_audio")
          , ("input_audio", JObject [("data", JString b), ("format", JString f)]) ]
partJSON (Cached p) = case partJSON p of
  JObject fs => JObject (fs ++ [("cache_control", JObject [("type", JString "ephemeral")])])
  j          => j
partJSON (RawPart j) = j

export
ToJSON Part where
  toJSON = partJSON

export
ToJSON Content where
  toJSON (Plain s)  = JString s
  toJSON (Parts ps) = JArray (map partJSON ps)

||| The text of some content: the text parts, joined.
export
contentText : Content -> String
contentText (Plain s)  = s
contentText (Parts ps) = concat (mapMaybe text ps)
  where
    text : Part -> Maybe String
    text (Text s)   = Just s
    text (Cached p) = text p
    text _          = Nothing

partFromJSON : JSON -> Part
partFromJSON j = case (asString (get "type" j), asString (get "text" j)) of
  (Just "text", Just s) => Text s
  _                     => RawPart j

contentFromJSON : JSON -> Maybe Content
contentFromJSON (JString s) = Just (Plain s)
contentFromJSON (JArray xs) = Just (Parts (map partFromJSON xs))
contentFromJSON _           = Nothing

--------------------------------------------------------------------------------
-- Tool calls
--------------------------------------------------------------------------------

||| A model's request to run a tool. `arguments` is JSON text, as the model
||| wrote it: it may not parse.
public export
record ToolCall where
  constructor MkToolCall
  id        : String
  name      : String
  arguments : String

export
ToJSON ToolCall where
  toJSON c = JObject
    [ ("id", JString c.id)
    , ("type", JString "function")
    , ("function", JObject [("name", JString c.name), ("arguments", JString c.arguments)]) ]

export
toolCallFromJSON : JSON -> ToolCall
toolCallFromJSON j =
  let f = get "function" j
   in MkToolCall (fromMaybe "" (asString (get "id" j)))
                 (fromMaybe "" (asString (get "name" f)))
                 (case get "arguments" f of
                    JString s => s
                    JNull     => ""
                    other     => render other)   -- some providers send an object

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

public export
record Message where
  constructor MkMessage
  role       : Role
  content    : Maybe Content
  ||| A name for the participant, where a model supports one.
  name       : Maybe String
  ||| The tools an assistant message asks to run.
  toolCalls  : List ToolCall
  ||| For a tool result: the call it answers.
  toolCallId : Maybe String
  ||| Further fields, sent as given. A decoded assistant message keeps its
  ||| `reasoning_details` here, so that sending it back in a tool loop
  ||| preserves the model's reasoning.
  extra      : List (String, JSON)

export
message : Role -> String -> Message
message r s = MkMessage r (Just (Plain s)) Nothing [] Nothing []

export
system : String -> Message
system = message System

export
developer : String -> Message
developer = message Developer

export
user : String -> Message
user = message User

export
assistant : String -> Message
assistant = message Assistant

||| A user message of several parts: `userParts [Text "What is this?", Image url]`.
export
userParts : List Part -> Message
userParts ps = MkMessage User (Just (Parts ps)) Nothing [] Nothing []

||| The result of a tool call, by the call's id.
export
toolResult : (callId : String) -> (result : String) -> Message
toolResult i s = MkMessage ToolResult (Just (Plain s)) Nothing [] (Just i) []

||| The message's content, marked as a prompt cache breakpoint: everything up
||| to and including it can be cached by providers that support caching.
export
cached : Message -> Message
cached m = { content := map mark m.content } m
  where
    markLast : List Part -> List Part
    markLast []        = []
    markLast [p]       = [Cached p]
    markLast (p :: ps) = p :: markLast ps

    mark : Content -> Content
    mark (Plain s)  = Parts [Cached (Text s)]
    mark (Parts ps) = Parts (markLast ps)

||| A string literal is a user message.
export
FromString Message where
  fromString = user

||| The text of a message, or `""` when it has none.
export
messageText : Message -> String
messageText m = maybe "" contentText m.content

export
ToJSON Message where
  toJSON m = objectOf
    [ field "role" (show m.role)
    -- an assistant message that only calls tools has a null content
    , case m.content of
        Just c  => field "content" c
        Nothing => [("content", JNull)]
    , optional "name" m.name
    , nonEmpty "tool_calls" m.toolCalls
    , optional "tool_call_id" m.toolCallId
    , m.extra ]

||| Read a message from a response.
export
messageFromJSON : JSON -> Message
messageFromJSON j = MkMessage
  (maybe Assistant parseRole (asString (get "role" j)))
  (contentFromJSON (get "content" j))
  (asString (get "name" j))
  (map toolCallFromJSON (asList (get "tool_calls" j)))
  (asString (get "tool_call_id" j))
  (case get "reasoning_details" j of
     JArray (x :: xs) => [("reasoning_details", JArray (x :: xs))]
     _                => [])
