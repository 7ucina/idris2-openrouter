||| Print a reply as it is written.
|||
|||   pack exec examples/Stream.idr
module Stream

import OpenRouter
import System.File

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let request = chatRequest "openai/gpt-4o-mini" ["Write a haiku about dependent types."] []
  result <- chatStreamText client request $ \piece => do
    putStr piece
    fflush stdout
  case result of
    Left err    => putStrLn ("\nError: " ++ show err)
    -- the whole reply, as `chat` would have returned it
    Right reply => putStrLn ("\n\n(finished: " ++ maybe "?" show (finish reply) ++ ")")
