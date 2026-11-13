||| The client against openrouter.ai. The catalog endpoints need no key and
||| cost nothing. About twenty small paid requests (around a cent in all, most
||| of it one generated image) run only when OPENROUTER_API_KEY is set.
module Live

import Data.IORef
import Data.List
import Data.Maybe
import Data.Nat
import Data.String
import Harness
import OpenRouter

%default covering

export
liveTests : Tally => IO ()
liveTests = do
  section "Live: public endpoints"
  let anon = newClient ""
  n <- modelCount anon
  check "there are models" (either (const 0) id n > 50)

  ms <- models anon []
  let ms' = either (const []) id ms
  putStrLn ("  " ++ show (length ms') ++ " models listed")
  check "the whole model list decodes" (length ms' > 50)
  check "every model has an id and a name" (all (\m => m.id /= "" && m.name /= "") ms')
  check "most models have a context length" (2 * length (filter (\m => m.contextLength /= Nothing) ms') > length ms')
  check "most models have a prompt price" (2 * length (filter (\m => m.pricing.prompt /= Nothing) ms') > length ms')
  check "some model takes tools" (any (supports "tools") ms')

  es <- modelEndpoints anon "openai/gpt-4o-mini"
  check "a model has endpoints, with provider names"
    (either (const False) (\xs => not (null xs) && all (\e => e.providerName /= "") xs) es)

  ps <- providers anon
  check "there are providers, with slugs" (either (const False) (\xs => length xs > 10 && all (\p => p.slug /= "") xs) ps)

  em <- embeddingModels anon
  check "there are embedding models" (either (const False) (not . null) em)

  r <- chat anon (chatRequest "openai/gpt-4o-mini" ["hi"] [MaxTokens 1])
  check "a chat request with no key is refused with a 401"
    (case r of Left (Api e) => e.status == 401; _ => False)
  k <- keyInfo (newClient "sk-or-v1-not-a-real-key")
  check "a made-up key is refused with a 401"
    (case k of Left (Api e) => e.status == 401; _ => False)

  Just c <- fromEnv
    | Nothing => putStrLn "\n(OPENROUTER_API_KEY is not set: skipping the paid requests)"
  section "Live: paid requests"
  r <- chat c (chatRequest "openai/gpt-4o-mini" ["Reply with the single word: pong"] [MaxTokens 8, Temperature 0])
  check ("a chat reply: " ++ either show text r) (either (const False) (isInfixOf "pong" . toLower . text) r)
  out <- newIORef ""
  r <- chatStreamText c (chatRequest "openai/gpt-4o-mini" ["Reply with the single word: pong"] [MaxTokens 8, Temperature 0])
         (\t => modifyIORef out (++ t))
  o <- readIORef out
  check ("a streamed reply: " ++ either show text r)
    (either (const False) (\x => text x == o && isInfixOf "pong" (toLower o) && x.usage /= Nothing) r)

  let mini = "openai/gpt-4o-mini"
  r <- chat c (chatRequest mini ["Say hi."] [MaxTokens 4, Logprobs True, TopLogprobs 2])
  check "log probabilities, with alternatives"
    (either (const False) (\x => maybe False (\ch => not (null ch.logprobs) && all (\l => length l.top == 2 && l.logprob <= 0) ch.logprobs) (firstChoice x)) r)
  check "usage and cost are reported"
    (either (const False) (\x => maybe False (\u => u.promptTokens > 0 && u.totalTokens > u.promptTokens && maybe False (> 0) u.cost) x.usage) r)
  let genId = either (const "") (.id) r

  r <- chat c (chatRequest "openai/not-a-model" ["hi"] [])
  check ("an unknown model is an API error: " ++ either show (const "ok") r)
    (case r of Left (Api e) => e.status == 400 || e.status == 404; _ => False)

  calls <- newIORef (the (List (String, Integer)) [])
  let h = handler "multiply" "Multiply two integers." (object [prop "a" integer, prop "b" integer]) $ \[a, b] => do
            modifyIORef calls (("multiply", a * b) ::)
            pure (show (a * b))
  run <- runTools c [h] 4 (chatRequest mini ["Use the multiply tool to compute 1234 times 5678, then state the result."] [Temperature 0])
  cs <- readIORef calls
  check ("a tool loop: " ++ either show (text . response) run)
    (cs == [("multiply", 7006652)] && either (const False) (\x => isInfixOf "7006652" (pack (filter isDigit (unpack (text x.response))))) run)

  r <- chatStream c (chatRequest mini ["What is 6 times 7? Use the tool."] [Tools [h.tool], ToolChoice Required]) (\_ => pure ())
  check ("a streamed tool call is assembled: " ++ either show (show . map arguments . requestedTools) r)
    (either (const False) (\x => map name (requestedTools x) == ["multiply"]
        && all (\t => t.id /= "" && either (const False) (const True) (decodeText (object [prop "a" integer, prop "b" integer]) t.arguments)) (requestedTools x)
        && finish x == Just FinishToolCalls) r)

  s <- chatAs c "capital" (object [prop "country" string, prop "capital" string, prop "population_millions" number])
         (chatRequest mini ["The capital of Norway."] [Temperature 0])
  check ("structured output: " ++ either show (const "ok") s)
    (case s of Right ([_, capital, pop], _) => capital == "Oslo" && pop > 0; _ => False)

  r <- chat c (chatRequest "openai/gpt-5-nano" ["What is 17 * 23? Just the number."] [Reasoning [Effort Low]])
  check ("a reasoning model: " ++ either show text r)
    (either (const False) (\x => isInfixOf "391" (text x) && maybe False (\u => isJust u.reasoningTokens) x.usage) r)

  r <- complete c (completionRequest mini "The capital of France is" [MaxTokens 16, Temperature 0])
  check ("a text completion: " ++ either show completionText r) (either (const False) (isInfixOf "Paris" . completionText) r)
  out <- newIORef ""
  r <- completeStream c (completionRequest mini "The capital of France is" [MaxTokens 16, Temperature 0]) (\t => modifyIORef out (++ t))
  o <- readIORef out
  check ("a streamed text completion: " ++ either show id r) (either (const False) (\t => t == o && isInfixOf "Paris" t) r)

  r <- embed c (embeddingRequest "openai/text-embedding-3-small" ["a cat", "a kitten", "tax law"] [])
  check ("embeddings: " ++ either show (show . map length . embeddings) r)
    (case r of
       Right x => case x.embeddings of
         [a, b, t] => length a > 100 && length a == length b && dot a b > dot a t
         _         => False
       Left _ => False)

  let out = "test/build/live"
  r <- speech c (speechRequest "heygen/heygen-voice-1-turbo:free" "The quick brown fox jumps over the lazy dog." [Voice "nadine"]) (out ++ ".pcm")
  check ("speech is written to a file: " ++ either show show r) (either (const False) (> 20000) r)
  w <- saveWav (out ++ ".pcm") (out ++ ".wav") 24000
  check "and wrapped as WAV" (w == map (+ 44) (either (const Nothing) Just r))
  Just heard <- audioFile (out ++ ".wav")
    | Nothing => check "the WAV file is read back" False
  t <- transcribe c (transcriptionRequest "openai/gpt-4o-mini-transcribe" heard [Language "en"])
  check ("and transcribed: " ++ either show (.text) t) (either (const False) (isInfixOf "quick brown fox" . toLower . (.text)) t)

  s <- chatStream c (chatRequest "openai/gpt-audio-mini" ["Say exactly: hello from Idris."] (spoken "alloy" "pcm16" ++ [MaxTokens 200])) (\_ => pure ())
  check ("a spoken chat reply: " ++ either show (maybe "no audio" transcript . replyAudio) s)
    (either (const False) (maybe False (\a => isInfixOf "hello" (toLower a.transcript) && length a.base64 > 10000) . replyAudio) s)
  n <- maybe (pure Nothing) (saveBase64 (out ++ "2.pcm") . base64) (either (const Nothing) replyAudio s)
  check "its audio decodes to whole 16-bit samples" (maybe False (\b => b > 10000 && b `mod` 2 == 0) n)

  i <- generateImage c (imageRequest "recraft/recraft-v4.1-flash-v2" "a small red fox, flat vector illustration" [AspectRatio "1:1"])
  check ("an image is generated: " ++ either show (show . map mediaType . images) i)
    (either (const False) (\x => any (\g => length g.base64 > 1000) x.images) i)
  n <- maybe (pure Nothing) (saveBase64 (out ++ ".img") . base64) (either (const Nothing) (head' . images) i)
  check "and saved" (maybe False (> 1000) n)
  Just picture <- fileDataURI "image/webp" (out ++ ".img")
    | Nothing => check "the image is read back" False
  v <- chat c (chatRequest mini [userParts [Text "What animal is this? One word.", Image picture]] [MaxTokens 10])
  check ("and recognized when sent back as input: " ++ either show text v) (either (const False) (isInfixOf "fox" . toLower . text) v)

  k <- keyInfo c
  putStrLn ("  key: " ++ either show (\x => x.label ++ ", used $" ++ maybe "?" show x.usage ++ ", limit " ++ maybe "none" show x.limit) k)
  check "the key's record" (either (const False) (\x => x.label /= "" && x.usage /= Nothing) k)
  cr <- credits c
  check ("credits: " ++ either show (\x => show x.purchased ++ " bought, " ++ show x.used ++ " used") cr)
    (either (const False) (\x => x.purchased >= 0 && x.used >= 0) cr)

  g <- generation ({ retries := 6, backoff := 1000 } c) genId
  check ("a generation record: " ++ either show (\x => x.model ++ " via " ++ fromMaybe "?" x.provider ++ ", $" ++ maybe "?" show x.cost) g)
    (either (const False) (\x => x.id == genId && x.promptTokens /= Nothing) g)
  where
    Eq Usage where
      a == b = a.totalTokens == b.totalTokens

    dot : List Double -> List Double -> Double
    dot xs ys = sum (zipWith (*) xs ys)
