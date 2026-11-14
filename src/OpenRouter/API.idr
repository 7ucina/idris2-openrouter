||| Every endpoint of the OpenRouter API, one function each.
|||
||| This module is generated from OpenRouter's OpenAPI description by
||| `tools/generate_api.py`; do not edit it by hand. It covers 174 operations.
|||
||| These functions are thin: path parameters and required query parameters
||| are arguments, optional query parameters go in a `query` list, and bodies
||| and results are `JSON`. They add what every call here has (the key,
||| retries, timeouts, errors as `Either Error`). For the endpoints most
||| programs use (chat, streaming, tools, images, audio, and so on) the
||| modules re-exported by `OpenRouter` have typed functions instead.
|||
||| The module is not re-exported by `OpenRouter`, since its names are the
||| API's own and overlap with the typed ones. Import it under a name:
|||
||| ```idris
||| import OpenRouter
||| import OpenRouter.API as API
|||
||| guardrails <- API.listGuardrails client [("limit", "20")]
||| ```
module OpenRouter.API

import OpenRouter.Client
import OpenRouter.JSON
import OpenRouter.Response

%default total

--------------------------------------------------------------------------------
-- alpha.decisions
--------------------------------------------------------------------------------

||| Submit a Decisions request.
|||
||| Asks a Decisions model typed questions (`noul`, `choice`, `score`, `box`)
||| about the content in `state` and returns one typed answer per question
||| with its probabilities. Images, audio and video go in `state` as
||| `image_url`, `input_audio` and `video_url` parts; PNG and JPEG images can
||| instead go once in `assets` and be referenced by key. Which question
||| types, media parts and asset references an endpoint accepts depends on the
||| provider; a request an endpoint cannot serve fails with `400` before
||| anything is sent upstream. See the [Multimodal Decisions
||| guide](/docs/guides/community/multimodal-decisions) for the per-provider
||| table. Typed fields (text, numbers, dates, lists, estimates, forecasts)
||| come from [`POST
||| /api/alpha/extractions`](/docs/guides/community/extractions), which takes
||| the same envelope with `fields` in place of `questions` (text `state`
||| only; images and PDFs go in `assets`). Alpha: the shape may change.
|||
||| `POST /api/alpha/decisions`
export covering
createApiAlphaDecisions : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createApiAlphaDecisions c body = call c POST "/api/alpha/decisions" [] (Just body)

--------------------------------------------------------------------------------
-- alpha.extractions
--------------------------------------------------------------------------------

||| Submit an Extractions request.
|||
||| Extracts, computes, estimates or forecasts typed fields from a state
||| string and image assets using an extraction-style System One model. Alpha:
||| the shape is not stable.
|||
||| `POST /api/alpha/extractions`
export covering
createApiAlphaExtractions : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createApiAlphaExtractions c body = call c POST "/api/alpha/extractions" [] (Just body)

--------------------------------------------------------------------------------
-- Analytics
--------------------------------------------------------------------------------

||| Get user activity grouped by endpoint.
|||
||| Returns user activity data grouped by endpoint for the last 30 (completed)
||| UTC days. Pass `workspace_id` to scope the response to a single workspace.
||| Pass `group_by=workspace` to split each row per workspace and include
||| `workspace_id` on every item; by default rows are aggregated across
||| workspaces and `workspace_id` is not returned. Activity recorded before
||| workspace resolution existed is permanently attributed to the account
||| default workspace (no backfill is possible). A workspace-scoped management
||| key needs `activity:view_all` on its own workspace and reads only that
||| workspace: an omitted `workspace_id` defaults to it, a `workspace_id`
||| naming any other workspace returns 403, `api_key_hash` and `user_id`
||| resolve only keys and members of that workspace, and legacy activity with
||| no workspace is excluded (including for the default workspace).
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /activity`
|||
||| Query parameters: `date`, `api_key_hash`, `user_id`, `group_by`,
||| `workspace_id`.
export covering
getUserActivity : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
getUserActivity c query = call c GET "/activity" query Nothing

||| Get available analytics metrics and dimensions.
|||
||| Returns the available metrics, dimensions, filter operators, and
||| granularities for the analytics query endpoint. Workspace-scoped
||| management keys are accepted. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /analytics/meta`
export covering
getAnalyticsMeta : HasIO io => Client -> io (Either Error JSON)
getAnalyticsMeta c = call c GET "/analytics/meta" [] Nothing

||| Query analytics data.
|||
||| Execute an analytics query with specified metrics, dimensions, filters,
||| and time range. A workspace-scoped management key needs
||| `activity:view_all` on its own workspace and reads only that workspace: it
||| is refused a `workspace` filter naming another workspace, it excludes
||| legacy rows with no workspace (including for the default workspace), and
||| possible-cache metrics such as `possible_cached_tokens` return 400.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /analytics/query`
export covering
queryAnalytics : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
queryAnalytics c body = call c POST "/analytics/query" [] (Just body)

--------------------------------------------------------------------------------
-- Anthropic Messages
--------------------------------------------------------------------------------

||| Create a message.
|||
||| Creates a message using the Anthropic Messages API format. Supports text,
||| images, PDFs, tools, and extended thinking.
|||
||| `POST /messages`
|||
||| Headers, set through the client's `headers`: `X-OpenRouter-Metadata`.
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
createMessages : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createMessages c body = call c POST "/messages" [] (Just body)

--------------------------------------------------------------------------------
-- API Keys
--------------------------------------------------------------------------------

||| Get current API key.
|||
||| Get information on the API key associated with the current authentication
||| session.
|||
||| `GET /key`
export covering
getCurrentKey : HasIO io => Client -> io (Either Error JSON)
getCurrentKey c = call c GET "/key" [] Nothing

||| List API keys.
|||
||| List all API keys for the authenticated user. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /keys`
|||
||| Query parameters: `include_disabled`, `include_expired`, `offset`,
||| `workspace_id`.
export covering
listKeys : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listKeys c query = call c GET "/keys" query Nothing

||| Create a new API key.
|||
||| Create a new API key for the authenticated user. The plaintext `key` is
||| returned only in this response. Treat it as a write-only, sensitive value;
||| it cannot be retrieved later. Authenticate with a [management
||| key](/docs/guides/overview/auth/management-api-keys). The optional
||| `external` object associates the key with a partner-defined user and
||| lookup key.
|||
||| `POST /keys`
export covering
createKeys : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createKeys c body = call c POST "/keys" [] (Just body)

||| Delete an API key.
|||
||| Delete an existing API key. Authenticate with a [management
||| key](/docs/guides/overview/auth/management-api-keys).
|||
||| `DELETE /keys/{hash}`
export covering
deleteKeys : HasIO io => Client -> (hash : String) -> io (Either Error JSON)
deleteKeys c hash = call c DELETE ("/keys/" ++ urlEncode hash) [] Nothing

