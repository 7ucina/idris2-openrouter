||| Any endpoint of the API through `OpenRouter.API`, which has a function
||| for each one. Needs no API key.
|||
|||   pack exec examples/Endpoints.idr
module Endpoints

import Data.List
import Data.Maybe
import Data.String
import OpenRouter
import OpenRouter.API as API

main : IO ()
main = do
  let client = newClient ""
  -- results are JSON, read with `get`, `path` and the `as...` functions
  Right providers <- API.listProviders client
    | Left err => putStrLn ("Error: " ++ show err)
  let names = mapMaybe (asString . get "name") (asList (get "data" providers))
  putStrLn (show (length names) ++ " providers, among them " ++ joinBy ", " (take 5 (sort names)) ++ ".")

  -- path parameters are arguments; an endpoint with optional query
  -- parameters also takes them as a list, as `API.getModels client [("limit", "5")]`
  Right served <- API.listEndpoints client "openai" "gpt-4o-mini"
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn "\nWho serves openai/gpt-4o-mini:"
  for_ (asList (path ["data", "endpoints"] served)) $ \endpoint =>
    putStrLn ("  " ++ padRight 12 ' ' (fromMaybe "?" (asString (get "provider_name" endpoint)))
                ++ maybe "" (\n => show n ++ " tokens of context") (asNat (get "context_length" endpoint)))
