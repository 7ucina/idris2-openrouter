||| A chat in the terminal: replies stream in, and the conversation is kept.
||| The model is the first argument, if there is one.
|||
|||   pack exec examples/Chat.idr anthropic/claude-haiku-4.5
module Chat

import Data.String
import OpenRouter
import System
import System.File

covering
loop : Client -> (model : String) -> List Message -> IO ()
loop client model history = do
  putStr "\nyou> "
  fflush stdout
  Right line <- fGetLine stdin
    | Left _ => pure ()
  eof <- fEOF stdin
  let said = trim line
  if eof && said == "" then putStrLn "" else
    if said == "" then loop client model history else do
      let history' = history ++ [user said]
      putStr "\n"
      result <- chatStreamText client (chatRequest model history' []) $ \piece => do
        putStr piece
        fflush stdout
      putStrLn ""
      case result of
        Left err    => do putStrLn ("Error: " ++ show err)
                          loop client model history
        Right response => loop client model (history' ++ toList (reply response))

covering
main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  args <- getArgs
  let model = case args of
                (_ :: m :: _) => m
                _             => "openai/gpt-4o-mini"
  putStrLn ("Talking to " ++ model ++ ". End with Ctrl-D.")
  loop ({ appTitle := Just "idris2-openrouter chat example" } client) model
    [system "You are a concise, friendly assistant."]
