||| The Responses API (`/responses`): OpenAI's newer request shape, served by
||| OpenRouter for every model. A request is a list of items rather than
||| chat messages, and a response is a list of output items: messages,
||| reasoning, and tool calls.
|||
||| ```idris
||| Right r <- respond client (responsesRequest "openai/gpt-4o-mini" [say User "Hello"] [])
||| putStrLn (outputText r)
||| ```
|||
||| OpenRouter keeps no conversation state, so a follow-up request carries the
||| conversation itself: the earlier input, then `outputItems` of the earlier
||| response, then what is new.
module OpenRouter.Responses

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
import OpenRouter.Schema
import OpenRouter.Tools

%default total

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

||| One item of a request's input.
public export
data Item : Type where
  ||| A message of plain text.
  Say            : Role -> String -> Item
  ||| A message of several parts: text, images, files, audio.
  SayParts       : Role -> List Part -> Item
  ||| A tool call the model made earlier.
  FunctionCall   : (callId : String) -> (name : String) -> (arguments : String) -> Item
  ||| The result of a tool call, by the call's id.
  FunctionOutput : (callId : String) -> (output : String) -> Item
  ||| Any other item, as its JSON: an output item being sent back, for one.
  RawItem        : JSON -> Item

||| A message of plain text.
public export
say : Role -> String -> Item
say = Say

inputPart : Part -> JSON
inputPart (Text s)         = JObject [("type", JString "input_text"), ("text", JString s)]
inputPart (Image u)        = JObject [("type", JString "input_image"), ("image_url", JString u), ("detail", JString "auto")]
inputPart (ImageAt d u)    =
  JObject [ ("type", JString "input_image"), ("image_url", JString u)
          , ("detail", JString (case d of { LowDetail => "low"; HighDetail => "high"; AutoDetail => "auto" })) ]
inputPart (File n d)       = JObject [("type", JString "input_file"), ("filename", JString n), ("file_data", JString d)]
inputPart (Audio b f)      =
  JObject [("type", JString "input_audio"), ("input_audio", JObject [("data", JString b), ("format", JString f)])]
inputPart (Video u)        = JObject [("type", JString "input_video"), ("video_url", JString u)]
inputPart (Cached p)       = inputPart p
inputPart (RawPart j)      = j

export
ToJSON Item where
  toJSON (Say r s)            = JObject [("type", JString "message"), ("role", JString (show r)), ("content", JString s)]
  toJSON (SayParts r ps)      =
    JObject [("type", JString "message"), ("role", JString (show r)), ("content", JArray (map inputPart ps))]
  toJSON (FunctionCall i n a) =
    JObject [("type", JString "function_call"), ("call_id", JString i), ("name", JString n), ("arguments", JString a)]
  toJSON (FunctionOutput i o) =
    JObject [("type", JString "function_call_output"), ("call_id", JString i), ("output", JString o)]
  toJSON (RawItem j)          = j

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

||| A request to the Responses API. It takes the same options as a chat
||| request; the ones the two APIs name differently (the token limit, tools,
||| the output format) are translated. `Instructions` sets the system prompt.
public export
record ResponsesRequest where
  constructor MkResponsesRequest
  model   : String
  input   : List Item
  options : List Option

public export
responsesRequest : (model : String) -> List Item -> List Option -> ResponsesRequest
responsesRequest = MkResponsesRequest

-- The Responses API writes a function tool flat, where chat nests it.
flatTool : Tool -> JSON
flatTool t = objectOf
  [ field "type" "function"
  , field "name" t.name
  , field "description" t.description
  , field "parameters" t.schema
  , if t.strict then field "strict" True else [] ]

responsesField : Option -> (String, JSON)
responsesField (MaxTokens n)           = ("max_output_tokens", toJSON n)
responsesField (MaxCompletionTokens n) = ("max_output_tokens", toJSON n)
responsesField (ToolChoice (Function n)) =
  ("tool_choice", JObject [("type", JString "function"), ("name", JString n)])
responsesField (ResponseFormat f)      = ("text", JObject [("format", format f)])
  where
    format : Format -> JSON
    format (JSONSchema n s j) =
      JObject [("type", JString "json_schema"), ("name", JString n), ("strict", JBool s), ("schema", j)]
    format other              = toJSON other
responsesField o                       = optionField o

||| The request body. With `stream`, the answer comes as server-sent events.
export
responsesBody : (stream : Bool) -> ResponsesRequest -> JSON
responsesBody stream r = JObject $ lastWins $
  [("model", JString r.model), ("input", toJSON r.input)]
    ++ map responsesField (filter (not . isTools) r.options)
    ++ tools
    ++ (if stream then [("stream", JBool True)] else [])
  where
    isTools : Option -> Bool
    isTools (Tools _)       = True
    isTools (ServerTools _) = True
    isTools _               = False

    tools : List (String, JSON)
    tools =
      let functions = concatMap (\o => case o of { Tools ts => map flatTool ts; _ => [] }) r.options
          servers   = concatMap (\o => case o of { ServerTools ts => ts; _ => [] }) r.options
       in if null functions && null servers then [] else [("tools", JArray (functions ++ servers))]

