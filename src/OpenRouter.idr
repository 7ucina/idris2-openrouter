||| A client for the OpenRouter API.
|||
||| ```idris
||| import OpenRouter
|||
||| main : IO ()
||| main = do
|||   Just client <- fromEnv
|||     | Nothing => putStrLn "Set OPENROUTER_API_KEY."
|||   Right reply <- chat client (chatRequest "openai/gpt-4o-mini" ["Why is the sky blue?"] [])
|||     | Left err => putStrLn (show err)
|||   putStrLn (text reply)
||| ```
|||
||| This module re-exports the whole package except `OpenRouter.HTTP` (the
||| libcurl binding) and `OpenRouter.SSE` (the event-stream decoder), which
||| are there to import when you need them.
module OpenRouter

import public OpenRouter.Async
import public OpenRouter.Client
import public OpenRouter.JSON
import public OpenRouter.Message
import public OpenRouter.Model
import public OpenRouter.Request
import public OpenRouter.Response
import public OpenRouter.Schema
import public OpenRouter.Stream
import public OpenRouter.Tools
