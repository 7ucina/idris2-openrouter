||| Order documents by how well they answer a question.
|||
|||   pack exec examples/Rerank.idr
module Rerank

import Data.Maybe
import Data.String
import OpenRouter

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let documents =
        [ "Idris is a programming language with dependent types."
        , "The capital of Norway is Oslo."
        , "Totality checking shows that a function terminates on every input."
        , "Chez Scheme compiles Scheme to native code."
        ]
  Right ranked <- rerank client (rerankRequest "cohere/rerank-v3.5" "How do I know my function always finishes?" documents [])
    | Left err => putStrLn ("Error: " ++ show err)
  for_ ranked.results $ \result =>
    putStrLn (padLeft 6 ' ' (substr 0 5 (show result.score)) ++ "  " ++ fromMaybe "" result.document)