export
ToJSON ResponsesRequest where
  toJSON = responsesBody False

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

||| One item of a response's output.
public export
data OutputItem : Type where
  ||| Text the model wrote, with the sources it cites.
  OutputMessage : (text : String) -> List Citation -> OutputItem
  ||| The model declined, and says why.
  OutputRefusal : String -> OutputItem
  ||| A summary of the model's reasoning.
  OutputReasoning : String -> OutputItem
  ||| A request to run one of the request's function tools.
  OutputCall    : ToolCall -> OutputItem
  ||| Anything else (a web search, a generated image, ...), by its type.
  OtherOutput   : (type : String) -> JSON -> OutputItem

export
outputItemFromJSON : JSON -> OutputItem
outputItemFromJSON j = case asString (get "type" j) of
  Just "message" =>
    let parts = asList (get "content" j)
        texts = mapMaybe (\p => if asString (get "type" p) == Just "output_text" then asString (get "text" p) else Nothing) parts
        cites = concatMap (citationsFromJSON . get "annotations") parts
     in case (texts, mapMaybe (asString . get "refusal") parts) of
          ([], r :: _) => OutputRefusal r
          _            => OutputMessage (concat texts) cites
  Just "reasoning" =>
    OutputReasoning (joinBy "\n" (mapMaybe (asString . get "text") (asList (get "summary" j) ++ asList (get "content" j))))
  Just "function_call" =>
    OutputCall (MkToolCall (fromMaybe "" (asString (get "call_id" j)))
                     (fromMaybe "" (asString (get "name" j)))
                     (fromMaybe "" (asString (get "arguments" j))))
  Just t  => OtherOutput t j
  Nothing => OtherOutput "" j

public export
record ModelResponse where
  constructor MkModelResponse
  id      : String
  model   : String
  ||| `"completed"`, `"incomplete"` (it ran out of tokens, say), `"failed"`.
  status  : String
  output  : List OutputItem
  ||| The output items as they arrived, to send back as input in a follow-up
  ||| request (see `outputItems`).
  items   : List JSON
  usage   : Maybe Usage
  raw     : JSON

-- The Responses API counts input and output tokens; a Usage counts prompt
-- and completion tokens. They are the same things.
responsesUsage : JSON -> Maybe Usage
responsesUsage JNull = Nothing
responsesUsage j = Just $ MkUsage
  (fromMaybe 0 (asNat (get "input_tokens" j)))
  (fromMaybe 0 (asNat (get "output_tokens" j)))
  (fromMaybe 0 (asNat (get "total_tokens" j)))
  (asNat (path ["output_tokens_details", "reasoning_tokens"] j))
  (asNat (path ["input_tokens_details", "cached_tokens"] j))
  (asNat (path ["input_tokens_details", "cache_write_tokens"] j))
  (asDouble (get "cost" j))
  j

export
modelResponseFromJSON : JSON -> ModelResponse
modelResponseFromJSON j = MkModelResponse
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "model" j)))
  (fromMaybe "" (asString (get "status" j)))
  (map outputItemFromJSON (asList (get "output" j)))
  (asList (get "output" j))
  (responsesUsage (get "usage" j))
  j

||| The text of a response: its messages, joined.
export
outputText : ModelResponse -> String
outputText r = concat (mapMaybe text r.output)
  where
    text : OutputItem -> Maybe String
    text (OutputMessage t _) = Just t
    text _                   = Nothing

||| The summaries of the model's reasoning, joined.
export
outputReasoning : ModelResponse -> String
outputReasoning r = joinBy "\n" (mapMaybe reasoning r.output)
  where
    reasoning : OutputItem -> Maybe String
    reasoning (OutputReasoning t) = Just t
    reasoning _             = Nothing

||| The tools the model asked to run.
export
functionCalls : ModelResponse -> List ToolCall
functionCalls r = mapMaybe call r.output
  where
    call : OutputItem -> Maybe ToolCall
    call (OutputCall c) = Just c
    call _        = Nothing

||| The sources the response cites.
export
outputCitations : ModelResponse -> List Citation
outputCitations r = concatMap cites r.output
  where
    cites : OutputItem -> List Citation
    cites (OutputMessage _ cs) = cs
    cites _                    = []

||| A response's output as input items, for the follow-up request: append
||| them to the earlier input, then add what is new.
export
outputItems : ModelResponse -> List Item
outputItems r = map RawItem r.items

-- A response that failed carries its error inside itself.
failure : JSON -> Maybe Error
failure j = case get "error" j of
  JNull => Nothing
  e     => Just (Api (MkApiError
             (fromMaybe 500 (cast <$> asInteger (get "code" e)))
             (fromMaybe "the response failed" (asString (get "message" e)))
             Nothing e Nothing))

--------------------------------------------------------------------------------
-- Calling
--------------------------------------------------------------------------------

||| Send a request to the Responses API and wait for the whole response.
export covering
respond : HasIO io => Client -> ResponsesRequest -> io (Either Error ModelResponse)
respond c r = do
  Right j <- call c POST "/responses" [] (Just (responsesBody False r))
    | Left e => pure (Left e)
  pure (Right (modelResponseFromJSON j))

