||| The Anthropic Messages API (`/messages`), which OpenRouter serves for
||| every model, not only Anthropic's. Use it when you want Anthropic's
||| request shape: content blocks, a `system` field, thinking blocks.
|||
||| ```idris
||| Right m <- createMessage client $
|||   messagesRequest "anthropic/claude-haiku-4.5" 1024 [userTurn "Hello"] []
||| putStrLn (blocksText m.content)
||| ```
module OpenRouter.Anthropic

import Data.IORef
import Data.List
import Data.Maybe
import Data.SnocList
import Data.String
import OpenRouter.Client
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Request
import OpenRouter.Response

%default total

--------------------------------------------------------------------------------
-- Blocks and turns
--------------------------------------------------------------------------------

||| One block of a turn's content.
public export
data Block : Type where
  TextBlock   : String -> Block
  ||| An image, as base64 data of a media type such as `"image/png"`.
  ImageBlock  : (mediaType : String) -> (base64 : String) -> Block
  ||| The model asks for a tool to be run. `input` is the arguments, as JSON.
  ToolUse     : (id : String) -> (name : String) -> (input : JSON) -> Block
  ||| The result of a tool, by the id of its `ToolUse`.
  ToolOutput  : (toolUseId : String) -> (content : String) -> (isError : Bool) -> Block
  ||| The model's thinking, with the signature that lets it be sent back.
  Thinking    : (thinking : String) -> (signature : String) -> Block
  ||| Any other block, as its JSON.
  RawBlock    : JSON -> Block

export
ToJSON Block where
  toJSON (TextBlock s)      = JObject [("type", JString "text"), ("text", JString s)]
  toJSON (ImageBlock m b)   =
    JObject [ ("type", JString "image")
            , ("source", JObject [("type", JString "base64"), ("media_type", JString m), ("data", JString b)]) ]
  toJSON (ToolUse i n j)    = JObject [("type", JString "tool_use"), ("id", JString i), ("name", JString n), ("input", j)]
  toJSON (ToolOutput i c e) =
    objectOf [ field "type" "tool_result", field "tool_use_id" i, field "content" c
             , if e then field "is_error" True else [] ]
  toJSON (Thinking t s)     = JObject [("type", JString "thinking"), ("thinking", JString t), ("signature", JString s)]
  toJSON (RawBlock j)       = j

export
blockFromJSON : JSON -> Block
blockFromJSON j = case asString (get "type" j) of
  Just "text"     => TextBlock (fromMaybe "" (asString (get "text" j)))
  Just "tool_use" => ToolUse (fromMaybe "" (asString (get "id" j))) (fromMaybe "" (asString (get "name" j))) (get "input" j)
  Just "thinking" => Thinking (fromMaybe "" (asString (get "thinking" j))) (fromMaybe "" (asString (get "signature" j)))
  _               => RawBlock j

||| One turn of the conversation: the user's or the assistant's.
public export
record Turn where
  constructor MkTurn
  role    : Role
  content : List Block

||| A user turn of plain text.
public export
userTurn : String -> Turn
userTurn s = MkTurn User [TextBlock s]

||| An assistant turn of plain text.
public export
assistantTurn : String -> Turn
assistantTurn s = MkTurn Assistant [TextBlock s]

export
ToJSON Turn where
  toJSON t = JObject [("role", JString (show t.role)), ("content", toJSON t.content)]

||| The text in some blocks, joined.
export
blocksText : List Block -> String
blocksText = concat . mapMaybe text
  where
    text : Block -> Maybe String
    text (TextBlock s) = Just s
    text _             = Nothing

||| The tools some blocks ask for, as tool calls whose arguments are JSON
||| text: the form `Handler`s take.
export
toolUses : List Block -> List ToolCall
toolUses = mapMaybe use
  where
    use : Block -> Maybe ToolCall
    use (ToolUse i n j) = Just (MkToolCall i n (render j))
    use _               = Nothing

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

||| A request to the Messages API. It takes the same options as a chat
||| request; the ones Anthropic names differently (stop sequences, tools,
||| tool choice, thinking) are translated. `Instructions` sets the system
||| prompt, and `Reasoning [Budget n]` turns thinking on.
public export
record MessagesRequest where
  constructor MkMessagesRequest
  model     : String
  ||| The most tokens to generate. Anthropic's API requires it.
  maxTokens : Nat
  messages  : List Turn
  options   : List Option

public export
messagesRequest : (model : String) -> (maxTokens : Nat) -> List Turn -> List Option -> MessagesRequest
messagesRequest = MkMessagesRequest

