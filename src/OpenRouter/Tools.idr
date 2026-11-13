||| Tools with typed arguments, and the loop that runs them.
|||
||| A `Handler` pairs a tool's description with the function behind it. The
||| arguments a model writes are decoded by the tool's schema before the
||| function sees them, so the function takes an Idris value, not JSON:
|||
||| ```idris
||| weather : Handler IO
||| weather = handler "get_weather" "The current weather in a city."
|||   (object [prop "city" string])
|||   (\[city] => pure ("18 degrees and clear in " ++ city))
||| ```
module OpenRouter.Tools

import Data.List
import Data.String
import OpenRouter.Client
import OpenRouter.JSON
import OpenRouter.Message
import OpenRouter.Request
import OpenRouter.Response
import OpenRouter.Schema

%default total

||| A tool, and what to do when a model calls it.
public export
record Handler (io : Type -> Type) where
  constructor MkHandler
  tool : Tool
  ||| From the arguments, as the JSON text the model wrote, to the result
  ||| the model is shown.
  run  : (arguments : String) -> io String

||| A tool whose arguments are described, and decoded, by a schema. When a
||| model's arguments do not fit, the function is not called: the model is
||| told what was wrong instead, and can try again.
export
handler : Applicative io => (name : String) -> (description : String) -> Schema a
       -> (a -> io String) -> Handler io
handler name description schema f = MkHandler (tool name description schema) $ \arguments =>
  case decodeText schema (if trim arguments == "" then "{}" else arguments) of
    Right x => f x
    Left m  => pure ("Error: the arguments do not fit the tool's schema. " ++ show m)

||| How a conversation with tools went.
public export
record ToolRun where
  constructor MkToolRun
  ||| The last response. Its finish reason is still `FinishToolCalls` when
  ||| the rounds ran out before the model was done.
  response  : ChatResponse
  ||| The whole conversation: the request's messages, then every assistant
  ||| message and tool result, the last reply included.
  messages  : List Message
  ||| Every response along the way, in order, for adding up usage.
  responses : List ChatResponse

answer : Applicative io => List (Handler io) -> ToolCall -> io Message
answer handlers call =
  case find (\h => h.tool.name == call.name) handlers of
    Just h  => toolResult call.id <$> h.run call.arguments
    Nothing => pure (toolResult call.id ("Error: there is no tool named " ++ call.name ++ "."))

||| Chat with tools: send the request, run the tools the model calls, send
||| the results back, and repeat until the model answers without calling a
||| tool, or until tools have been run `maxRounds` times. The handlers' tools
||| are added to the request.
export covering
runTools : HasIO io => Client -> List (Handler io) -> (maxRounds : Nat) -> ChatRequest
        -> io (Either Error ToolRun)
runTools c handlers maxRounds request =
  go maxRounds [<] (withOptions [Tools (map tool handlers)] request)
  where
    go : Nat -> SnocList ChatResponse -> ChatRequest -> io (Either Error ToolRun)
    go rounds seen r = do
      Right resp <- chat c r
        | Left e => pure (Left e)
      let msgs = r.messages ++ toList (reply resp)
          done = MkToolRun resp msgs (seen <>> [resp])
      case (rounds, requestedTools resp) of
        (_, [])       => pure (Right done)
        (Z, _)        => pure (Right done)
        (S k, calls)  => do
          results <- traverse (answer handlers) calls
          go k (seen :< resp) ({ messages := msgs ++ results } r)

||| The tokens and the cost of a whole tool run.
export
totalUsage : ToolRun -> Usage
totalUsage run = foldl plus (MkUsage 0 0 0 Nothing Nothing Nothing JNull) (mapMaybe usage run.responses)
  where
    both : Num a => Maybe a -> Maybe a -> Maybe a
    both (Just x) (Just y) = Just (x + y)
    both x        y        = x <|> y

    plus : Usage -> Usage -> Usage
    plus a b = MkUsage
      (a.promptTokens + b.promptTokens)
      (a.completionTokens + b.completionTokens)
      (a.totalTokens + b.totalTokens)
      (both a.reasoningTokens b.reasoningTokens)
      (both a.cachedTokens b.cachedTokens)
      (both a.cost b.cost)
      JNull
