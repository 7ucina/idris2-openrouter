||| Streamed responses: the chunks a stream is made of, and an accumulator
||| that folds them into the same `ChatResponse` a plain request returns.
module OpenRouter.Stream

import Data.List
import Data.Maybe
import Data.SnocList
import Data.String
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Response

%default total

--------------------------------------------------------------------------------
-- Chunks
--------------------------------------------------------------------------------

||| A fragment of a tool call. The id and the name come once; the arguments
||| come in pieces.
public export
record ToolCallDelta where
  constructor MkToolCallDelta
  ||| Which of the message's tool calls this fragment belongs to.
  index     : Maybe Nat
  id        : Maybe String
  name      : Maybe String
  arguments : String

||| What one chunk adds to one choice.
public export
record Delta where
  constructor MkDelta
  index              : Nat
  ||| More of the reply's text, or `""`.
  content            : String
  ||| More of the model's reasoning, or `""`.
  reasoning          : String
  toolCalls          : List ToolCallDelta
  ||| Set on the choice's last chunk.
  finishReason       : Maybe FinishReason
  nativeFinishReason : Maybe String
  logprobs           : List TokenLogprob
  ||| Structured reasoning blocks, kept so the message can be sent back.
  reasoningDetails   : List JSON

public export
record Chunk where
  constructor MkChunk
  id       : Maybe String
  model    : Maybe String
  provider : Maybe String
  deltas   : List Delta
  ||| Token counts and cost, which arrive on the last chunk.
  usage    : Maybe Usage
  ||| Set when the provider failed in the middle of the stream.
  error    : Maybe ApiError
  raw      : JSON

toolCallDeltaFromJSON : JSON -> ToolCallDelta
toolCallDeltaFromJSON j =
  let f = get "function" j
   in MkToolCallDelta
        (asNat (get "index" j))
        (asString (get "id" j) >>= \s => if s == "" then Nothing else Just s)
        (asString (get "name" f) >>= \s => if s == "" then Nothing else Just s)
        (fromMaybe "" (asString (get "arguments" f)))

deltaFromJSON : JSON -> Delta
deltaFromJSON j =
  let d = get "delta" j
   in MkDelta
        (fromMaybe 0 (asNat (get "index" j)))
        -- a chat chunk carries delta.content; a text completion chunk, text
        (fromMaybe "" (asString (get "content" d) <|> asString (get "text" j)))
        (fromMaybe "" (asString (get "reasoning" d)))
        (map toolCallDeltaFromJSON (asList (get "tool_calls" d)))
        (parseFinishReason <$> asString (get "finish_reason" j))
        (asString (get "native_finish_reason" j))
        (logprobsFromJSON (get "logprobs" j))
        (asList (get "reasoning_details" d))

export
chunkFromJSON : JSON -> Chunk
chunkFromJSON j = MkChunk
  (asString (get "id" j))
  (asString (get "model" j))
  (asString (get "provider" j))
  (map deltaFromJSON (asList (get "choices" j)))
  (usageFromJSON (get "usage" j))
  (embeddedError j)
  j

||| The text a chunk adds to the first choice.
export
chunkText : Chunk -> String
chunkText c = concatMap content (filter ((== 0) . index) c.deltas)

||| The reasoning a chunk adds to the first choice.
export
chunkReasoning : Chunk -> String
chunkReasoning c = concatMap reasoning (filter ((== 0) . index) c.deltas)

--------------------------------------------------------------------------------
-- Accumulating
--------------------------------------------------------------------------------

record PartialCall where
  constructor MkPartialCall
  index     : Nat
  id        : String
  name      : String
  arguments : SnocList String

record PartialChoice where
  constructor MkPartialChoice
  index     : Nat
  content   : SnocList String
  reasoning : SnocList String
  calls     : List PartialCall          -- by ascending index
  finish    : Maybe FinishReason
  native    : Maybe String
  logprobs  : SnocList TokenLogprob
  details   : SnocList JSON

||| Everything a stream has said so far.
export
record Accumulator where
  constructor MkAccumulator
  id       : Maybe String
  model    : Maybe String
  provider : Maybe String
  choices  : List PartialChoice         -- by ascending index
  usage    : Maybe Usage

||| An accumulator that has seen nothing.
export
emptyAccumulator : Accumulator
emptyAccumulator = MkAccumulator Nothing Nothing Nothing [] Nothing

-- Change the entry with the given index, adding a fresh one in order when
-- there is none.
upsert : (index : a -> Nat) -> (fresh : Nat -> a) -> Nat -> (a -> a) -> List a -> List a
upsert index fresh i f [] = [f (fresh i)]
upsert index fresh i f (x :: xs) =
  case compare i (index x) of
    LT => f (fresh i) :: x :: xs
    EQ => f x :: xs
    GT => x :: upsert index fresh i f xs

addCall : List PartialCall -> ToolCallDelta -> List PartialCall
addCall calls d =
  let i = case d.index of
            Just i  => i
            -- no index: a fragment with an id opens a new call, one without
            -- continues the last
            Nothing => case (d.id, calls) of
              (Just _, _)        => length calls
              (Nothing, [])      => 0
              (Nothing, c :: cs) => (.index) (last (c :: cs))
   in upsert (.index) (\n => MkPartialCall n "" "" [<]) i
        (\c => { id        := fromMaybe c.id d.id
               , name      := fromMaybe c.name d.name
               , arguments $= (:< d.arguments) } c)
        calls

addDelta : List PartialChoice -> Delta -> List PartialChoice
addDelta choices d =
  upsert (.index) (\n => MkPartialChoice n [<] [<] [] Nothing Nothing [<] [<]) d.index
    (\c => { content   $= (:< d.content)
           , reasoning $= (:< d.reasoning)
           , calls     := foldl addCall c.calls d.toolCalls
           , finish    := d.finishReason <|> c.finish
           , native    := d.nativeFinishReason <|> c.native
           , logprobs  $= (<>< d.logprobs)
           , details   $= (<>< d.reasoningDetails) } c)
    choices

||| Add a chunk.
export
accumulate : Accumulator -> Chunk -> Accumulator
accumulate acc c =
  { id       := acc.id <|> c.id
  , model    := c.model <|> acc.model
  , provider := c.provider <|> acc.provider
  , choices  := foldl addDelta acc.choices c.deltas
  , usage    := c.usage <|> acc.usage } acc

finishCall : PartialCall -> ToolCall
finishCall c = MkToolCall c.id c.name (concat c.arguments)

finishChoice : PartialChoice -> Choice
finishChoice c =
  let content   = concat c.content
      reasoning = concat c.reasoning
      calls     = map finishCall c.calls
      details   = c.details <>> []
   in MkChoice c.index
        (MkMessage Assistant
           (if content == "" && not (null calls) then Nothing else Just (Plain content))
           Nothing calls Nothing
           (if null details then [] else [("reasoning_details", JArray details)]))
        c.finish c.native
        (if reasoning == "" then Nothing else Just reasoning)
        Nothing
        (c.logprobs <>> [])
        JNull

||| The response the chunks so far add up to.
export
accumulated : Accumulator -> ChatResponse
accumulated acc = MkChatResponse
  (fromMaybe "" acc.id)
  (fromMaybe "" acc.model)
  acc.provider
  Nothing
  (map finishChoice acc.choices)
  acc.usage
  JNull

||| Fold a whole stream's chunks into a response.
export
collectChunks : List Chunk -> ChatResponse
collectChunks = accumulated . foldl accumulate emptyAccumulator