anthropicTool : Tool -> JSON
anthropicTool t =
  JObject [("name", JString t.name), ("description", JString t.description), ("input_schema", t.schema)]

messagesField : Option -> List (String, JSON)
messagesField (Instructions s)        = [("system", JString s)]
messagesField (Stop xs)               = [("stop_sequences", toJSON xs)]
messagesField (MaxTokens n)           = [("max_tokens", toJSON n)]
messagesField (MaxCompletionTokens n) = [("max_tokens", toJSON n)]
messagesField (ToolChoice Auto)       = [("tool_choice", JObject [("type", JString "auto")])]
messagesField (ToolChoice None)       = [("tool_choice", JObject [("type", JString "none")])]
messagesField (ToolChoice Required)   = [("tool_choice", JObject [("type", JString "any")])]
messagesField (ToolChoice (Function n)) =
  [("tool_choice", JObject [("type", JString "tool"), ("name", JString n)])]
messagesField (Reasoning os)          = concatMap thinking os
  where
    thinking : ReasoningOption -> List (String, JSON)
    thinking (Budget n)      = [("thinking", JObject [("type", JString "enabled"), ("budget_tokens", toJSON n)])]
    thinking (Enabled False) = [("thinking", JObject [("type", JString "disabled")])]
    thinking _               = []
messagesField o                       = [optionField o]

||| The request body. With `stream`, the answer comes as server-sent events.
export
messagesBody : (stream : Bool) -> MessagesRequest -> JSON
messagesBody stream r = JObject $ lastWins $
  [("model", JString r.model), ("max_tokens", toJSON r.maxTokens), ("messages", toJSON r.messages)]
    ++ concatMap messagesField (filter (not . isTools) r.options)
    ++ tools
    ++ (if stream then [("stream", JBool True)] else [])
  where
    isTools : Option -> Bool
    isTools (Tools _)       = True
    isTools (ServerTools _) = True
    isTools _               = False

    tools : List (String, JSON)
    tools =
      let functions = concatMap (\o => case o of { Tools ts => map anthropicTool ts; _ => [] }) r.options
          servers   = concatMap (\o => case o of { ServerTools ts => ts; _ => [] }) r.options
       in if null functions && null servers then [] else [("tools", JArray (functions ++ servers))]

export
ToJSON MessagesRequest where
  toJSON = messagesBody False

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

public export
record MessagesResponse where
  constructor MkMessagesResponse
  id         : String
  model      : String
  content    : List Block
  ||| `"end_turn"`, `"max_tokens"`, `"stop_sequence"`, `"tool_use"`, ...
  stopReason : Maybe String
  usage      : Maybe Usage
  raw        : JSON

anthropicUsage : JSON -> Maybe Usage
anthropicUsage JNull = Nothing
anthropicUsage j =
  let input  = fromMaybe 0 (asNat (get "input_tokens" j))
      output = fromMaybe 0 (asNat (get "output_tokens" j))
   in Just $ MkUsage input output (input + output) Nothing
        (asNat (get "cache_read_input_tokens" j))
        (asNat (get "cache_creation_input_tokens" j))
        (asDouble (get "cost" j))
        j

export
messagesResponseFromJSON : JSON -> MessagesResponse
messagesResponseFromJSON j = MkMessagesResponse
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "model" j)))
  (map blockFromJSON (asList (get "content" j)))
  (asString (get "stop_reason" j))
  (anthropicUsage (get "usage" j))
  j

||| The reply as a turn, to append to the conversation.
export
replyTurn : MessagesResponse -> Turn
replyTurn r = MkTurn Assistant r.content

--------------------------------------------------------------------------------
-- Calling
--------------------------------------------------------------------------------

||| Send a request to the Messages API and wait for the whole reply.
export covering
createMessage : HasIO io => Client -> MessagesRequest -> io (Either Error MessagesResponse)
createMessage c r = do
  Right j <- call c POST "/messages" [] (Just (messagesBody False r))
    | Left e => pure (Left e)
  pure (Right (messagesResponseFromJSON j))

||| What a streamed message says as it arrives.
public export
data MessageEvent : Type where
  ||| More of the reply's text.
  TextPiece     : String -> MessageEvent
  ||| More of the model's thinking.
  ThinkingPiece : String -> MessageEvent
  ||| More of a tool call's arguments, as JSON text.
  InputPiece    : String -> MessageEvent
  ||| A content block is complete.
  BlockDone     : Block -> MessageEvent
  ||| Any other event, by its type.
  OtherMessageEvent : (type : String) -> JSON -> MessageEvent

