||| The Responses API: a streamed reply, then a tool loop.
|||
|||   pack exec examples/Responses.idr
module Responses

import OpenRouter
import System.File

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let model = "openai/gpt-4o-mini"

  -- a reply, printed as it is written
  Right reply <- respondStreamText client
      (responsesRequest model [say User "In one sentence: what is a monad?"] [Instructions "Be plain."])
      (\piece => putStr piece >> fflush stdout)
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn ("\n(" ++ maybe "?" (show . totalTokens) reply.usage ++ " tokens)\n")

  -- the same typed tools as the chat API
  let add = handler "add" "Add up a list of numbers." (object [prop "numbers" (array number)])
              (\[numbers] => pure (show (sum numbers)))
  Right answer <- respondWithTools client [add] 3
      (responsesRequest model [say User "What is 12.5 + 30 + 0.25? Use the tool."] [])
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn (outputText answer)
