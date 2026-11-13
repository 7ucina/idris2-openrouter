||| Requests: a model, its input, and a list of options.
|||
||| Options are plain data, so a request reads like the JSON it becomes:
|||
||| ```idris
||| chatRequest "openai/gpt-4o-mini" ["Why is the sky blue?"]
|||   [Temperature 0.2, MaxTokens 300, Provider [Sort Throughput]]
||| ```
|||
||| When an option is given twice, the later one wins. `Field` sets any
||| parameter this module has no constructor for.
module OpenRouter.Request

import Data.List
import Data.String
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Schema

%default total

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

||| A function a model may ask to have called.
public export
record Tool where
  constructor MkTool
  name        : String
  description : String
  ||| The JSON Schema of the arguments.
  schema      : JSON
  ||| Ask the provider to hold the model to the schema exactly.
  strict      : Bool

||| A tool whose arguments are described by a typed schema.
export
tool : (name : String) -> (description : String) -> Schema a -> Tool
tool n d s = MkTool n d (jsonSchema s) False

||| The tool, with the provider asked to hold the model to its schema exactly.
export
strictTool : Tool -> Tool
strictTool = { strict := True }

export
ToJSON Tool where
  toJSON t = JObject
    [ ("type", JString "function")
    , ("function", objectOf
        [ field "name" t.name
        , field "description" t.description
        , field "parameters" t.schema
        , if t.strict then field "strict" True else [] ]) ]

||| Whether and how a model uses its tools.
public export
data ToolChoiceMode : Type where
  ||| The model decides. The default when tools are given.
  Auto     : ToolChoiceMode
  ||| The model must not call a tool.
  None     : ToolChoiceMode
  ||| The model must call some tool.
  Required : ToolChoiceMode
  ||| The model must call this tool.
  Function : (name : String) -> ToolChoiceMode

export
ToJSON ToolChoiceMode where
  toJSON Auto         = JString "auto"
  toJSON None         = JString "none"
  toJSON Required     = JString "required"
  toJSON (Function n) =
    JObject [("type", JString "function"), ("function", JObject [("name", JString n)])]

--------------------------------------------------------------------------------
-- Output format
--------------------------------------------------------------------------------

public export
data Format : Type where
  ||| Any JSON object. The prompt must also ask for JSON.
  JSONObject : Format
  ||| JSON that fits a schema.
  JSONSchema : (name : String) -> (strict : Bool) -> (schema : JSON) -> Format

export
ToJSON Format where
  toJSON JSONObject         = JObject [("type", JString "json_object")]
  toJSON (JSONSchema n s j) = JObject
    [ ("type", JString "json_schema")
    , ("json_schema", JObject [("name", JString n), ("strict", JBool s), ("schema", j)]) ]

||| Strict structured output for a typed schema.
export
schemaFormat : (name : String) -> Schema a -> Format
schemaFormat n s = JSONSchema n True (jsonSchema s)

--------------------------------------------------------------------------------
-- Reasoning
--------------------------------------------------------------------------------

public export
data EffortLevel = Minimal | Low | Medium | High | XHigh

export
Show EffortLevel where
  show Minimal = "minimal"
  show Low     = "low"
  show Medium  = "medium"
  show High    = "high"
  show XHigh   = "xhigh"

public export
data ReasoningOption : Type where
  ||| How hard to think, for models that take an effort level.
  Effort  : EffortLevel -> ReasoningOption
  ||| A budget of reasoning tokens, for models that take one.
  Budget  : Nat -> ReasoningOption
  ||| Reason, but leave the reasoning out of the response.
  Exclude : Bool -> ReasoningOption
  ||| Turn reasoning on with the model's defaults, or off.
  Enabled : Bool -> ReasoningOption

reasoningField : ReasoningOption -> (String, JSON)
reasoningField (Effort e)  = ("effort", JString (show e))
reasoningField (Budget n)  = ("max_tokens", toJSON n)
reasoningField (Exclude b) = ("exclude", JBool b)
reasoningField (Enabled b) = ("enabled", JBool b)

--------------------------------------------------------------------------------
-- Provider routing
--------------------------------------------------------------------------------

public export
data DataPolicy = Allow | Deny

public export
data SortBy = Price | Throughput | Latency