-- A block being assembled from deltas.
record Building where
  constructor MkBuilding
  start     : JSON              -- the content_block of content_block_start
  text      : SnocList String
  thinking  : SnocList String
  signature : SnocList String
  input     : SnocList String

built : Building -> Block
built b = case asString (get "type" b.start) of
  Just "text"     => TextBlock (fromMaybe "" (asString (get "text" b.start)) ++ concat b.text)
  Just "thinking" => Thinking (fromMaybe "" (asString (get "thinking" b.start)) ++ concat b.thinking) (concat b.signature)
  Just "tool_use" =>
    let written = concat b.input
     in ToolUse (fromMaybe "" (asString (get "id" b.start))) (fromMaybe "" (asString (get "name" b.start)))
          (if trim written == "" then get "input" b.start else either (const (JString written)) id (parse written))
  _               => blockFromJSON b.start

record Assembly where
  constructor MkAssembly
  message : JSON                -- the message of message_start
  blocks  : SnocList Block
  current : Maybe Building
  stop    : Maybe String
  usage   : JSON

||| Send a request, hand each event to `onEvent` as it arrives, and return
||| the whole reply at the end: the same value `createMessage` would have
||| returned.
export covering
streamMessage : HasIO io => Client -> MessagesRequest -> (onEvent : MessageEvent -> io ())
             -> io (Either Error MessagesResponse)
streamMessage c r onEvent = do
  Right s <- openEventStream c "/messages" (messagesBody True r)
    | Left e => pure (Left e)
  loop s (MkAssembly JNull [<] Nothing Nothing JNull)
  where
    result : Assembly -> MessagesResponse
    result a = MkMessagesResponse
      (fromMaybe "" (asString (get "id" a.message)))
      (fromMaybe "" (asString (get "model" a.message)))
      (a.blocks <>> maybe [] (\b => [built b]) a.current)
      a.stop
      -- the first event counts the input, the last counts the output
      (anthropicUsage (JObject (lastWins (asFields (get "usage" a.message) ++ asFields a.usage))))
      JNull

    loop : EventStream -> Assembly -> io (Either Error MessagesResponse)
    loop s a = do
      Right (Just (_, j)) <- nextJSON s
        | Left e        => closeEventStream s >> pure (Left e)
        | Right Nothing => closeEventStream s >> pure (Right (result a))
      let type  = fromMaybe "" (asString (get "type" j))
          delta = get "delta" j
      case type of
        "message_start"       => loop s ({ message := get "message" j } a)
        "content_block_start" => loop s ({ current := Just (MkBuilding (get "content_block" j) [<] [<] [<] [<]) } a)
        "content_block_delta" => case (asString (get "type" delta), a.current) of
          (Just "text_delta", Just b) => do
            let t = fromMaybe "" (asString (get "text" delta))
            onEvent (TextPiece t)
            loop s ({ current := Just ({ text $= (:< t) } b) } a)
          (Just "thinking_delta", Just b) => do
            let t = fromMaybe "" (asString (get "thinking" delta))
            onEvent (ThinkingPiece t)
            loop s ({ current := Just ({ thinking $= (:< t) } b) } a)
          (Just "signature_delta", Just b) =>
            loop s ({ current := Just ({ signature $= (:< fromMaybe "" (asString (get "signature" delta))) } b) } a)
          (Just "input_json_delta", Just b) => do
            let t = fromMaybe "" (asString (get "partial_json" delta))
            onEvent (InputPiece t)
            loop s ({ current := Just ({ input $= (:< t) } b) } a)
          _ => onEvent (OtherMessageEvent type j) >> loop s a
        "content_block_stop"  => case a.current of
          Just b  => do onEvent (BlockDone (built b))
                        loop s ({ blocks $= (:< built b), current := Nothing } a)
          Nothing => loop s a
        "message_delta"       =>
          loop s ({ stop := asString (get "stop_reason" delta) <|> a.stop, usage := get "usage" j } a)
        "message_stop"        => closeEventStream s >> pure (Right (result a))
        "ping"                => loop s a
        _                     => onEvent (OtherMessageEvent type j) >> loop s a

||| `streamMessage` for the common case: `onText` gets each piece of the
||| reply's text.
export covering
streamMessageText : HasIO io => Client -> MessagesRequest -> (onText : String -> io ())
                 -> io (Either Error MessagesResponse)
streamMessageText c r onText = streamMessage c r $ \event => case event of
  TextPiece t => onText t
  _           => pure ()
