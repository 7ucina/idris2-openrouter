||| Running requests at the same time.
|||
||| Every function in `OpenRouter.Client` blocks until it is done. To do
||| several things at once, run each on a thread of its own: `async` starts
||| one, `await` collects its result, and `concurrently` runs a whole list
||| with a limit on how many go at a time.
|||
||| ```idris
||| replies <- concurrently 4 [ask client model q | q <- questions]
||| ```
|||
||| Threads here are operating system threads. A thread that waits on the
||| network does not hold up the others.
module OpenRouter.Async

import Data.IORef
import Data.List
import Data.Maybe
import OpenRouter.Client
import OpenRouter.Request
import OpenRouter.Response
import System.Concurrency

%default total

--------------------------------------------------------------------------------
-- Tasks
--------------------------------------------------------------------------------

||| A computation running on a thread of its own, and in time its result.
export
record Task a where
  constructor MkTask
  result   : IORef (Maybe a)
  lock     : Mutex
  finished : Condition

||| Start an action on a new thread, and carry on at once.
export
async : IO a -> IO (Task a)
async action = do
  result   <- newIORef Nothing
  lock     <- makeMutex
  finished <- makeCondition
  _ <- fork $ do
    x <- action
    mutexAcquire lock
    writeIORef result (Just x)
    conditionBroadcast finished
    mutexRelease lock
  pure (MkTask result lock finished)

||| Wait for a task and get its result. Awaiting a task again, or from
||| several threads, gives the same result each time.
export covering
await : Task a -> IO a
await t = do
  mutexAcquire t.lock
  x <- wait
  mutexRelease t.lock
  pure x
  where
    wait : IO a
    wait = do
      Nothing <- readIORef t.result
        | Just x => pure x
      conditionWait t.finished t.lock
      wait

||| The task's result if it has finished, without waiting.
export
poll : Task a -> IO (Maybe a)
poll t = do
  mutexAcquire t.lock
  x <- readIORef t.result
  mutexRelease t.lock
  pure x

||| Wait for every task, and get the results in the tasks' order.
export covering
awaitAll : List (Task a) -> IO (List a)
awaitAll = traverse await

--------------------------------------------------------------------------------
-- Many at once
--------------------------------------------------------------------------------

||| Run the actions at the same time, at most `limit` of them at any moment
||| (`0` for no limit), and return their results in the actions' order.
||| Rate limits make a small limit worth having.
export covering
concurrently : (limit : Nat) -> List (IO a) -> IO (List a)
concurrently limit actions = do
  slots <- traverse (const (newIORef Nothing)) actions
  queue <- newIORef (zipWith (\slot, action => action >>= writeIORef slot . Just) slots actions)
  lock  <- makeMutex
  let count = length actions
  workers <- traverse (const (async (work lock queue)))
               (replicate (if limit == 0 then count else min limit count) ())
  ignore (awaitAll workers)
  catMaybes <$> traverse readIORef slots
  where
    -- Take jobs off the queue until there are none left.
    work : Mutex -> IORef (List (IO ())) -> IO ()
    work lock queue = do
      mutexAcquire lock
      jobs <- readIORef queue
      case jobs of
        [] => mutexRelease lock
        job :: rest => do
          writeIORef queue rest
          mutexRelease lock
          job
          work lock queue

||| Send several chat requests at the same time, at most `limit` at any
||| moment (`0` for no limit). The replies come back in the requests' order;
||| one request failing does not disturb the others.
export covering
chatAll : Client -> (limit : Nat) -> List ChatRequest -> IO (List (Either Error ChatResponse))
chatAll client limit requests = concurrently limit (map (chat client) requests)