public export
data ProviderOption : Type where
  ||| Providers to try, in order, by slug.
  Order             : List String -> ProviderOption
  ||| Whether other providers may serve the request when the preferred ones cannot.
  AllowFallbacks    : Bool -> ProviderOption
  ||| Only use providers that support every parameter in the request.
  RequireParameters : Bool -> ProviderOption
  ||| Whether providers that may store or train on prompts are acceptable.
  DataCollection    : DataPolicy -> ProviderOption
  ||| Only use endpoints with zero data retention.
  ZDR               : Bool -> ProviderOption
  ||| The only providers allowed.
  Only              : List String -> ProviderOption
  ||| Providers never to use.
  Ignore            : List String -> ProviderOption
  ||| Acceptable quantization levels, as `"fp8"` or `"int4"`.
  Quantizations     : List String -> ProviderOption
  ||| Prefer the cheapest, the fastest or the quickest to start.
  Sort              : SortBy -> ProviderOption
  ||| The most to pay, in dollars per million tokens: `[("prompt", 1), ("completion", 2)]`.
  MaxPrice          : List (String, Double) -> ProviderOption
  ||| Any other routing preference.
  ProviderField     : String -> JSON -> ProviderOption

providerField : ProviderOption -> (String, JSON)
providerField (Order xs)             = ("order", toJSON xs)
providerField (AllowFallbacks b)     = ("allow_fallbacks", JBool b)
providerField (RequireParameters b)  = ("require_parameters", JBool b)
providerField (DataCollection Allow) = ("data_collection", JString "allow")
providerField (DataCollection Deny)  = ("data_collection", JString "deny")
providerField (ZDR b)                = ("zdr", JBool b)
providerField (Only xs)              = ("only", toJSON xs)
providerField (Ignore xs)            = ("ignore", toJSON xs)
providerField (Quantizations xs)     = ("quantizations", toJSON xs)
providerField (Sort Price)           = ("sort", JString "price")
providerField (Sort Throughput)      = ("sort", JString "throughput")
providerField (Sort Latency)         = ("sort", JString "latency")
providerField (MaxPrice ps)          = ("max_price", JObject (map (map JNum) ps))
providerField (ProviderField k v)    = (k, v)

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

public export
data Option : Type where
  Temperature         : Double -> Option
  TopP                : Double -> Option
  TopK                : Nat -> Option
  MinP                : Double -> Option
  TopA                : Double -> Option
  FrequencyPenalty    : Double -> Option
  PresencePenalty     : Double -> Option
  RepetitionPenalty   : Double -> Option
  ||| Make sampling repeatable, where the provider supports it.
  Seed                : Integer -> Option
  ||| The most tokens to generate, sent as `max_tokens`.
  MaxTokens           : Nat -> Option
  ||| The same limit under its newer name, `max_completion_tokens`.
  MaxCompletionTokens : Nat -> Option
  ||| Stop generating at any of these strings.
  Stop                : List String -> Option
  ||| A bias per token id, from -100 to 100.
  LogitBias           : List (Integer, Double) -> Option
  ||| Return the log probability of each generated token.
  Logprobs            : Bool -> Option
  ||| With `Logprobs True`: how many alternatives to return at each position.
  TopLogprobs         : Nat -> Option
  Tools               : List Tool -> Option
  ToolChoice          : ToolChoiceMode -> Option
  ParallelToolCalls   : Bool -> Option
  ResponseFormat      : Format -> Option
  Reasoning           : List ReasoningOption -> Option
  ||| Models to fall back to, in order, when the first cannot answer.
  Fallbacks           : List String -> Option
  Provider            : List ProviderOption -> Option
  ||| Plugins, each as its JSON object. See `plugin` and `webSearch`.
  Plugins             : List JSON -> Option
  ||| Prompt transforms, as `["middle-out"]`.
  Transforms          : List String -> Option
  ||| The kinds of output wanted, as `["image", "text"]`.
  Modalities          : List String -> Option
  ||| A stable id for your end user, which helps OpenRouter detect abuse.
  EndUser             : String -> Option
  ||| Any other parameter, by its JSON name.
  Field               : String -> JSON -> Option

||| A plugin by its id, with its settings.
export
plugin : (id : String) -> (settings : List (String, JSON)) -> JSON
plugin i settings = JObject (("id", JString i) :: settings)

||| The web search plugin with its defaults.
export
webSearch : JSON
webSearch = plugin "web" []

