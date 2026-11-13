||| Tools with typed arguments. The schema of each tool is sent to the model,
||| and the same schema decodes what the model sends back, so the functions
||| below take Idris values and never touch JSON.
|||
|||   pack exec examples/Tools.idr
module Tools

import Data.String
import OpenRouter

||| A stand-in for a real weather service.
weather : Handler IO
weather = handler "get_weather" "The current weather in a city."
  (object
    [ prop "city" (string `describe` "The city's name, in English")
    , prop "unit" (nullable (enum ["celsius", "fahrenheit"]))
    ])
  (\[city, unit] => do
    putStrLn ("  [get_weather " ++ city ++ "]")
    pure $ case unit of
      Just "fahrenheit" => "64 degrees Fahrenheit and clear in " ++ city
      _                 => "18 degrees Celsius and clear in " ++ city)

add : Handler IO
add = handler "add" "Add up a list of numbers."
  (object [prop "numbers" (array number)])
  (\[numbers] => do
    putStrLn ("  [add " ++ show numbers ++ "]")
    pure (show (sum numbers)))

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let request = chatRequest "openai/gpt-4o-mini"
        ["What is the weather in Oslo and in Lima? Also, what is 12.5 + 30 + 0.25?"] []
  -- run tools for at most five rounds
  Right run <- runTools client [weather, add] 5 request
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn (text run.response)
  putStrLn ("\n(" ++ show (length run.responses) ++ " requests, "
              ++ show (totalUsage run).totalTokens ++ " tokens)")
