||| The catalog and the account: models, endpoints, providers, the current
||| key, credits, and the record of a past generation.
module OpenRouter.Model

import Data.List
import Data.Maybe
import Data.String
import OpenRouter.JSON

%default total

--------------------------------------------------------------------------------
-- Models
--------------------------------------------------------------------------------

||| Prices in US dollars. `prompt` and `completion` are per token.
public export
record Pricing where
  constructor MkPricing
  prompt     : Maybe Double
  completion : Maybe Double
  ||| Per request.
  request    : Maybe Double
  ||| Per input image.
  image      : Maybe Double
  ||| Per cached prompt token read.
  cacheRead  : Maybe Double
  raw        : JSON

export
pricingFromJSON : JSON -> Pricing
pricingFromJSON j = MkPricing
  (asAmount (get "prompt" j))
  (asAmount (get "completion" j))
  (asAmount (get "request" j))
  (asAmount (get "image" j))
  (asAmount (get "input_cache_read" j))
  j

public export
record Model where
  constructor MkModel
  ||| The id to put in a request, as `"openai/gpt-4o-mini"`.
  id                  : String
  name                : String
  description         : String
  ||| When the model was added, in seconds since 1970.
  created             : Maybe Integer
  ||| The context window, in tokens.
  contextLength       : Maybe Nat
  ||| The most tokens the top provider will generate.
  maxCompletionTokens : Maybe Nat
  pricing             : Pricing
  ||| What the model reads: `"text"`, `"image"`, `"file"`, `"audio"`.
  inputModalities     : List String
  outputModalities    : List String
  ||| The request parameters the model takes, as `"tools"` and `"reasoning"`.
  supportedParameters : List String
  ||| Whether the top provider applies its own moderation.
  moderated           : Bool
  ||| For a speech model: the voices it has.
  voices              : List String
  raw                 : JSON

export
modelFromJSON : JSON -> Model
modelFromJSON j = MkModel
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "name" j)))
  (fromMaybe "" (asString (get "description" j)))
  (asInteger (get "created" j))
  (asNat (get "context_length" j))
  (asNat (path ["top_provider", "max_completion_tokens"] j))
  (pricingFromJSON (get "pricing" j))
  (asStrings (path ["architecture", "input_modalities"] j))
  (asStrings (path ["architecture", "output_modalities"] j))
  (asStrings (get "supported_parameters" j))
  (fromMaybe False (asBool (path ["top_provider", "is_moderated"] j)))
  (asStrings (get "supported_voices" j))
  j

||| Whether a model takes a request parameter, as `"tools"` or
||| `"structured_outputs"`.
export
supports : String -> Model -> Bool
supports p m = elem p m.supportedParameters

||| One provider's offering of a model.
public export
record Endpoint where
  constructor MkEndpoint
  name                : String
  providerName        : String
  ||| The provider's slug, for `Order`, `Only` and `Ignore`.
  tag                 : String
  contextLength       : Maybe Nat
  maxCompletionTokens : Maybe Nat
  pricing             : Pricing
  quantization        : Maybe String
  supportedParameters : List String
  ||| The share of recent requests that succeeded, in percent.
  uptimeLast30m       : Maybe Double
  raw                 : JSON

export
endpointFromJSON : JSON -> Endpoint
endpointFromJSON j = MkEndpoint
  (fromMaybe "" (asString (get "name" j)))
  (fromMaybe "" (asString (get "provider_name" j)))
  (fromMaybe "" (asString (get "tag" j)))
  (asNat (get "context_length" j))
  (asNat (get "max_completion_tokens" j))
  (pricingFromJSON (get "pricing" j))
  (asString (get "quantization" j))
  (asStrings (get "supported_parameters" j))
  (asDouble (get "uptime_last_30m" j))
  j

||| A company that serves models through OpenRouter.
public export
record ProviderInfo where
  constructor MkProviderInfo
  name             : String
  slug             : String
  privacyPolicyUrl : Maybe String
  termsOfServiceUrl : Maybe String
  statusPageUrl    : Maybe String
  raw              : JSON

export
providerInfoFromJSON : JSON -> ProviderInfo
providerInfoFromJSON j = MkProviderInfo
  (fromMaybe "" (asString (get "name" j)))
  (fromMaybe "" (asString (get "slug" j)))
  (asString (get "privacy_policy_url" j))
  (asString (get "terms_of_service_url" j))
  (asString (get "status_page_url" j))
  j

--------------------------------------------------------------------------------
-- The account
--------------------------------------------------------------------------------

||| An API key: the one in use, or one a management key looks after. Amounts
||| are in credits (US dollars).
public export
record KeyInfo where
  constructor MkKeyInfo
  label          : String
  ||| The key's name, as given when it was made.
  name           : Maybe String
  ||| What the management endpoints know the key by.
  hash           : Maybe String
  disabled       : Bool
  ||| What the key has spent.
  usage          : Maybe Double
  ||| The key's spending limit; `Nothing` when it has none.
  limit          : Maybe Double
  limitRemaining : Maybe Double
  freeTier       : Bool
  raw            : JSON

