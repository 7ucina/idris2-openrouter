||| One question, one answer.
|||
|||   pack exec examples/Hello.idr
module Hello

import OpenRouter

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let request = chatRequest "openai/gpt-4o-mini"
        [system "Answer in one sentence.", "Why is the sky blue?"]
        [Temperature 0.2, MaxTokens 200]
  Right reply <- chat client request
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn (text reply)
  whenJust reply.usage $ \u =>
    putStrLn ("\n(" ++ show u.totalTokens ++ " tokens" ++ maybe "" (\c => ", $" ++ show c) u.cost ++ ")")