||| Get a single API key.
|||
||| Get a single API key by hash. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /keys/{hash}`
export covering
getKey : HasIO io => Client -> (hash : String) -> io (Either Error JSON)
getKey c hash = call c GET ("/keys/" ++ urlEncode hash) [] Nothing

||| Update an API key.
|||
||| Update an existing API key. Authenticate with a [management
||| key](/docs/guides/overview/auth/management-api-keys).
|||
||| `PATCH /keys/{hash}`
export covering
updateKeys : HasIO io => Client -> (hash : String) -> (body : JSON) -> io (Either Error JSON)
updateKeys c hash body = call c PATCH ("/keys/" ++ urlEncode hash) [] (Just body)

--------------------------------------------------------------------------------
-- Batch
--------------------------------------------------------------------------------

||| List batches.
|||
||| Lists batches in the workspace of the authenticating API key, newest
||| first. To fetch the next page, pass the previous page's `last_id` as
||| `after`. List items omit `results`. Use `GET /batches/{id}` to get them.
||| See the [Batch API
||| Quickstart](https://openrouter.ai/docs/batch-quickstart).
|||
||| `GET /batches`
|||
||| Query parameters: `limit`, `after`, `status`, `created_after`,
||| `created_before`.
export covering
listBatches : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listBatches c query = call c GET "/batches" query Nothing

||| Create a batch.
|||
||| Creates a batch of requests that run asynchronously against a single
||| endpoint (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`,
||| `/v1/embeddings`, `/v1/audio/speech`). Returns `202` with `status:
||| "validating"`. Poll `GET /batches/{id}` for progress and results. See the
||| [Batch API Quickstart](https://openrouter.ai/docs/batch-quickstart).
|||
||| `POST /batches`
export covering
createBatches : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createBatches c body = call c POST "/batches" [] (Just body)

||| Delete a batch.
|||
||| Deletes a batch in a terminal status (`completed`, `failed`, `expired`, or
||| `cancelled`) and its stored requests and results. Batches still in
||| progress return `409`. Billing and usage records are kept. See the [Batch
||| API Quickstart](https://openrouter.ai/docs/batch-quickstart).
|||
||| `DELETE /batches/{id}`
export covering
deleteBatch : HasIO io => Client -> (id : String) -> io (Either Error JSON)
deleteBatch c id = call c DELETE ("/batches/" ++ urlEncode id) [] Nothing

||| Get a batch.
|||
||| Returns a batch with its status and request counts. Batches in a terminal
||| status include `results`. Failed batches report the reason in
||| `error.message`. See the [Batch API
||| Quickstart](https://openrouter.ai/docs/batch-quickstart).
|||
||| `GET /batches/{id}`
export covering
getBatches : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getBatches c id = call c GET ("/batches/" ++ urlEncode id) [] Nothing

--------------------------------------------------------------------------------
-- Benchmarks
--------------------------------------------------------------------------------

||| List Benchmarks.
|||
||| Unified benchmark endpoint that aggregates scores from multiple benchmark
||| sources (Artificial Analysis, Design Arena, and OpenRouter's own
||| tau-bench, GPQA, and web-search evals). Filter by source to reproduce the
||| exact shapes from the legacy per-source endpoints, or use task_type to
||| find models suited for specific workloads. Use task_type=search (or a
||| search_* benchmark_type) for OpenRouter's search benchmarks, which publish
||| each model's highest-scoring eligible evaluation configuration with
||| same-configuration runs combined by task-weighted mean. Authenticate with
||| any valid OpenRouter API key. Rate-limited to 30 requests/minute per key
||| and 500 requests/day per account.
|||
||| `GET /benchmarks`
|||
||| Query parameters: `source`, `task_type`, `benchmark_type`,
||| `include_run_config`, `search_engine`, `search_surface`, `arena`,
||| `category`, `max_results`.
export covering
getBenchmarks : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
getBenchmarks c query = call c GET "/benchmarks" query Nothing

--------------------------------------------------------------------------------
-- BYOK
--------------------------------------------------------------------------------

||| List BYOK provider credentials.
|||
||| List the bring-your-own-key (BYOK) provider credentials for the
||| authenticated entity's default workspace, or a workspace-scoped management
||| key's own workspace. Use the `workspace_id` query parameter to scope the
||| result to a different workspace, or the `provider` query parameter to
||| filter by upstream provider. A workspace-scoped management key can only
||| list its own workspace; any other `workspace_id` returns 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /byok`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`, `provider`.
export covering
listBYOKKeys : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listBYOKKeys c query = call c GET "/byok" query Nothing

||| Create a BYOK provider credential.
|||
||| Create a new bring-your-own-key (BYOK) provider credential. The raw key is
||| encrypted at rest and never returned in API responses. When `workspace_id`
||| is omitted, the credential is created in the default workspace; if that
||| default has been deleted, the request returns a 400 and you must pass
||| `workspace_id` explicitly. A workspace-scoped management key creates the
||| credential in its own workspace when `workspace_id` is omitted, and any
||| other `workspace_id` returns 403. Treat the raw key as write-only; it is
||| never returned after creation. Use `allowed_api_key_hashes` to restrict
||| the credential to specific OpenRouter API keys. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /byok`
export covering
createBYOKKey : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createBYOKKey c body = call c POST "/byok" [] (Just body)

||| Delete a BYOK provider credential.
|||
||| Delete (soft-delete) a bring-your-own-key (BYOK) provider credential by
||| its `id`. The encrypted key material is wiped and the record is marked as
||| deleted. A workspace-scoped management key only reaches credentials in its
||| own workspace; any other `id` returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /byok/{id}`
export covering
deleteBYOKKey : HasIO io => Client -> (id : String) -> io (Either Error JSON)
deleteBYOKKey c id = call c DELETE ("/byok/" ++ urlEncode id) [] Nothing

||| Get a BYOK provider credential.
|||
||| Get a single bring-your-own-key (BYOK) provider credential by its `id`. A
||| workspace-scoped management key only reaches credentials in its own
||| workspace; any other `id` returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /byok/{id}`
export covering
getBYOKKey : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getBYOKKey c id = call c GET ("/byok/" ++ urlEncode id) [] Nothing

||| Update a BYOK provider credential.
|||
||| Update an existing bring-your-own-key (BYOK) provider credential by its
||| `id`. Include the `key` field to rotate the raw provider API key in-place
||| (the previous key material is overwritten). Use `allowed_api_key_hashes`
||| to restrict the credential to specific OpenRouter API keys (`null` clears
||| the restriction). A workspace-scoped management key only reaches
||| credentials in its own workspace; any other `id` returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /byok/{id}`
export covering
updateBYOKKey : HasIO io => Client -> (id : String) -> (body : JSON) -> io (Either Error JSON)
updateBYOKKey c id body = call c PATCH ("/byok/" ++ urlEncode id) [] (Just body)

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

||| Create a chat completion.
|||
||| Sends a request for a model response for the given chat conversation.
||| Supports both streaming and non-streaming modes.
|||
||| `POST /chat/completions`
|||
||| Headers, set through the client's `headers`: `X-OpenRouter-Metadata`.
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
sendChatCompletionRequest : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
sendChatCompletionRequest c body = call c POST "/chat/completions" [] (Just body)

--------------------------------------------------------------------------------
-- Classifications
--------------------------------------------------------------------------------

||| Task classification market share.
|||
||| Returns the market-share breakdown of OpenRouter traffic by task
||| classification (e.g. code generation, web search, summarization) over a
||| trailing time window.
|||
||| `GET /classifications/task`
|||
||| Query parameters: `window`.
export covering
getTaskClassifications : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
getTaskClassifications c query = call c GET "/classifications/task" query Nothing

--------------------------------------------------------------------------------
-- Containers
--------------------------------------------------------------------------------

||| List container files.
|||
||| Lists the files in a container, in lexicographic path order. The container
||| id is the canonical id returned in bash/shell tool results; a restarted
||| session is a separate container with its own id. Paginate with `limit` and
||| `after` (pass the previous page's `last_id`); `has_more: true` always
||| means the next page is fetchable that way. `last_id` is the resume cursor:
||| it is the last listed file's id, except when a page ends at the
||| per-request scan bound on hidden bookkeeping objects, where it names the
||| scan position instead and may not appear in `data` (which can then be
||| empty).
|||
||| `GET /containers/{container_id}/files`
|||
||| Query parameters: `limit`, `after`.
export covering
listContainerFiles : HasIO io => Client -> (containerId : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
listContainerFiles c containerId query = call c GET ("/containers/" ++ urlEncode containerId ++ "/files") query Nothing

||| Retrieve a container file.
|||
||| Returns the metadata of a single file in a container.
|||
||| `GET /containers/{container_id}/files/{file_id}`
export covering
getContainerFile : HasIO io => Client -> (containerId : String) -> (fileId : String)
  -> io (Either Error JSON)
getContainerFile c containerId fileId = call c GET ("/containers/" ++ urlEncode containerId ++ "/files/" ++ urlEncode fileId) [] Nothing

||| Download container file content.
|||
||| Streams the raw bytes of a file in a container.
|||
||| `GET /containers/{container_id}/files/{file_id}/content`
|||
||| The response's bytes are written to `file`; the result is how many there
||| were.
export covering
downloadContainerFileContent : HasIO io => Client -> (containerId : String) -> (fileId : String)
  -> (file : String) -> io (Either Error Nat)
downloadContainerFileContent c containerId fileId file = download c GET ("/containers/" ++ urlEncode containerId ++ "/files/" ++ urlEncode fileId ++ "/content") [] Nothing file

||| Promote a container file into workspace documents.
|||
||| Copies a file from the container's sandbox prefix into the workspace's
||| durable document storage, so it outlives the container. Returns the new
||| document in the Files API shape, with a durable file id in the documents
||| namespace. The copy counts against the workspace's storage quota. Unlike a
||| direct upload, promoted files are downloadable.
|||
||| `POST /containers/{container_id}/files/{file_id}/promote`
export covering
promoteContainerFile : HasIO io => Client -> (containerId : String) -> (fileId : String)
  -> io (Either Error JSON)
promoteContainerFile c containerId fileId = call c POST ("/containers/" ++ urlEncode containerId ++ "/files/" ++ urlEncode fileId ++ "/promote") [] Nothing

--------------------------------------------------------------------------------
-- Credits
--------------------------------------------------------------------------------

||| Get remaining credits.
|||
||| Get total credits purchased and used for the authenticated user.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /credits`
export covering
getCredits : HasIO io => Client -> io (Either Error JSON)
getCredits c = call c GET "/credits" [] Nothing

||| Deprecated Coinbase Commerce charge endpoint.
|||
||| Deprecated. The Coinbase APIs used by this endpoint have been deprecated,
||| so Coinbase Commerce charges have been removed. Use the web credits
||| purchase flow instead.
|||
||| `POST /credits/coinbase`
|||
||| Deprecated by OpenRouter.
export covering
createCoinbaseCharge : HasIO io => Client -> io (Either Error JSON)
createCoinbaseCharge c = call c POST "/credits/coinbase" [] Nothing

||| Agent setup guide, served at the purchases collection.
|||
||| `GET /credits/purchases`
export covering
getCreditPurchasesSetupGuide : HasIO io => Client -> io (Either Error String)
getCreditPurchasesSetupGuide c = callText c GET "/credits/purchases" []

||| Buy credits with a machine payment.
|||
||| Starts an agent credit purchase paid with a Machine Payments Protocol
||| (MPP) credential: USDC on Tempo, or a card when one is offered. The first
||| call answers `402` with one `WWW-Authenticate: Payment ...` challenge per
||| payment option; pay one of them and retry the same request, same
||| `Idempotency-Key`, with the signed credential in `Payment-Authorization:
||| Payment ...` (or in `Authorization: Payment ...` when the management key
||| is sent as `X-Api-Key`). A paid request answers `202`: the transfer was
||| broadcast or the card was charged, and the payment is still being
||| confirmed, so credits arrive asynchronously. Poll the URL in the
||| `Location` header, `GET /api/v1/credits/purchases/{id}`, until `status` is
||| `credited` or `failed`.
|||
||| `POST /credits/purchases`
|||
||| Headers, set through the client's `headers`: `idempotency-key`.
export covering
createCreditsPurchases : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createCreditsPurchases c body = call c POST "/credits/purchases" [] (Just body)

||| Agent skill for buying OpenRouter credits.
|||
||| `GET /credits/purchases/SKILL.md`
export covering
getCreditsPurchasesSkill : HasIO io => Client -> io (Either Error String)
getCreditsPurchasesSkill c = callText c GET "/credits/purchases/SKILL.md" []

||| Agent setup guide for buying credits with a machine payment.
|||
||| `GET /credits/purchases/setup`
export covering
listCreditsPurchasesSetup : HasIO io => Client -> io (Either Error String)
listCreditsPurchasesSetup c = callText c GET "/credits/purchases/setup" []

||| Get a credit purchase.
|||
||| Returns one agent credit purchase of the calling account, read from its
||| Stripe PaymentIntent. Poll this after a `202` until `status` is `credited`
||| or `failed`.
|||
||| `GET /credits/purchases/{id}`
export covering
listCreditsPurchases : HasIO io => Client -> (id : String) -> io (Either Error JSON)
listCreditsPurchases c id = call c GET ("/credits/purchases/" ++ urlEncode id) [] Nothing

--------------------------------------------------------------------------------
-- Datasets
--------------------------------------------------------------------------------

||| Top apps by token usage.
|||
||| Returns the top public apps on OpenRouter ranked by token usage inside the
||| requested date window, matching the public apps marketplace on
||| openrouter.ai/apps. Token totals are `prompt_tokens + completion_tokens`;
||| hidden and private apps are excluded and traffic from related app aliases
||| is merged into the canonical visible app.
|||
||| `GET /datasets/app-rankings`
|||
||| Query parameters: `category`, `subcategory`, `sort`, `start_date`,
||| `end_date`, `limit`, `offset`.
export covering
getAppRankings : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
getAppRankings c query = call c GET "/datasets/app-rankings" query Nothing

||| Daily token totals for top 50 models.
|||
||| Returns the top 50 public models per day by total token usage on
||| OpenRouter, plus a single aggregated `other` row per day that sums every
||| model outside that top 50. Token totals are `prompt_tokens +
||| completion_tokens`, matching the public rankings chart on
||| openrouter.ai/rankings.
|||
||| `GET /datasets/rankings-daily`
|||
||| Query parameters: `start_date`, `end_date`, `period`, `modality`,
||| `context_bucket`, `category`, `language_type`.
export covering
getRankingsDaily : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
getRankingsDaily c query = call c GET "/datasets/rankings-daily" query Nothing

||| Cost per session by harness and model.
|||
||| Returns weekly refreshed, aggregated cost-per-session cells for the
||| published harnesses. Sessions are never pooled across apps. Medians are of
||| per-session USD spend, and privacy-preserving aggregation never exposes
||| clerk_user_id values or per-session rows.
|||
||| `GET /datasets/session-cost`
|||
||| Query parameters: `app_slug`, `model`, `turn_range`, `limit`, `offset`.
export covering
getSessionCost : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
getSessionCost c query = call c GET "/datasets/session-cost" query Nothing

--------------------------------------------------------------------------------
-- Embeddings
--------------------------------------------------------------------------------

||| Submit an embedding request.
|||
||| Submits an embedding request to the embeddings router.
|||
||| `POST /embeddings`
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
createEmbeddings : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createEmbeddings c body = call c POST "/embeddings" [] (Just body)

||| List all embeddings models.
|||
||| Returns a list of all available embeddings models and their properties.
|||
||| `GET /embeddings/models`
|||
||| Query parameters: `offset`, `limit`.
export covering
listEmbeddingsModels : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listEmbeddingsModels c query = call c GET "/embeddings/models" query Nothing

--------------------------------------------------------------------------------
-- Endpoints
--------------------------------------------------------------------------------

||| Preview the impact of ZDR on the available endpoints.
|||
||| `GET /endpoints/zdr`
export covering
listEndpointsZdr : HasIO io => Client -> io (Either Error JSON)
listEndpointsZdr c = call c GET "/endpoints/zdr" [] Nothing

||| List all endpoints for a model.
|||
||| `GET /models/{author}/{slug}/endpoints`
export covering
listEndpoints : HasIO io => Client -> (author : String) -> (slug : String)
  -> io (Either Error JSON)
listEndpoints c author slug = call c GET ("/models/" ++ urlEncode author ++ "/" ++ urlEncode slug ++ "/endpoints") [] Nothing

--------------------------------------------------------------------------------
-- External Users
--------------------------------------------------------------------------------

||| List registered external users.
|||
||| List registrations belonging to the authenticated organization. Inactive
||| registrations are excluded by default. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /external-users`
|||
||| Query parameters: `offset`, `limit`, `user`, `include_inactive`.
export covering
listExternalUsers : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listExternalUsers c query = call c GET "/external-users" query Nothing

||| Register an external user.
|||
||| Register a caller-supplied tracking ID under the authenticated
||| organization. No login account, policy, or credentials are created.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /external-users`
export covering
createExternalUser : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createExternalUser c body = call c POST "/external-users" [] (Just body)

||| Deactivate a registered external user.
|||
||| Soft-deactivate a registration while retaining its tracking ID. Repeat
||| deactivation succeeds. This does not block inference; reactivate through
||| PATCH. [Management key](/docs/guides/overview/auth/management-api-keys)
||| required.
|||
||| `DELETE /external-users/{user}`
export covering
deleteExternalUser : HasIO io => Client -> (user : String) -> io (Either Error JSON)
deleteExternalUser c user = call c DELETE ("/external-users/" ++ urlEncode user) [] Nothing

||| Get a registered external user.
|||
||| Retrieve an active or inactive registration by its URL-encoded,
||| caller-supplied tracking ID. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /external-users/{user}`
export covering
getExternalUser : HasIO io => Client -> (user : String) -> io (Either Error JSON)
getExternalUser c user = call c GET ("/external-users/" ++ urlEncode user) [] Nothing

||| Update a registered external user.
|||
||| Update registration state without changing identity. State changes do not
||| enforce inference access. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /external-users/{user}`
export covering
updateExternalUser : HasIO io => Client -> (user : String) -> (body : JSON)
  -> io (Either Error JSON)
updateExternalUser c user body = call c PATCH ("/external-users/" ++ urlEncode user) [] (Just body)

--------------------------------------------------------------------------------
-- Files
--------------------------------------------------------------------------------

||| List files.
|||
||| Lists files belonging to the workspace of the authenticating API key.
|||
||| `GET /files`
|||
||| Query parameters: `limit`, `cursor`, `workspace_id`, `provider`, `after`,
||| `after_id`, `before_id`, `order`.
export covering
listFiles : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listFiles c query = call c GET "/files" query Nothing

||| Upload a file.
|||
||| Uploads a file to be referenced in future API calls. The file is stored
||| under the workspace of the authenticating API key. Maximum file size: 100
||| MB; empty files are rejected. The file type is determined from the file
||| contents: not the filename or the declared content type: and must be a
||| PDF, a PNG/JPEG/GIF/WebP image, a DOCX/XLSX/PPTX document, an
||| MP3/WAV/FLAC/OGG audio file, or UTF-8 text. Text is reported by its
||| structure as `application/json`, `application/x-ndjson`, `text/csv`,
||| `text/markdown`, or `text/plain`.
|||
||| `POST /files`
|||
||| Query parameters: `workspace_id`, `provider`.
export covering
uploadFile : HasIO io => Client -> (query : List (String, String)) -> (parts : List FormPart)
  -> io (Either Error JSON)
uploadFile c query parts = upload c "/files" query parts

||| Delete a file.
|||
||| Deletes a file owned by the requesting workspace. Deletion is
||| irreversible.
|||
||| `DELETE /files/{file_id}`
|||
||| Query parameters: `workspace_id`, `provider`.
export covering
deleteFile : HasIO io => Client -> (fileId : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deleteFile c fileId query = call c DELETE ("/files/" ++ urlEncode fileId) query Nothing

||| Get file metadata.
|||
||| Retrieves metadata for a single file owned by the requesting workspace.
|||
||| `GET /files/{file_id}`
|||
||| Query parameters: `workspace_id`, `provider`.
export covering
getFileMetadata : HasIO io => Client -> (fileId : String) -> (query : List (String, String))
  -> io (Either Error JSON)
getFileMetadata c fileId query = call c GET ("/files/" ++ urlEncode fileId) query Nothing

||| Download file content.
|||
||| Downloads the raw bytes of a file. Only files created server-side are
||| downloadable; uploaded files return 400.
|||
||| `GET /files/{file_id}/content`
|||
||| Query parameters: `workspace_id`, `provider`.
|||
||| The response's bytes are written to `file`; the result is how many there
||| were.
export covering
downloadFileContent : HasIO io => Client -> (fileId : String) -> (query : List (String, String))
  -> (file : String) -> io (Either Error Nat)
downloadFileContent c fileId query file = download c GET ("/files/" ++ urlEncode fileId ++ "/content") query Nothing file

--------------------------------------------------------------------------------
-- Generations
--------------------------------------------------------------------------------

||| Get request & usage metadata for a generation.
|||
||| `GET /generation`
export covering
getGeneration : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getGeneration c id = call c GET "/generation" [("id", id)] Nothing

||| Get stored prompt, completion, and error content for a generation.
|||
||| `GET /generation/content`
export covering
listGenerationContent : HasIO io => Client -> (id : String) -> io (Either Error JSON)
listGenerationContent c id = call c GET "/generation/content" [("id", id)] Nothing

||| Submit feedback for a generation.
|||
||| Submit structured feedback on a generation the authenticated user made.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /generation/feedback`
export covering
submitGenerationFeedback : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
submitGenerationFeedback c body = call c POST "/generation/feedback" [] (Just body)

--------------------------------------------------------------------------------
-- Guardrail Policies
--------------------------------------------------------------------------------

||| List workspace-wide policies.
|||
||| List the workspace-wide policies that apply across workspaces in the
||| account. [Management key](/docs/guides/overview/auth/management-api-keys)
||| required.
|||
||| `GET /guardrails/policies/account`
|||
||| Query parameters: `offset`, `limit`.
export covering
listAccountPolicies : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listAccountPolicies c query = call c GET "/guardrails/policies/account" query Nothing

||| Create a workspace-wide policy.
|||
||| Create a workspace-wide budget, moderation, or model availability policy.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/policies/account`
export covering
createAccountPolicy : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createAccountPolicy c body = call c POST "/guardrails/policies/account" [] (Just body)

||| Delete a workspace-wide policy.
|||
||| Delete a workspace-wide policy. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /guardrails/policies/account/{id}`
export covering
deleteAccountPolicy : HasIO io => Client -> (id : String) -> io (Either Error JSON)
deleteAccountPolicy c id = call c DELETE ("/guardrails/policies/account/" ++ urlEncode id) [] Nothing

||| Update a workspace-wide policy.
|||
||| Replace a workspace-wide policy and its workspace coverage. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/account/{id}`
export covering
updateAccountPolicy : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateAccountPolicy c id body = call c PUT ("/guardrails/policies/account/" ++ urlEncode id) [] (Just body)

||| Get an API key policy assignment.
|||
||| Get the policies of one type that apply to an API key in a workspace.
||| Requires a management key with write access. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/assignments/api-keys/{hash}`
|||
||| Query parameters: `workspace_id`.
export covering
getApiKeyPolicyAssignment : HasIO io => Client -> (hash : String) -> (policyType : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
getApiKeyPolicyAssignment c hash policyType query = call c GET ("/guardrails/policies/assignments/api-keys/" ++ urlEncode hash) ([("policy_type", policyType)] ++ query) Nothing

||| Change an API key policy assignment.
|||
||| Assign or unassign one policy for an API key. Fails with 409 when
||| `expected_assignment` no longer matches the stored state. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/assignments/api-keys/{hash}`
export covering
changeApiKeyPolicyAssignment : HasIO io => Client -> (hash : String) -> (body : JSON)
  -> io (Either Error JSON)
changeApiKeyPolicyAssignment c hash body = call c PUT ("/guardrails/policies/assignments/api-keys/" ++ urlEncode hash) [] (Just body)

||| Get a member policy assignment.
|||
||| Get the policies of one type that apply to a member in a workspace.
||| Requires a management key with write access. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/assignments/members/{member_id}`
|||
||| Query parameters: `workspace_id`.
export covering
getMemberPolicyAssignment : HasIO io => Client -> (memberId : String) -> (policyType : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
getMemberPolicyAssignment c memberId policyType query = call c GET ("/guardrails/policies/assignments/members/" ++ urlEncode memberId) ([("policy_type", policyType)] ++ query) Nothing

||| Change a member policy assignment.
|||
||| Assign or unassign one policy for a member. Fails with 409 when
||| `expected_assignment` no longer matches the stored state. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/assignments/members/{member_id}`
export covering
changeMemberPolicyAssignment : HasIO io => Client -> (memberId : String) -> (body : JSON)
  -> io (Either Error JSON)
changeMemberPolicyAssignment c memberId body = call c PUT ("/guardrails/policies/assignments/members/" ++ urlEncode memberId) [] (Just body)

||| List budget policies.
|||
||| List the budget policies in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/budget`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listBudgetPolicies : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listBudgetPolicies c query = call c GET "/guardrails/policies/budget" query Nothing

||| Create a budget policy.
|||
||| Create a budget policy in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/policies/budget`
export covering
createBudgetPolicy : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createBudgetPolicy c body = call c POST "/guardrails/policies/budget" [] (Just body)

||| Delete a budget policy.
|||
||| Delete a budget policy. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /guardrails/policies/budget/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
deleteBudgetPolicy : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deleteBudgetPolicy c id query = call c DELETE ("/guardrails/policies/budget/" ++ urlEncode id) query Nothing

||| Get a budget policy.
|||
||| Get a budget policy with its member and API key assignments. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/budget/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
getBudgetPolicy : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
getBudgetPolicy c id query = call c GET ("/guardrails/policies/budget/" ++ urlEncode id) query Nothing

||| Update a budget policy.
|||
||| Replace a budget policy's name and config, and optionally its assignments.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/budget/{id}`
export covering
updateBudgetPolicy : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateBudgetPolicy c id body = call c PUT ("/guardrails/policies/budget/" ++ urlEncode id) [] (Just body)

||| List model availability policies.
|||
||| List the model availability policies in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/model-availability`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listModelAvailabilityPolicies : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listModelAvailabilityPolicies c query = call c GET "/guardrails/policies/model-availability" query Nothing

||| Create a model availability policy.
|||
||| Create a model availability policy in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/policies/model-availability`
export covering
createModelAvailabilityPolicy : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createModelAvailabilityPolicy c body = call c POST "/guardrails/policies/model-availability" [] (Just body)

||| Delete a model availability policy.
|||
||| Delete a model availability policy. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /guardrails/policies/model-availability/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
deleteModelAvailabilityPolicy : HasIO io => Client -> (id : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
deleteModelAvailabilityPolicy c id query = call c DELETE ("/guardrails/policies/model-availability/" ++ urlEncode id) query Nothing

||| Get a model availability policy.
|||
||| Get a model availability policy with its member and API key assignments.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/model-availability/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
getModelAvailabilityPolicy : HasIO io => Client -> (id : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
getModelAvailabilityPolicy c id query = call c GET ("/guardrails/policies/model-availability/" ++ urlEncode id) query Nothing

||| Update a model availability policy.
|||
||| Replace a model availability policy's name and config, and optionally its
||| assignments. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/model-availability/{id}`
export covering
updateModelAvailabilityPolicy : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateModelAvailabilityPolicy c id body = call c PUT ("/guardrails/policies/model-availability/" ++ urlEncode id) [] (Just body)

||| List moderation policies.
|||
||| List the moderation policies in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/moderation`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listModerationPolicies : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listModerationPolicies c query = call c GET "/guardrails/policies/moderation" query Nothing

||| Create a moderation policy.
|||
||| Create a moderation policy in a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/policies/moderation`
export covering
createModerationPolicy : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createModerationPolicy c body = call c POST "/guardrails/policies/moderation" [] (Just body)

||| Delete a moderation policy.
|||
||| Delete a moderation policy. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /guardrails/policies/moderation/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
deleteModerationPolicy : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deleteModerationPolicy c id query = call c DELETE ("/guardrails/policies/moderation/" ++ urlEncode id) query Nothing

||| Get a moderation policy.
|||
||| Get a moderation policy with its member and API key assignments.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/policies/moderation/{id}`
|||
||| Query parameters: `workspace_id`.
export covering
getModerationPolicy : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
getModerationPolicy c id query = call c GET ("/guardrails/policies/moderation/" ++ urlEncode id) query Nothing

||| Update a moderation policy.
|||
||| Replace a moderation policy's name and config, and optionally its
||| assignments. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /guardrails/policies/moderation/{id}`
export covering
updateModerationPolicy : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateModerationPolicy c id body = call c PUT ("/guardrails/policies/moderation/" ++ urlEncode id) [] (Just body)

--------------------------------------------------------------------------------
-- Guardrails
--------------------------------------------------------------------------------

||| List guardrails.
|||
||| List all guardrails for the authenticated user. A workspace-scoped
||| management key lists only its own workspace, which `workspace_id` defaults
||| to; naming another workspace returns 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listGuardrails : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listGuardrails c query = call c GET "/guardrails" query Nothing

||| Create a guardrail.
|||
||| Create a new guardrail for the authenticated user. A newly created
||| guardrail enforces nothing until it is assigned to API keys or
||| organization members; `workspace_id` places the guardrail in a workspace
||| but does not apply it to that workspace's traffic. To restrict all traffic
||| in a workspace, update the workspace's default guardrail instead. Set
||| `allowed_data_regions` to enforce [In-Region
||| Routing](/docs/guides/features/in-region-routing#enforcing-in-region-routing-with-guardrails):
||| governed requests must arrive through one of the listed OpenRouter domains
||| and are rejected with a 403 otherwise. A workspace-scoped management key
||| creates in its own workspace, which `workspace_id` defaults to; naming
||| another workspace returns 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails`
export covering
createGuardrail : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createGuardrail c body = call c POST "/guardrails" [] (Just body)

||| List all key assignments.
|||
||| List all API key guardrail assignments for the authenticated user. A
||| workspace-scoped management key lists only its own workspace, which
||| `workspace_id` defaults to; naming another workspace returns 403.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/assignments/keys`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listKeyAssignments : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listKeyAssignments c query = call c GET "/guardrails/assignments/keys" query Nothing

||| List all member assignments.
|||
||| List all organization member guardrail assignments for the authenticated
||| user. A workspace-scoped management key lists only its own workspace,
||| which `workspace_id` defaults to; naming another workspace returns 403.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/assignments/members`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listMemberAssignments : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listMemberAssignments c query = call c GET "/guardrails/assignments/members" query Nothing

||| Delete a guardrail.
|||
||| Delete an existing guardrail. A workspace-scoped management key reaches
||| only guardrails in its own workspace; any other guardrail returns 404.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /guardrails/{id}`
export covering
deleteGuardrail : HasIO io => Client -> (id : String) -> io (Either Error JSON)
deleteGuardrail c id = call c DELETE ("/guardrails/" ++ urlEncode id) [] Nothing

||| Get a guardrail.
|||
||| Get a single guardrail by ID. A workspace-scoped management key reaches
||| only guardrails in its own workspace; any other guardrail returns 404.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/{id}`
export covering
getGuardrail : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getGuardrail c id = call c GET ("/guardrails/" ++ urlEncode id) [] Nothing

||| Update a guardrail.
|||
||| Update an existing guardrail, or materialize an unconfigured workspace
||| default guardrail. Collection fields use replace semantics: send the full
||| desired set on every update. A workspace-scoped management key reaches
||| only guardrails in its own workspace; any other guardrail returns 404.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /guardrails/{id}`
export covering
updateGuardrail : HasIO io => Client -> (id : String) -> (body : JSON) -> io (Either Error JSON)
updateGuardrail c id body = call c PATCH ("/guardrails/" ++ urlEncode id) [] (Just body)

||| List key assignments for a guardrail.
|||
||| List all API key assignments for a specific guardrail. A workspace-scoped
||| management key reaches only guardrails in its own workspace; any other
||| guardrail returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/{id}/assignments/keys`
|||
||| Query parameters: `offset`, `limit`.
export covering
listGuardrailKeyAssignments : HasIO io => Client -> (id : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
listGuardrailKeyAssignments c id query = call c GET ("/guardrails/" ++ urlEncode id ++ "/assignments/keys") query Nothing

||| Bulk assign keys to a guardrail.
|||
||| Assign multiple API keys to a specific guardrail. A key may hold at most
||| one guardrail; assigning replaces any existing assignment. A
||| workspace-scoped management key reaches only guardrails in its own
||| workspace (any other returns 404), and a batch naming an unknown or
||| out-of-workspace key hash is rejected with 400 before anything changes.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/{id}/assignments/keys`
export covering
bulkAssignKeysToGuardrail : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkAssignKeysToGuardrail c id body = call c POST ("/guardrails/" ++ urlEncode id ++ "/assignments/keys") [] (Just body)

||| Bulk unassign keys from a guardrail.
|||
||| Unassign multiple API keys from a specific guardrail. A workspace-scoped
||| management key reaches only guardrails in its own workspace (any other
||| returns 404), and a batch naming an unknown or out-of-workspace key hash
||| is rejected with 400 before anything changes. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/{id}/assignments/keys/remove`
export covering
bulkUnassignKeysFromGuardrail : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkUnassignKeysFromGuardrail c id body = call c POST ("/guardrails/" ++ urlEncode id ++ "/assignments/keys/remove") [] (Just body)

||| List member assignments for a guardrail.
|||
||| List all organization member assignments for a specific guardrail. A
||| workspace-scoped management key reaches only guardrails in its own
||| workspace; any other guardrail returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /guardrails/{id}/assignments/members`
|||
||| Query parameters: `offset`, `limit`.
export covering
listGuardrailMemberAssignments : HasIO io => Client -> (id : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
listGuardrailMemberAssignments c id query = call c GET ("/guardrails/" ++ urlEncode id ++ "/assignments/members") query Nothing

||| Bulk assign members to a guardrail.
|||
||| Assign multiple organization members to a specific guardrail. Requires an
||| organization-scoped management key; workspace-scoped management keys
||| return 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/{id}/assignments/members`
export covering
bulkAssignMembersToGuardrail : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkAssignMembersToGuardrail c id body = call c POST ("/guardrails/" ++ urlEncode id ++ "/assignments/members") [] (Just body)

||| Bulk unassign members from a guardrail.
|||
||| Unassign multiple organization members from a specific guardrail. Requires
||| an organization-scoped management key; workspace-scoped management keys
||| return 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /guardrails/{id}/assignments/members/remove`
export covering
bulkUnassignMembersFromGuardrail : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkUnassignMembersFromGuardrail c id body = call c POST ("/guardrails/" ++ urlEncode id ++ "/assignments/members/remove") [] (Just body)

--------------------------------------------------------------------------------
-- Images
--------------------------------------------------------------------------------

||| Generate an image.
|||
||| Generates an image from a text prompt via the image generation router.
|||
||| `POST /images`
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
createImages : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createImages c body = call c POST "/images" [] (Just body)

||| List image generation models.
|||
||| Lists every image generation model with its top-level supported-parameter
||| superset and a URL to its full per-endpoint records.
|||
||| `GET /images/models`
export covering
listImageModels : HasIO io => Client -> io (Either Error JSON)
listImageModels c = call c GET "/images/models" [] Nothing

||| List endpoints for an image model.
|||
||| Returns the full per-endpoint records for an image model: each endpoint's
||| definitive supported parameters, pricing, and passthrough allowlist.
|||
||| `GET /images/models/{author}/{slug}/endpoints`
export covering
listImageModelEndpoints : HasIO io => Client -> (author : String) -> (slug : String)
  -> io (Either Error JSON)
listImageModelEndpoints c author slug = call c GET ("/images/models/" ++ urlEncode author ++ "/" ++ urlEncode slug ++ "/endpoints") [] Nothing

--------------------------------------------------------------------------------
-- Models
--------------------------------------------------------------------------------

||| Get a model by its slug.
|||
||| Returns full details for a single model identified by its author and slug
||| (e.g. openai/gpt-4). Supports variant suffixes (e.g. openai/gpt-4:free)
||| and resolves known slug aliases.
|||
||| `GET /model/{author}/{slug}`
export covering
getModel : HasIO io => Client -> (author : String) -> (slug : String) -> io (Either Error JSON)
getModel c author slug = call c GET ("/model/" ++ urlEncode author ++ "/" ++ urlEncode slug) [] Nothing

||| List all models and their properties.
|||
||| `GET /models`
|||
||| Query parameters: `offset`, `limit`, `category`, `supported_parameters`,
||| `output_modalities`, `sort`, `q`, `input_modalities`, `endpoints`,
||| `context`, `min_price`, `max_price`, `arch`, `model_authors`, `providers`,
||| `distillable`, `zdr`, `region`, `min_output_price`, `max_output_price`,
||| `min_age_days`, `max_age_days`, `min_intelligence_index`,
||| `max_intelligence_index`, `min_coding_index`, `max_coding_index`,
||| `min_agentic_index`, `max_agentic_index`, `min_tool_success_rate`,
||| `max_tool_success_rate`.
export covering
getModels : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
getModels c query = call c GET "/models" query Nothing

||| Get total count of available models.
|||
||| `GET /models/count`
|||
||| Query parameters: `output_modalities`.
export covering
listModelsCount : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listModelsCount c query = call c GET "/models/count" query Nothing

||| List models filtered by user provider preferences, privacy settings, and
||| guardrails.
|||
||| List models filtered by user provider preferences, [privacy
||| settings](https://openrouter.ai/docs/guides/privacy/provider-logging), and
||| [guardrails](https://openrouter.ai/docs/guides/features/guardrails).
||| Returns text-output models by default; pass `output_modalities` (a
||| comma-separated list of `text`, `image`, `embeddings`, `audio`, `video`,
||| `rerank`, `speech`, `transcription`, or `all`) to include other
||| modalities. If requesting through a regional hostname, the results will be
||| filtered to models that satisfy in-region routing for that region.
|||
||| `GET /models/user`
|||
||| Query parameters: `offset`, `limit`, `output_modalities`, `sort`,
||| `client`.
export covering
listModelsUser : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listModelsUser c query = call c GET "/models/user" query Nothing

--------------------------------------------------------------------------------
-- OAuth
--------------------------------------------------------------------------------

||| Exchange authorization code for API key.
|||
||| Exchange an authorization code from the PKCE flow for a user-controlled
||| API key.
|||
||| `POST /auth/keys`
export covering
exchangeAuthCodeForAPIKey : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
exchangeAuthCodeForAPIKey c body = call c POST "/auth/keys" [] (Just body)

||| Create authorization code.
|||
||| Create an authorization code for the PKCE flow to generate a
||| user-controlled API key.
|||
||| `POST /auth/keys/code`
export covering
createAuthKeysCode : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createAuthKeysCode c body = call c POST "/auth/keys/code" [] (Just body)

||| OpenRouter access token signing keys.
|||
||| RFC 7517 JWK Set containing the public keys OpenRouter signs access tokens
||| with.
|||
||| `GET /oauth/jwks`
export covering
listOauthJwks : HasIO io => Client -> io (Either Error JSON)
listOauthJwks c = call c GET "/oauth/jwks" [] Nothing

||| Exchange a workload identity token.
|||
||| RFC 8693 token exchange. Presents a JWT from an issuer your organization
||| trusts (Settings → Workload identity) and receives a short-lived
||| OpenRouter access token that acts as the API key the matching federation
||| policy targets.
|||
||| `POST /oauth/token`
export covering
createOauthToken : HasIO io => Client -> (fields : List (String, String))
  -> io (Either Error JSON)
createOauthToken c fields = callForm c "/oauth/token" fields

--------------------------------------------------------------------------------
-- Observability
--------------------------------------------------------------------------------

||| List observability destinations.
|||
||| List the observability destinations configured for the authenticated
||| entity's default workspace, or a workspace-scoped management key's own
||| workspace. Use the `workspace_id` query parameter to scope the result to a
||| different workspace. A workspace-scoped management key can only list its
||| own workspace; any other `workspace_id` returns 403. Only destinations
||| with stable release status are surfaced: destinations of other types are
||| excluded. [Management key](/docs/guides/overview/auth/management-api-keys)
||| required.
|||
||| `GET /observability/destinations`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listObservabilityDestinations : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listObservabilityDestinations c query = call c GET "/observability/destinations" query Nothing

||| Create an observability destination.
|||
||| Create a new observability destination. A maximum of 5 destinations per
||| type is allowed. Defaults to the authenticated entity's default workspace,
||| or a workspace-scoped management key's own workspace; use the
||| `workspace_id` body field to scope to a different workspace. A
||| workspace-scoped management key can only create in its own workspace; any
||| other `workspace_id` returns 403. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /observability/destinations`
export covering
createObservabilityDestination : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createObservabilityDestination c body = call c POST "/observability/destinations" [] (Just body)

||| Delete an observability destination.
|||
||| Delete an existing observability destination. This performs a soft delete.
||| A workspace-scoped management key only reaches destinations in its own
||| workspace; any other `id` returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /observability/destinations/{id}`
export covering
deleteObservabilityDestination : HasIO io => Client -> (id : String) -> io (Either Error JSON)
deleteObservabilityDestination c id = call c DELETE ("/observability/destinations/" ++ urlEncode id) [] Nothing

||| Get an observability destination.
|||
||| Fetch a single observability destination by its UUID. A workspace-scoped
||| management key only reaches destinations in its own workspace; any other
||| `id` returns 404. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /observability/destinations/{id}`
export covering
getObservabilityDestination : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getObservabilityDestination c id = call c GET ("/observability/destinations/" ++ urlEncode id) [] Nothing

||| Update an observability destination.
|||
||| Update an existing observability destination. Only the fields provided in
||| the request body are updated. A workspace-scoped management key only
||| reaches destinations in its own workspace; any other `id` returns 404.
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /observability/destinations/{id}`
export covering
updateObservabilityDestination : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateObservabilityDestination c id body = call c PATCH ("/observability/destinations/" ++ urlEncode id) [] (Just body)

--------------------------------------------------------------------------------
-- Organization
--------------------------------------------------------------------------------

||| List organization members.
|||
||| List all members of the organization associated with the authenticated
||| management key. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /organization/members`
|||
||| Query parameters: `offset`, `limit`.
export covering
listOrganizationMembers : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listOrganizationMembers c query = call c GET "/organization/members" query Nothing

||| Get organization settings.
|||
||| Get the settings of the organization associated with the authenticated
||| management key. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /organization/settings`
export covering
getOrganizationSettings : HasIO io => Client -> io (Either Error JSON)
getOrganizationSettings c = call c GET "/organization/settings" [] Nothing

||| Update organization settings.
|||
||| Update the settings of the organization associated with the authenticated
||| management key. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /organization/settings`
export covering
updateOrganizationSettings : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
updateOrganizationSettings c body = call c PATCH "/organization/settings" [] (Just body)

--------------------------------------------------------------------------------
-- Presets
--------------------------------------------------------------------------------

||| List presets.
|||
||| Lists all presets for the authenticated user, ordered by most recently
||| updated first.
|||
||| `GET /presets`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listPresets : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listPresets c query = call c GET "/presets" query Nothing

||| Delete a preset.
|||
||| Archives a preset: it no longer resolves for inference and is hidden from
||| get and list. The preset and its versions are kept, so the slug stays
||| taken; restore it with `POST /presets/{slug}/restore`. Deleting an
||| already-archived preset succeeds again. A disabled preset returns 409.
||| Requires a read-write [management
||| key](/docs/guides/overview/auth/management-api-keys); inference API keys
||| are rejected. `workspace_id` may be sent as a query parameter or a JSON
||| body field.
|||
||| `DELETE /presets/{slug}`
|||
||| Query parameters: `workspace_id`.
export covering
deletePreset : HasIO io => Client -> (slug : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deletePreset c slug query = call c DELETE ("/presets/" ++ urlEncode slug) query Nothing

||| Get a preset.
|||
||| Retrieves a preset by its slug with its currently designated version
||| inline.
|||
||| `GET /presets/{slug}`
|||
||| Query parameters: `workspace_id`.
export covering
getPreset : HasIO io => Client -> (slug : String) -> (query : List (String, String))
  -> io (Either Error JSON)
getPreset c slug query = call c GET ("/presets/" ++ urlEncode slug) query Nothing

||| Create a preset from a chat-completions request body.
|||
||| Creates a preset (or a new version of an existing one) from an inference
||| request body. Only fields that overlap with the preset config are
||| persisted; other fields (e.g. `messages`, `stream`, `prompt`) are silently
||| ignored. Requires a read-write [management
||| key](/docs/guides/overview/auth/management-api-keys); inference API keys
||| are rejected.
|||
||| `POST /presets/{slug}/chat/completions`
|||
||| Query parameters: `workspace_id`.
export covering
createPresetsChatCompletions : HasIO io => Client -> (slug : String)
  -> (query : List (String, String)) -> (body : JSON) -> io (Either Error JSON)
createPresetsChatCompletions c slug query body = call c POST ("/presets/" ++ urlEncode slug ++ "/chat/completions") query (Just body)

||| Create a preset from a messages request body.
|||
||| Creates a preset (or a new version of an existing one) from an inference
||| request body. Only fields that overlap with the preset config are
||| persisted; other fields (e.g. `messages`, `stream`, `prompt`) are silently
||| ignored. Requires a read-write [management
||| key](/docs/guides/overview/auth/management-api-keys); inference API keys
||| are rejected.
|||
||| `POST /presets/{slug}/messages`
|||
||| Query parameters: `workspace_id`.
export covering
createPresetsMessages : HasIO io => Client -> (slug : String) -> (query : List (String, String))
  -> (body : JSON) -> io (Either Error JSON)
createPresetsMessages c slug query body = call c POST ("/presets/" ++ urlEncode slug ++ "/messages") query (Just body)

||| Create a preset from a responses request body.
|||
||| Creates a preset (or a new version of an existing one) from an inference
||| request body. Only fields that overlap with the preset config are
||| persisted; other fields (e.g. `messages`, `stream`, `prompt`) are silently
||| ignored. Requires a read-write [management
||| key](/docs/guides/overview/auth/management-api-keys); inference API keys
||| are rejected.
|||
||| `POST /presets/{slug}/responses`
|||
||| Query parameters: `workspace_id`.
export covering
createPresetsResponses : HasIO io => Client -> (slug : String)
  -> (query : List (String, String)) -> (body : JSON) -> io (Either Error JSON)
createPresetsResponses c slug query body = call c POST ("/presets/" ++ urlEncode slug ++ "/responses") query (Just body)

||| Restore a preset.
|||
||| Re-activates an archived preset so it resolves for inference again. No
||| version is created and the designated version is unchanged. Restoring an
||| active preset returns it unchanged. A disabled preset returns 409.
||| Requires a read-write [management
||| key](/docs/guides/overview/auth/management-api-keys); inference API keys
||| are rejected. `workspace_id` may be sent as a query parameter or a JSON
||| body field.
|||
||| `POST /presets/{slug}/restore`
|||
||| Query parameters: `workspace_id`.
export covering
restorePreset : HasIO io => Client -> (slug : String) -> (query : List (String, String))
  -> io (Either Error JSON)
restorePreset c slug query = call c POST ("/presets/" ++ urlEncode slug ++ "/restore") query Nothing

||| List versions of a preset.
|||
||| Lists all versions of a preset, ordered by version number ascending
||| (oldest first).
|||
||| `GET /presets/{slug}/versions`
|||
||| Query parameters: `offset`, `limit`, `workspace_id`.
export covering
listPresetVersions : HasIO io => Client -> (slug : String) -> (query : List (String, String))
  -> io (Either Error JSON)
listPresetVersions c slug query = call c GET ("/presets/" ++ urlEncode slug ++ "/versions") query Nothing

||| Get a specific version of a preset.
|||
||| Retrieves a specific version of a preset by its slug and version number.
|||
||| `GET /presets/{slug}/versions/{version}`
|||
||| Query parameters: `workspace_id`.
export covering
getPresetVersion : HasIO io => Client -> (slug : String) -> (version : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
getPresetVersion c slug version query = call c GET ("/presets/" ++ urlEncode slug ++ "/versions/" ++ urlEncode version) query Nothing

--------------------------------------------------------------------------------
-- Private Endpoints
--------------------------------------------------------------------------------

||| List private endpoints.
|||
||| List the organization's private endpoints, including drafts. Requires the
||| private endpoints entitlement. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /private-endpoints`
export covering
listPrivateEndpoints : HasIO io => Client -> io (Either Error JSON)
listPrivateEndpoints c = call c GET "/private-endpoints" [] Nothing

||| Create a private endpoint.
|||
||| Create a private endpoint as a draft. Drafts are not routable: validate
||| one with `POST /private-endpoints/{id}/validate`, then activate it with
||| `POST /private-endpoints/{id}/activate`. Pass `activate` to do all three
||| in one call; if validation fails the draft is kept and returned with the
||| failed checks. Send an `Idempotency-Key` header to make retries safe: a
||| repeated key with the same request returns the endpoint the first request
||| created; reusing it with different fields returns 422
||| `idempotency_key_reused`. Returns 400 `parameters_invalid` when
||| `tool_choice` is declared without `tools`. The response does not echo
||| `declared_parameters` or `tested_parameters`; read them with `GET
||| /private-endpoints/{id}`. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-endpoints`
|||
||| Headers, set through the client's `headers`: `idempotency-key`.
export covering
createPrivateEndpoint : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createPrivateEndpoint c body = call c POST "/private-endpoints" [] (Just body)

||| Delete a private endpoint.
|||
||| Delete a private endpoint and stop routing to it. Pass `draft_only=true`
||| to refuse (409) when the endpoint has been activated. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /private-endpoints/{id}`
|||
||| Query parameters: `draft_only`.
export covering
deletePrivateEndpoint : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deletePrivateEndpoint c id query = call c DELETE ("/private-endpoints/" ++ urlEncode id) query Nothing

||| Get a private endpoint.
|||
||| Get one private endpoint with its upstream configuration and current
||| pricing. [Management key](/docs/guides/overview/auth/management-api-keys)
||| required.
|||
||| `GET /private-endpoints/{id}`
export covering
getPrivateEndpoint : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getPrivateEndpoint c id = call c GET ("/private-endpoints/" ++ urlEncode id) [] Nothing

||| Update a private endpoint.
|||
||| Change any of the endpoint fields you own in one call; only the fields
||| present change, and the response is the whole endpoint. `pricing` and
||| `declared_parameters` replace their stored value, `settings` changes only
||| the fields it names (`null` clears a limit or restores the provider
||| default); routing picks these up for subsequent requests on drafts and
||| active endpoints alike. `declared_zdr` and `declared_region` change on
||| drafts and active endpoints alike; on an active endpoint the change keeps
||| its validation and tested parameters, and routing applies it to subsequent
||| requests. `upstream_model_id` and `base_url` re-point a draft: an omitted
||| `upstream_model_id` or `base_url` keeps the stored one, omitted
||| data-policy declarations are kept while the upstream is unchanged and
||| cleared when it changes, and any change to the upstream or declarations of
||| a draft clears earlier validation. Naming `upstream_model_id` or
||| `base_url` on an active endpoint returns 409 `already_active` and writes
||| nothing, even alongside other fields; delete and re-create instead. Every
||| group is checked before anything is written: 400 `parameters_invalid` when
||| `tool_choice` is declared without `tools` tested or declared, 400
||| `settings_invalid` when `max_prompt_tokens` exceeds the context length,
||| both completion APIs are off, or `excluded_parameters` names a tested
||| parameter, 422 `pricing_invalid` for rates the provider strategy cannot
||| represent, or `pricing_cache_read_unsupported` or
||| `pricing_cache_write_unsupported` when that rate is a cache rate the
||| strategy has no SKU for. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /private-endpoints/{id}`
export covering
updatePrivateEndpoint : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updatePrivateEndpoint c id body = call c PATCH ("/private-endpoints/" ++ urlEncode id) [] (Just body)

||| Activate a validated private endpoint.
|||
||| Make a validated draft routable. Returns 409 when the endpoint was never
||| validated, the validation is stale, or it is already active. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-endpoints/{id}/activate`
export covering
activatePrivateEndpoint : HasIO io => Client -> (id : String) -> io (Either Error JSON)
activatePrivateEndpoint c id = call c POST ("/private-endpoints/" ++ urlEncode id ++ "/activate") [] Nothing

||| Disable a private endpoint.
|||
||| Stop routing to an active endpoint without deleting it. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-endpoints/{id}/disable`
export covering
disablePrivateEndpoint : HasIO io => Client -> (id : String) -> io (Either Error JSON)
disablePrivateEndpoint c id = call c POST ("/private-endpoints/" ++ urlEncode id ++ "/disable") [] Nothing

||| Enable a private endpoint.
|||
||| Resume routing to a disabled endpoint. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-endpoints/{id}/enable`
export covering
enablePrivateEndpoint : HasIO io => Client -> (id : String) -> io (Either Error JSON)
enablePrivateEndpoint c id = call c POST ("/private-endpoints/" ++ urlEncode id ++ "/enable") [] Nothing

||| Validate a draft private endpoint.
|||
||| Send a live test request to the draft endpoint using the given workspace's
||| BYOK credential for its provider. A passing validation is required before
||| activation. Failed checks return 200 with `passed: false`. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-endpoints/{id}/validate`
export covering
validatePrivateEndpoint : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
validatePrivateEndpoint c id body = call c POST ("/private-endpoints/" ++ urlEncode id ++ "/validate") [] (Just body)

--------------------------------------------------------------------------------
-- Private Providers
--------------------------------------------------------------------------------

||| List private providers.
|||
||| List the organization's private providers. Requires the private endpoints
||| entitlement. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /private-providers`
export covering
listPrivateProviders : HasIO io => Client -> io (Either Error JSON)
listPrivateProviders c = call c GET "/private-providers" [] Nothing

||| Create a private provider.
|||
||| Create a private, bring-your-own-key provider visible only to your
||| organization. Use its slug as `provider_slug` when creating private
||| endpoints. Requires the private endpoints entitlement. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /private-providers`
export covering
createPrivateProvider : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createPrivateProvider c body = call c POST "/private-providers" [] (Just body)

||| Delete a private provider.
|||
||| Delete a private provider. Refuses (409) while any private endpoint still
||| runs under it. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /private-providers/{slug}`
export covering
deletePrivateProvider : HasIO io => Client -> (slug : String) -> io (Either Error JSON)
deletePrivateProvider c slug = call c DELETE ("/private-providers/" ++ urlEncode slug) [] Nothing

||| Get a private provider.
|||
||| Get one of the organization's private providers by slug. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /private-providers/{slug}`
export covering
getPrivateProvider : HasIO io => Client -> (slug : String) -> io (Either Error JSON)
getPrivateProvider c slug = call c GET ("/private-providers/" ++ urlEncode slug) [] Nothing

||| Update a private provider.
|||
||| Update a private provider's display name or base URL. The name and slug
||| cannot change, and the data policy is fixed by OpenRouter, so a body with
||| no editable field is rejected (400). [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /private-providers/{slug}`
export covering
updatePrivateProvider : HasIO io => Client -> (slug : String) -> (body : JSON)
  -> io (Either Error JSON)
updatePrivateProvider c slug body = call c PATCH ("/private-providers/" ++ urlEncode slug) [] (Just body)

--------------------------------------------------------------------------------
-- Providers
--------------------------------------------------------------------------------

||| List all providers.
|||
||| `GET /providers`
export covering
listProviders : HasIO io => Client -> io (Either Error JSON)
listProviders c = call c GET "/providers" [] Nothing

--------------------------------------------------------------------------------
-- Rerank
--------------------------------------------------------------------------------

||| Submit a rerank request.
|||
||| Submits a rerank request to the rerank router.
|||
||| `POST /rerank`
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
createRerank : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createRerank c body = call c POST "/rerank" [] (Just body)

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

||| Create a response.
|||
||| Creates a streaming or non-streaming response using OpenResponses API
||| format.
|||
||| `POST /responses`
|||
||| Headers, set through the client's `headers`: `X-OpenRouter-Metadata`.
|||
||| This returns the whole response. To stream it, see `openEventStream`.
export covering
createResponses : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createResponses c body = call c POST "/responses" [] (Just body)

--------------------------------------------------------------------------------
-- SCIM
--------------------------------------------------------------------------------

||| List SCIM group mappings.
|||
||| List SCIM group-to-workspace mappings for the organization. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /scim/group-mappings`
|||
||| Query parameters: `offset`, `limit`.
export covering
listScimGroupMappings : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listScimGroupMappings c query = call c GET "/scim/group-mappings" query Nothing

||| Create a SCIM group mapping.
|||
||| Create a SCIM group-to-workspace role mapping. Creating a mapping that
||| already exists with the same role succeeds and re-applies the mapping to
||| the group members. Requesting a different role for an existing mapping
||| returns 409. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /scim/group-mappings`
export covering
createScimGroupMapping : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createScimGroupMapping c body = call c POST "/scim/group-mappings" [] (Just body)

||| Delete a SCIM group mapping.
|||
||| Delete a SCIM group-to-workspace mapping. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /scim/group-mappings/{id}`
export covering
deleteScimGroupMapping : HasIO io => Client -> (id : String) -> (keepMembers : String)
  -> io (Either Error JSON)
deleteScimGroupMapping c id keepMembers = call c DELETE ("/scim/group-mappings/" ++ urlEncode id) [("keep_members", keepMembers)] Nothing

||| Get a SCIM group mapping.
|||
||| Get a SCIM group-to-workspace mapping. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /scim/group-mappings/{id}`
export covering
getScimGroupMapping : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getScimGroupMapping c id = call c GET ("/scim/group-mappings/" ++ urlEncode id) [] Nothing

||| Update a SCIM group mapping.
|||
||| Update a SCIM group mapping role. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /scim/group-mappings/{id}`
export covering
updateScimGroupMapping : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
updateScimGroupMapping c id body = call c PATCH ("/scim/group-mappings/" ++ urlEncode id) [] (Just body)

||| List SCIM groups.
|||
||| List SCIM groups for the organization. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /scim/groups`
|||
||| Query parameters: `offset`, `limit`, `display_name`, `external_id`.
export covering
listScimGroups : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listScimGroups c query = call c GET "/scim/groups" query Nothing

||| Start a SCIM directory sync.
|||
||| Start a SCIM directory sync. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /scim/sync-jobs`
export covering
createScimSyncJob : HasIO io => Client -> io (Either Error JSON)
createScimSyncJob c = call c POST "/scim/sync-jobs" [] Nothing

||| Get SCIM directory sync status.
|||
||| Get SCIM directory sync status. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /scim/sync-jobs/{id}`
export covering
getScimSyncJob : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getScimSyncJob c id = call c GET ("/scim/sync-jobs/" ++ urlEncode id) [] Nothing

--------------------------------------------------------------------------------
-- STT
--------------------------------------------------------------------------------

||| Create transcription.
|||
||| Transcribes audio into text. Accepts base64-encoded audio input as JSON,
||| an OpenAI-style multipart/form-data file upload, or a URL the provider
||| downloads directly, and returns the transcribed text.
|||
||| `POST /audio/transcriptions`
export covering
createAudioTranscriptions : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createAudioTranscriptions c body = call c POST "/audio/transcriptions" [] (Just body)

--------------------------------------------------------------------------------
-- SystemOne
--------------------------------------------------------------------------------

||| Submit a System One request.
|||
||| Sends state and typed questions to a System One model such as Jev and
||| returns its answers. Compatible with the TypeSafe SDKs. Bare System One
||| model IDs such as `jev-1.13` and `jev-latest` are mapped onto the
||| `typesafe/` namespace.
|||
||| `POST /systemone`
export covering
createSystemone : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createSystemone c body = call c POST "/systemone" [] (Just body)

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

||| List server tools.
|||
||| Lists every server tool OpenRouter can run on behalf of a model: accepted
||| `tools[].type` spellings per API format, the engines behind it with their
||| pricing, and how many endpoints run it natively.
|||
||| `GET /tools`
|||
||| Query parameters: `offset`, `limit`, `api_format`.
export covering
listTools : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listTools c query = call c GET "/tools" query Nothing

||| Get a server tool.
|||
||| One server tool by canonical name or any accepted alias, with the models
||| that run it natively.
|||
||| `GET /tools/{name}`
export covering
getTool : HasIO io => Client -> (name : String) -> io (Either Error JSON)
getTool c name = call c GET ("/tools/" ++ urlEncode name) [] Nothing

--------------------------------------------------------------------------------
-- TTS
--------------------------------------------------------------------------------

||| Create speech.
|||
||| Synthesizes audio from the input text. Returns a raw audio bytestream in
||| the requested format (e.g. mp3, pcm, wav).
|||
||| `POST /audio/speech`
|||
||| The response's bytes are written to `file`; the result is how many there
||| were.
export covering
createAudioSpeech : HasIO io => Client -> (body : JSON) -> (file : String)
  -> io (Either Error Nat)
createAudioSpeech c body file = download c POST "/audio/speech" [] (Just body) file

--------------------------------------------------------------------------------
-- Vault
--------------------------------------------------------------------------------

||| List the connections an intern can use.
|||
||| Lists the connections in scope for the intern, by the key of their card on
||| the dashboard's Connections tab: `github`, `slack`, `google`, a catalog
||| MCP server such as `linear` or `notion`, or `mcp:<host>` for a custom MCP
||| server. A connection is listed when it is stored, enabled, and not turned
||| off or hidden for this intern, as the Connections tab lists it; whether
||| its last test passed is not part of the rule. `ori features add` checks a
||| feature's `ori.requires.connections` against this list. `routing` is the
||| vault's routing table for the intern: the credentials it holds and what it
||| would inject each for, from the same lookups the egress proxy picks a
||| credential with, GitHub repository coverage read through the installation
||| token and cached. `routing_text` is that table as the lines the intern
||| reads in its instructions. Never credentials. Returns 404 for an intern
||| the key cannot see. The scope is selected by the API key: workspace routes
||| act on the key's active workspace and intern routes act on one intern
||| inside that workspace. There is no default workspace and no fallback to
||| another scope. Every vault route, including reads, requires access to the
||| Intern API programme and returns 404 outside it. An intern's own API key
||| is confined to that intern: it can always read the intern's secrets and
||| effective secrets, writes to them follow the rules above, and every other
||| intern and every workspace route answers 404. Requests on regional
||| hostnames such as `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `GET /vault/interns/{internId}/connections`
export covering
listInternConnections : HasIO io => Client -> (internId : String) -> io (Either Error JSON)
listInternConnections c internId = call c GET ("/vault/interns/" ++ urlEncode internId ++ "/connections") [] Nothing

||| List the secrets an intern receives.
|||
||| Lists, one entry per name, the secret the intern's outbound requests
||| receive: its own secrets, secrets from an attached vault, and workspace
||| secrets, including ones stored before workspace-scoped storage. Where
||| several vaults hold a name, the entry is the one that wins, in the order
||| intern, attached, workspace. The same resolution decides what outbound
||| requests receive, so this list and the intern's requests agree. `scope`
||| says which vault the entry comes from. Responses carry metadata only,
||| never values. Results are ordered by name and paginated with `limit` and
||| `offset`. Returns 404 when the intern's attached vault is no longer
||| available, since the intern then receives no secrets. The scope is
||| selected by the API key: workspace routes act on the key's active
||| workspace and intern routes act on one intern inside that workspace. There
||| is no default workspace and no fallback to another scope. Every vault
||| route, including reads, requires access to the Intern API programme and
||| returns 404 outside it. An intern's own API key is confined to that
||| intern: it can always read the intern's secrets and effective secrets,
||| writes to them follow the rules above, and every other intern and every
||| workspace route answers 404. Requests on regional hostnames such as
||| `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `GET /vault/interns/{internId}/effective-secrets`
|||
||| Query parameters: `limit`, `offset`.
export covering
listInternEffectiveVaultSecrets : HasIO io => Client -> (internId : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
listInternEffectiveVaultSecrets c internId query = call c GET ("/vault/interns/" ++ urlEncode internId ++ "/effective-secrets") query Nothing

||| List intern secrets.
|||
||| Lists secret metadata stored for one intern. The list includes secrets
||| stored from the dashboard or at provisioning before workspace-scoped
||| storage; where both exist under one name, the one stored through this API
||| is listed. Those older secrets cannot be deleted or copied through this
||| API, and storing the same name through this API replaces them. Responses
||| contain names, bound hosts, fingerprints and creation times, never secret
||| values. Results are ordered by name and paginated with `limit` and
||| `offset`. The scope is selected by the API key: workspace routes act on
||| the key's active workspace and intern routes act on one intern inside that
||| workspace. There is no default workspace and no fallback to another scope.
||| Every vault route, including reads, requires access to the Intern API
||| programme and returns 404 outside it. An intern's own API key is confined
||| to that intern: it can always read the intern's secrets and effective
||| secrets, writes to them follow the rules above, and every other intern and
||| every workspace route answers 404. Requests on regional hostnames such as
||| `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `GET /vault/interns/{internId}/secrets`
|||
||| Query parameters: `limit`, `offset`.
export covering
listInternVaultSecrets : HasIO io => Client -> (internId : String)
  -> (query : List (String, String)) -> io (Either Error JSON)
listInternVaultSecrets c internId query = call c GET ("/vault/interns/" ++ urlEncode internId ++ "/secrets") query Nothing

||| Copy workspace secrets to an intern.
|||
||| Copies the named workspace secrets into one intern's scope, replacing any
||| intern secret with the same name. Each copy keeps the source value and
||| host bindings. Every name must exist in the workspace scope or the request
||| fails with 404 and nothing is copied. A workspace secret whose `hosts` is
||| `null` cannot be copied: the request fails with 409 and nothing is copied
||| until that secret is stored again with hosts. The response carries
||| metadata only. Writes return 503 while vault writes are disabled for the
||| caller. The scope is selected by the API key: workspace routes act on the
||| key's active workspace and intern routes act on one intern inside that
||| workspace. There is no default workspace and no fallback to another scope.
||| Every vault route, including reads, requires access to the Intern API
||| programme and returns 404 outside it. An intern's own API key is confined
||| to that intern: it can always read the intern's secrets and effective
||| secrets, writes to them follow the rules above, and every other intern and
||| every workspace route answers 404. Requests on regional hostnames such as
||| `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `POST /vault/interns/{internId}/secrets/copy`
export covering
copyVaultSecretsToIntern : HasIO io => Client -> (internId : String) -> (body : JSON)
  -> io (Either Error JSON)
copyVaultSecretsToIntern c internId body = call c POST ("/vault/interns/" ++ urlEncode internId ++ "/secrets/copy") [] (Just body)

||| Delete an intern secret.
|||
||| Deletes a secret stored for one intern. Returns 204 with no body on
||| success and 404 when the secret does not exist in the selected scope.
||| Writes return 503 while vault writes are disabled for the caller. The
||| scope is selected by the API key: workspace routes act on the key's active
||| workspace and intern routes act on one intern inside that workspace. There
||| is no default workspace and no fallback to another scope. Every vault
||| route, including reads, requires access to the Intern API programme and
||| returns 404 outside it. An intern's own API key is confined to that
||| intern: it can always read the intern's secrets and effective secrets,
||| writes to them follow the rules above, and every other intern and every
||| workspace route answers 404. Requests on regional hostnames such as
||| `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `DELETE /vault/interns/{internId}/secrets/{name}`
export covering
deleteInternVaultSecret : HasIO io => Client -> (internId : String) -> (name : String)
  -> io (Either Error JSON)
deleteInternVaultSecret c internId name = call c DELETE ("/vault/interns/" ++ urlEncode internId ++ "/secrets/" ++ urlEncode name) [] Nothing

||| Store an intern secret.
|||
||| Creates or replaces a secret stored for one intern. The value is encrypted
||| at rest and released only to the exact hostnames in `hosts`. The response
||| carries metadata only. Writes return 503 while vault writes are disabled
||| for the caller. The scope is selected by the API key: workspace routes act
||| on the key's active workspace and intern routes act on one intern inside
||| that workspace. There is no default workspace and no fallback to another
||| scope. Every vault route, including reads, requires access to the Intern
||| API programme and returns 404 outside it. An intern's own API key is
||| confined to that intern: it can always read the intern's secrets and
||| effective secrets, writes to them follow the rules above, and every other
||| intern and every workspace route answers 404. Requests on regional
||| hostnames such as `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `PUT /vault/interns/{internId}/secrets/{name}`
export covering
storeInternVaultSecret : HasIO io => Client -> (internId : String) -> (name : String)
  -> (body : JSON) -> io (Either Error JSON)
storeInternVaultSecret c internId name body = call c PUT ("/vault/interns/" ++ urlEncode internId ++ "/secrets/" ++ urlEncode name) [] (Just body)

||| List workspace secrets.
|||
||| Lists secret metadata for the workspace of the authenticated API key. The
||| list includes secrets stored from the dashboard or at provisioning before
||| workspace-scoped storage; where both exist under one name, the one stored
||| through this API is listed. Those older secrets cannot be deleted or
||| copied through this API, and storing the same name through this API
||| replaces them. Responses contain names, bound hosts, fingerprints and
||| creation times, never secret values. Results are ordered by name and
||| paginated with `limit` and `offset`. The scope is selected by the API key:
||| workspace routes act on the key's active workspace and intern routes act
||| on one intern inside that workspace. There is no default workspace and no
||| fallback to another scope. Every vault route, including reads, requires
||| access to the Intern API programme and returns 404 outside it. An intern's
||| own API key is confined to that intern: it can always read the intern's
||| secrets and effective secrets, writes to them follow the rules above, and
||| every other intern and every workspace route answers 404. Requests on
||| regional hostnames such as `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `GET /vault/secrets`
|||
||| Query parameters: `limit`, `offset`.
export covering
listVaultSecrets : HasIO io => Client -> (query : List (String, String))
  -> io (Either Error JSON)
listVaultSecrets c query = call c GET "/vault/secrets" query Nothing

||| Delete a workspace secret.
|||
||| Deletes a secret from the workspace of the authenticated API key. Returns
||| 204 with no body on success and 404 when the secret does not exist in the
||| selected scope. Writes return 503 while vault writes are disabled for the
||| caller. The scope is selected by the API key: workspace routes act on the
||| key's active workspace and intern routes act on one intern inside that
||| workspace. There is no default workspace and no fallback to another scope.
||| Every vault route, including reads, requires access to the Intern API
||| programme and returns 404 outside it. An intern's own API key is confined
||| to that intern: it can always read the intern's secrets and effective
||| secrets, writes to them follow the rules above, and every other intern and
||| every workspace route answers 404. Requests on regional hostnames such as
||| `eu.openrouter.ai` are refused. [API
||| key](/docs/api-reference/authentication) required.
|||
||| `DELETE /vault/secrets/{name}`
export covering
deleteVaultSecret : HasIO io => Client -> (name : String) -> io (Either Error JSON)
deleteVaultSecret c name = call c DELETE ("/vault/secrets/" ++ urlEncode name) [] Nothing

||| Store a workspace secret.
|||
||| Creates or replaces a secret in the workspace of the authenticated API
||| key. The value is encrypted at rest and released only to the exact
||| hostnames in `hosts`. The response carries metadata only. Writes return
||| 503 while vault writes are disabled for the caller. The scope is selected
||| by the API key: workspace routes act on the key's active workspace and
||| intern routes act on one intern inside that workspace. There is no default
||| workspace and no fallback to another scope. Every vault route, including
||| reads, requires access to the Intern API programme and returns 404 outside
||| it. An intern's own API key is confined to that intern: it can always read
||| the intern's secrets and effective secrets, writes to them follow the
||| rules above, and every other intern and every workspace route answers 404.
||| Requests on regional hostnames such as `eu.openrouter.ai` are refused.
||| [API key](/docs/api-reference/authentication) required.
|||
||| `PUT /vault/secrets/{name}`
export covering
storeVaultSecret : HasIO io => Client -> (name : String) -> (body : JSON)
  -> io (Either Error JSON)
storeVaultSecret c name body = call c PUT ("/vault/secrets/" ++ urlEncode name) [] (Just body)

--------------------------------------------------------------------------------
-- Video Generation
--------------------------------------------------------------------------------

||| Submit a video generation request.
|||
||| Submits a video generation request and returns a polling URL to check
||| status.
|||
||| `POST /videos`
export covering
createVideos : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createVideos c body = call c POST "/videos" [] (Just body)

||| List all video generation models.
|||
||| Returns a list of all available video generation models and their
||| properties.
|||
||| `GET /videos/models`
export covering
listVideosModels : HasIO io => Client -> io (Either Error JSON)
listVideosModels c = call c GET "/videos/models" [] Nothing

||| Poll video generation status.
|||
||| Returns job status and content URLs when completed.
|||
||| `GET /videos/{jobId}`
export covering
getVideos : HasIO io => Client -> (jobId : String) -> io (Either Error JSON)
getVideos c jobId = call c GET ("/videos/" ++ urlEncode jobId) [] Nothing

||| Download generated video content.
|||
||| Streams the generated video content from the upstream provider.
|||
||| `GET /videos/{jobId}/content`
|||
||| Query parameters: `index`.
|||
||| The response's bytes are written to `file`; the result is how many there
||| were.
export covering
listVideosContent : HasIO io => Client -> (jobId : String) -> (query : List (String, String))
  -> (file : String) -> io (Either Error Nat)
listVideosContent c jobId query file = download c GET ("/videos/" ++ urlEncode jobId ++ "/content") query Nothing file

--------------------------------------------------------------------------------
-- Workspaces
--------------------------------------------------------------------------------

||| List workspaces.
|||
||| List all workspaces for the authenticated user. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /workspaces`
|||
||| Query parameters: `offset`, `limit`.
export covering
listWorkspaces : HasIO io => Client -> (query : List (String, String)) -> io (Either Error JSON)
listWorkspaces c query = call c GET "/workspaces" query Nothing

||| Create a workspace.
|||
||| Create a new workspace for the authenticated user. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /workspaces`
export covering
createWorkspace : HasIO io => Client -> (body : JSON) -> io (Either Error JSON)
createWorkspace c body = call c POST "/workspaces" [] (Just body)

||| Delete a workspace.
|||
||| Delete an existing workspace. Workspaces with active API keys cannot be
||| deleted; remove the keys first. Deleting the default workspace requires
||| confirm_default_workspace_deletion=true. Deleting any workspace
||| permanently deletes its budgets and guardrails and disables its
||| classifiers and broadcast destinations. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /workspaces/{id}`
|||
||| Query parameters: `confirm_default_workspace_deletion`.
export covering
deleteWorkspace : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
deleteWorkspace c id query = call c DELETE ("/workspaces/" ++ urlEncode id) query Nothing

||| Get a workspace.
|||
||| Get a single workspace by ID or slug. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /workspaces/{id}`
export covering
getWorkspace : HasIO io => Client -> (id : String) -> io (Either Error JSON)
getWorkspace c id = call c GET ("/workspaces/" ++ urlEncode id) [] Nothing

||| Update a workspace.
|||
||| Update an existing workspace by ID or slug. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PATCH /workspaces/{id}`
export covering
updateWorkspace : HasIO io => Client -> (id : String) -> (body : JSON) -> io (Either Error JSON)
updateWorkspace c id body = call c PATCH ("/workspaces/" ++ urlEncode id) [] (Just body)

||| List workspace members.
|||
||| List all members of a workspace. Returns paginated results. For the
||| default workspace, returns all organization members (implicit membership).
||| [Management key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /workspaces/{id}/members`
|||
||| Query parameters: `offset`, `limit`.
export covering
listWorkspaceMembers : HasIO io => Client -> (id : String) -> (query : List (String, String))
  -> io (Either Error JSON)
listWorkspaceMembers c id query = call c GET ("/workspaces/" ++ urlEncode id ++ "/members") query Nothing

||| Bulk add members to a workspace.
|||
||| Add multiple organization members to a workspace. New members are assigned
||| the workspace role that matches their organization role. Users who are
||| already members of the workspace keep their current role and are not
||| included in the response. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /workspaces/{id}/members/add`
export covering
bulkAddWorkspaceMembers : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkAddWorkspaceMembers c id body = call c POST ("/workspaces/" ++ urlEncode id ++ "/members/add") [] (Just body)

||| Bulk remove members from a workspace.
|||
||| Remove multiple members from a workspace. Members with active API keys in
||| the workspace cannot be removed. SCIM-managed members cannot be removed;
||| changes must be made in your identity provider. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `POST /workspaces/{id}/members/remove`
export covering
bulkRemoveWorkspaceMembers : HasIO io => Client -> (id : String) -> (body : JSON)
  -> io (Either Error JSON)
bulkRemoveWorkspaceMembers c id body = call c POST ("/workspaces/" ++ urlEncode id ++ "/members/remove") [] (Just body)

||| List workspace budgets.
|||
||| List all budgets configured for a workspace. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /workspaces/{workspace_ref}/budgets`
export covering
listWorkspaceBudgets : HasIO io => Client -> (workspaceRef : String) -> io (Either Error JSON)
listWorkspaceBudgets c workspaceRef = call c GET ("/workspaces/" ++ urlEncode workspaceRef ++ "/budgets") [] Nothing

||| Delete a workspace budget.
|||
||| Remove the budget for a given interval. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `DELETE /workspaces/{workspace_ref}/budgets/{interval}`
export covering
deleteWorkspaceBudget : HasIO io => Client -> (workspaceRef : String) -> (interval : String)
  -> io (Either Error JSON)
deleteWorkspaceBudget c workspaceRef interval = call c DELETE ("/workspaces/" ++ urlEncode workspaceRef ++ "/budgets/" ++ urlEncode interval) [] Nothing

||| Get a workspace budget.
|||
||| Retrieve the budget for a given interval. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `GET /workspaces/{workspace_ref}/budgets/{interval}`
export covering
getWorkspaceBudget : HasIO io => Client -> (workspaceRef : String) -> (interval : String)
  -> io (Either Error JSON)
getWorkspaceBudget c workspaceRef interval = call c GET ("/workspaces/" ++ urlEncode workspaceRef ++ "/budgets/" ++ urlEncode interval) [] Nothing

||| Create or update a workspace budget.
|||
||| Create or update the budget for a given interval. Budget limits must
||| strictly decrease as the interval narrows (lifetime > monthly > weekly >
||| daily). The optional `include_byok_in_budgets` flag is a workspace-wide
||| setting: when provided it applies to every budget interval for the
||| workspace, not just the interval in this request. Note that a change made
||| here is applied to budget enforcement immediately, but an already-open
||| workspace settings page in the web dashboard may keep showing the previous
||| value until it is reloaded. [Management
||| key](/docs/guides/overview/auth/management-api-keys) required.
|||
||| `PUT /workspaces/{workspace_ref}/budgets/{interval}`
export covering
upsertWorkspaceBudget : HasIO io => Client -> (workspaceRef : String) -> (interval : String)
  -> (body : JSON) -> io (Either Error JSON)
upsertWorkspaceBudget c workspaceRef interval body = call c PUT ("/workspaces/" ++ urlEncode workspaceRef ++ "/budgets/" ++ urlEncode interval) [] (Just body)