export
keyInfoFromJSON : JSON -> KeyInfo
keyInfoFromJSON j = MkKeyInfo
  (fromMaybe "" (asString (get "label" j)))
  (asString (get "name" j))
  (asString (get "hash" j))
  (fromMaybe False (asBool (get "disabled" j)))
  (asAmount (get "usage" j))
  (asAmount (get "limit" j))
  (asAmount (get "limit_remaining" j))
  (fromMaybe False (asBool (get "is_free_tier" j)))
  j

||| Credits bought and credits spent, in US dollars.
public export
record Credits where
  constructor MkCredits
  purchased : Double
  used      : Double

export
creditsFromJSON : JSON -> Credits
creditsFromJSON j = MkCredits
  (fromMaybe 0 (asAmount (get "total_credits" j)))
  (fromMaybe 0 (asAmount (get "total_usage" j)))

||| What is left to spend.
export
remaining : Credits -> Double
remaining c = c.purchased - c.used

||| The record of one request, looked up by its generation id.
public export
record Generation where
  constructor MkGeneration
  id               : String
  model            : String
  provider         : Maybe String
  ||| What the request cost, in credits.
  cost             : Maybe Double
  promptTokens     : Maybe Nat
  completionTokens : Maybe Nat
  ||| Milliseconds until the first token.
  latency          : Maybe Double
  ||| Milliseconds spent generating.
  generationTime   : Maybe Double
  finishReason     : Maybe String
  streamed         : Bool
  cancelled        : Bool
  raw              : JSON

export
generationFromJSON : JSON -> Generation
generationFromJSON j = MkGeneration
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "model" j)))
  (asString (get "provider_name" j))
  (asAmount (get "total_cost" j))
  (asNat (get "tokens_prompt" j))
  (asNat (get "tokens_completion" j))
  (asDouble (get "latency" j))
  (asDouble (get "generation_time" j))
  (asString (get "finish_reason" j))
  (fromMaybe False (asBool (get "streamed" j)))
  (fromMaybe False (asBool (get "cancelled" j)))
  j

--------------------------------------------------------------------------------
-- Files and batches
--------------------------------------------------------------------------------

||| A file stored with OpenRouter, to refer to in later requests.
public export
record FileInfo where
  constructor MkFileInfo
  id        : String
  filename  : String
  mediaType : Maybe String
  ||| The file's size in bytes.
  size      : Maybe Nat
  ||| Whether its content can be downloaded: only files made on the server can.
  downloadable : Bool
  raw       : JSON

export
fileInfoFromJSON : JSON -> FileInfo
fileInfoFromJSON j = MkFileInfo
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "filename" j)))
  (asString (get "mime_type" j))
  (asNat (get "size_bytes" j) <|> asNat (get "bytes" j))
  (fromMaybe False (asBool (get "downloadable" j)))
  j

||| One request of a batch, under an id of your choosing that its result
||| will carry. `body` is the request as the batch's endpoint takes it:
||| `toJSON` of a `ChatRequest`, say.
public export
record BatchItem where
  constructor MkBatchItem
  customId : String
  body     : JSON

||| The outcome of one request of a batch.
public export
record BatchResult where
  constructor MkBatchResult
  customId : String
  ||| The response's body, as the endpoint would have returned it; `JNull`
  ||| when the request failed.
  body     : JSON
  ||| Why the request failed, when it did.
  error    : Maybe String

||| A batch of requests running in the background, at a discount.
public export
record Batch where
  constructor MkBatch
  id        : String
  ||| `"validating"`, `"in_progress"`, `"finalizing"`, `"completed"`,
  ||| `"failed"`, `"expired"`, `"cancelling"` or `"cancelled"`.
  status    : String
  endpoint  : String
  model     : String
  requests  : Nat
  completed : Nat
  failed    : Nat
  ||| The results, once the batch has completed.
  results   : List BatchResult
  raw       : JSON

export
batchFromJSON : JSON -> Batch
batchFromJSON j = MkBatch
  (fromMaybe "" (asString (get "id" j)))
  (fromMaybe "" (asString (get "status" j)))
  (fromMaybe "" (asString (get "endpoint" j)))
  (fromMaybe "" (asString (get "model" j)))
  (fromMaybe 0 (asNat (path ["request_counts", "total"] j)))
  (fromMaybe 0 (asNat (path ["request_counts", "completed"] j)))
  (fromMaybe 0 (asNat (path ["request_counts", "failed"] j)))
  (map result (asList (get "results" j)))
  j
  where
    result : JSON -> BatchResult
    result r = MkBatchResult
      (fromMaybe "" (asString (get "custom_id" r)))
      (path ["response", "body"] r)
      (asString (path ["error", "message"] r))

||| Whether a batch has stopped, for better or worse.
export
batchFinished : Batch -> Bool
batchFinished b = elem b.status ["completed", "failed", "expired", "cancelled"]
