module Main

import Harness
import Live
import Mock
import Pure
import System

covering
main : IO ()
main = do
  t <- newTally
  pureTests
  mock <- getEnv "OPENROUTER_MOCK_URL"
  whenJust mock mockTests
  live <- getEnv "OPENROUTER_LIVE"
  when (live == Just "1") liveTests
  report t
