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

||| The API key in use. Amounts are in credits (US dollars).
public export
record KeyInfo where
  constructor MkKeyInfo
  label          : String
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