optionField : Option -> (String, JSON)
optionField (Temperature x)         = ("temperature", JNum x)
optionField (TopP x)                = ("top_p", JNum x)
optionField (TopK n)                = ("top_k", toJSON n)
optionField (MinP x)                = ("min_p", JNum x)
optionField (TopA x)                = ("top_a", JNum x)
optionField (FrequencyPenalty x)    = ("frequency_penalty", JNum x)
optionField (PresencePenalty x)     = ("presence_penalty", JNum x)
optionField (RepetitionPenalty x)   = ("repetition_penalty", JNum x)
optionField (Seed n)                = ("seed", JInt n)
optionField (MaxTokens n)           = ("max_tokens", toJSON n)
optionField (MaxCompletionTokens n) = ("max_completion_tokens", toJSON n)
optionField (Stop xs)               = ("stop", toJSON xs)
optionField (LogitBias bs)          = ("logit_bias", JObject (map (\(t, b) => (show t, JNum b)) bs))
optionField (Logprobs b)            = ("logprobs", JBool b)
optionField (TopLogprobs n)         = ("top_logprobs", toJSON n)
optionField (Tools ts)              = ("tools", toJSON ts)
optionField (ToolChoice c)          = ("tool_choice", toJSON c)
optionField (ParallelToolCalls b)   = ("parallel_tool_calls", JBool b)
optionField (ResponseFormat f)      = ("response_format", toJSON f)
optionField (Reasoning os)          = ("reasoning", JObject (lastWins (map reasoningField os)))
optionField (Fallbacks ms)          = ("models", toJSON ms)
optionField (Provider os)           = ("provider", JObject (lastWins (map providerField os)))
optionField (Plugins ps)            = ("plugins", JArray ps)
optionField (Transforms ts)         = ("transforms", toJSON ts)
optionField (Modalities ms)         = ("modalities", toJSON ms)
optionField (EndUser u)             = ("user", JString u)
optionField (Field k v)             = (k, v)

||| The JSON fields of some options. A later option replaces an earlier one
||| of the same name.
export
optionFields : List Option -> List (String, JSON)
optionFields = lastWins . map optionField

--------------------------------------------------------------------------------
-- Chat requests
--------------------------------------------------------------------------------

public export
record ChatRequest where
  constructor MkChatRequest
  ||| A model id, as `"anthropic/claude-sonnet-4.5"`. Suffixes such as
  ||| `:free`, `:nitro` and `:online` work as OpenRouter documents them.
  model    : String
  messages : List Message
  options  : List Option

||| A chat request. String literals in the message list are user messages.
public export
chatRequest : (model : String) -> List Message -> List Option -> ChatRequest
chatRequest = MkChatRequest

||| Add options to a request. They take precedence over the ones it has.
export
withOptions : List Option -> ChatRequest -> ChatRequest
withOptions os = { options $= (++ os) }

||| Add messages to the end of a request.
export
withMessages : List Message -> ChatRequest -> ChatRequest
withMessages ms = { messages $= (++ ms) }

||| The request body. With `stream`, the answer comes as server-sent events.
export
chatBody : (stream : Bool) -> ChatRequest -> JSON
chatBody stream r = JObject $ lastWins $
  [("model", JString r.model), ("messages", toJSON r.messages)]
    ++ optionFields r.options
    ++ (if stream then [("stream", JBool True)] else [])

export
ToJSON ChatRequest where
  toJSON = chatBody False

--------------------------------------------------------------------------------
-- Text completion requests
--------------------------------------------------------------------------------

||| A request to continue a prompt, with no chat template applied.
public export
record CompletionRequest where
  constructor MkCompletionRequest
  model   : String
  prompt  : String
  options : List Option

public export
completionRequest : (model : String) -> (prompt : String) -> List Option -> CompletionRequest
completionRequest = MkCompletionRequest

export
completionBody : (stream : Bool) -> CompletionRequest -> JSON
completionBody stream r = JObject $ lastWins $
  [("model", JString r.model), ("prompt", JString r.prompt)]
    ++ optionFields r.options
    ++ (if stream then [("stream", JBool True)] else [])

export
ToJSON CompletionRequest where
  toJSON = completionBody False

--------------------------------------------------------------------------------
-- Embedding requests
--------------------------------------------------------------------------------

||| A request to embed some texts. Useful options: `Provider`, and
||| `Field "dimensions" (JInt 256)` for models that can shorten their vectors.
public export
record EmbeddingRequest where
  constructor MkEmbeddingRequest
  model   : String
  input   : List String
  options : List Option

public export
embeddingRequest : (model : String) -> (input : List String) -> List Option -> EmbeddingRequest
embeddingRequest = MkEmbeddingRequest

export
ToJSON EmbeddingRequest where
  toJSON r = JObject $ lastWins $
    [("model", JString r.model), ("input", toJSON r.input)] ++ optionFields r.options
