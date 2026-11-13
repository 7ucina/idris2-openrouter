||| Ask several questions at the same time, three at a time.
|||
|||   pack exec examples/Parallel.idr
module Parallel

import Data.String
import OpenRouter
import System.Clock

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let capitals  = ["Norway", "Peru", "Japan", "Kenya", "Canada", "Chile"]
      requests  = map (\country => chatRequest "openai/gpt-4o-mini"
                         [system "Answer with the city's name only.", user ("The capital of " ++ country ++ "?")]
                         [MaxTokens 10, Temperature 0]) capitals
  start   <- clockTime Monotonic
  replies <- chatAll client 3 requests
  end     <- clockTime Monotonic
  -- the replies are in the order of the requests
  for_ (zip capitals replies) $ \(country, reply) =>
    putStrLn (padRight 8 ' ' country ++ either (\err => "Error: " ++ show err) text reply)
  let ms = (toNano end - toNano start) `div` 1000000
  putStrLn ("\n" ++ show (length replies) ++ " replies in " ++ show ms ++ " ms")
