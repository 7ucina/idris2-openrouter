||| A reply with a type. One schema is both the JSON Schema the model must
||| follow and the decoder for what it writes.
|||
|||   pack exec examples/Structured.idr
module Structured

import Data.String
import OpenRouter

record Planet where
  constructor MkPlanet
  name      : String
  moons     : Nat
  ||| In Earth days.
  year      : Double
  discovery : Maybe Integer

planet : Schema Planet
planet = map (\[n, m, y, d] => MkPlanet n m y d) $ object
  [ prop "name" string
  , prop "moons" (natural `describe` "The number of known moons")
  , prop "year" (number `describe` "The length of its year, in Earth days")
  , prop "discovery" (nullable integer `describe` "The year it was discovered; null if known since antiquity")
  ]

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let request = chatRequest "openai/gpt-4o-mini" ["Describe the planets of the solar system."] []
  Right (planets, _) <- chatAs client "planets" (object [prop "planets" (array planet)]) request
    | Left err => putStrLn ("Error: " ++ show err)
  let [ps] = planets
  for_ ps $ \p =>
    putStrLn (padRight 8 ' ' p.name ++ padLeft 4 ' ' (show p.moons) ++ " moons, a year of "
                ++ show p.year ++ " days"
                ++ maybe "" (\y => ", discovered in " ++ show y) p.discovery)
