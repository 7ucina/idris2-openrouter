||| A few lines of test harness: named checks, counted.
module Harness

import Data.IORef
import Data.String
import System

%default total

export
record Tally where
  constructor MkTally
  passed : IORef Nat
  failed : IORef Nat

export
newTally : IO Tally
newTally = [| MkTally (newIORef 0) (newIORef 0) |]

export
section : String -> IO ()
section name = putStrLn ("\n" ++ name)

export
check : Tally => String -> Bool -> IO ()
check @{t} name True  = modifyIORef t.passed S
check @{t} name False = do
  modifyIORef t.failed S
  putStrLn ("  FAIL  " ++ name)

||| Check that two values are equal, and show both when they are not.
export
same : Tally => Show a => Eq a => String -> (got : a) -> (want : a) -> IO ()
same @{t} name got want =
  if got == want then modifyIORef t.passed S else do
    modifyIORef t.failed S
    putStrLn ("  FAIL  " ++ name)
    putStrLn ("        got   " ++ show got)
    putStrLn ("        want  " ++ show want)

||| Print the totals, and exit with a failure when any check failed.
export
report : Tally -> IO ()
report t = do
  p <- readIORef t.passed
  f <- readIORef t.failed
  putStrLn ("\n" ++ show p ++ " passed, " ++ show f ++ " failed")
  when (f > 0) (exitWith (ExitFailure 1))