||| Send a request whose reply must fit a schema, and get the reply as a
||| value of the schema's type.
export covering
respondAs : HasIO io => Client -> (name : String) -> Schema a -> ResponsesRequest
         -> io (Either Error (a, ModelResponse))
respondAs c name schema r = do
  Right resp <- respond c ({ options $= (++ [ResponseFormat (schemaFormat name schema)]) } r)
    | Left e => pure (Left e)
  pure $ case decodeText schema (outputText resp) of
    Left m  => Left (Mismatched m (outputText resp))
    Right x => Right (x, resp)

||| What a streamed response says as it arrives.
public export
data ResponseEvent : Type where
  ||| More of the reply's text.
  TextDelta      : String -> ResponseEvent
  ||| More of the reasoning summary.
  ReasoningDelta : String -> ResponseEvent
  ||| More of a tool call's arguments.
  ArgumentsDelta : String -> ResponseEvent
  ||| An output item is complete.
  ItemDone       : OutputItem -> ResponseEvent
  ||| Any other event, by its type.
  OtherEvent     : (type : String) -> JSON -> ResponseEvent

export
responseEventFromJSON : JSON -> ResponseEvent
responseEventFromJSON j =
  let type  = fromMaybe "" (asString (get "type" j))
      delta = fromMaybe "" (asString (get "delta" j))
   in if type == "response.output_text.delta" then TextDelta delta
      else if type == "response.reasoning_summary_text.delta" || type == "response.reasoning_text.delta"
        then ReasoningDelta delta
      else if type == "response.function_call_arguments.delta" then ArgumentsDelta delta
      else if type == "response.output_item.done" then ItemDone (outputItemFromJSON (get "item" j))
      else OtherEvent type j

||| Send a request, hand each event to `onEvent` as it arrives, and return
||| the whole response at the end: the same value `respond` would have
||| returned.
export covering
respondStream : HasIO io => Client -> ResponsesRequest -> (onEvent : ResponseEvent -> io ())
             -> io (Either Error ModelResponse)
respondStream c r onEvent = do
  Right s <- openEventStream c "/responses" (responsesBody True r)
    | Left e => pure (Left e)
  items <- newIORef (the (SnocList JSON) [<])
  loop s items
  where
    done : EventStream -> Either Error ModelResponse -> io (Either Error ModelResponse)
    done s result = closeEventStream s >> pure result

    loop : EventStream -> IORef (SnocList JSON) -> io (Either Error ModelResponse)
    loop s items = do
      Right (Just (_, j)) <- nextJSON s
        | Left e => done s (Left e)
        | Right Nothing => do
            -- the stream ended without saying it was complete: return what arrived
            got <- readIORef items
            done s (Right (modelResponseFromJSON (JObject [("status", JString "incomplete"), ("output", JArray (got <>> []))])))
      let type = fromMaybe "" (asString (get "type" j))
      if type == "response.completed" || type == "response.incomplete"
         then done s (Right (modelResponseFromJSON (get "response" j)))
         else if type == "response.failed"
           then done s (Left (fromMaybe (Malformed "the response failed" (render j)) (failure (get "response" j))))
           else if type == "error"
             then done s (Left (Api (MkApiError (fromMaybe 500 (cast <$> asInteger (get "code" j)))
                                      (fromMaybe "the stream failed" (asString (get "message" j))) Nothing j Nothing)))
             else do
               when (type == "response.output_item.done") (modifyIORef items (:< get "item" j))
               onEvent (responseEventFromJSON j)
               loop s items

||| `respondStream` for the common case: `onText` gets each piece of the
||| reply's text.
export covering
respondStreamText : HasIO io => Client -> ResponsesRequest -> (onText : String -> io ())
                 -> io (Either Error ModelResponse)
respondStreamText c r onText = respondStream c r $ \event => case event of
  TextDelta t => onText t
  _           => pure ()

||| The Responses API with tools: send the request, run the tools the model
||| calls, send the results back, and repeat until the model answers without
||| calling a tool, or until tools have been run `maxRounds` times. The
||| result is the last response.
export covering
respondWithTools : HasIO io => Client -> List (Handler io) -> (maxRounds : Nat) -> ResponsesRequest
                -> io (Either Error ModelResponse)
respondWithTools c handlers maxRounds request =
  go maxRounds ({ options $= (++ [Tools (map tool handlers)]) } request)
  where
    answer : ToolCall -> io Item
    answer call = case find (\h => h.tool.name == call.name) handlers of
      Just h  => FunctionOutput call.id <$> h.run call.arguments
      Nothing => pure (FunctionOutput call.id ("Error: there is no tool named " ++ call.name ++ "."))

    go : Nat -> ResponsesRequest -> io (Either Error ModelResponse)
    go rounds r = do
      Right resp <- respond c r
        | Left e => pure (Left e)
      case (rounds, functionCalls resp) of
        (_, [])      => pure (Right resp)
        (Z, _)       => pure (Right resp)
        (S k, calls) => do
          results <- traverse answer calls
          go k ({ input := r.input ++ outputItems resp ++ results } r)
