||| The cheapest models that can call tools. Needs no API key.
|||
|||   pack exec examples/Models.idr
module Models

import Data.List
import Data.Nat
import Data.Maybe
import Data.String
import OpenRouter

||| Dollars per million prompt tokens.
price : Model -> Double
price m = 1.0e6 * fromMaybe 0 m.pricing.prompt

||| An amount with three decimals.
dollars : Double -> String
dollars x =
  let thousandths = the Integer (cast (x * 1000 + 0.5))
   in "$" ++ show (thousandths `div` 1000) ++ "." ++ padLeft 3 '0' (show (thousandths `mod` 1000))

main : IO ()
main = do
  Right ms <- models (newClient "") [("supported_parameters", "tools")]
    | Left err => putStrLn ("Error: " ++ show err)
  let paid = sortBy (\a, b => compare (price a) (price b)) (filter (\m => price m > 0) ms)
  putStrLn (show (length ms) ++ " models can call tools. The ten cheapest that are not free:\n")
  for_ (take 10 paid) $ \m =>
    putStrLn (padRight 46 ' ' m.id
                ++ padLeft 8 ' ' (dollars (price m)) ++ " / M tokens in"
                ++ maybe "" (\n => ", " ++ show (n `div` 1000) ++ "k context") m.contextLength)
