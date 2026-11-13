||| Read a sentence aloud into a WAV file, then transcribe the file back
||| into text.
|||
|||   pack exec examples/Speech.idr
module Speech

import OpenRouter

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  let sentence = "The quick brown fox jumps over the lazy dog."

  -- Text to speech. Without `SpeechFormat "mp3"` the audio is headerless
  -- PCM, which every speech model can produce.
  Right _ <- speech client
      (speechRequest "heygen/heygen-voice-1-turbo:free" sentence [Voice "nadine"]) "speech.pcm"
    | Left err => putStrLn ("Error: " ++ show err)
  Just bytes <- saveWav "speech.pcm" "speech.wav" 24000
    | Nothing => putStrLn "Could not write speech.wav"
  putStrLn ("Wrote speech.wav (" ++ show bytes ++ " bytes)")

  -- Speech to text.
  Just audio <- audioFile "speech.wav"
    | Nothing => putStrLn "Could not read speech.wav"
  Right heard <- transcribe client
      (transcriptionRequest "openai/gpt-4o-mini-transcribe" audio [Language "en"])
    | Left err => putStrLn ("Error: " ++ show err)
  putStrLn ("Said:  " ++ sentence)
  putStrLn ("Heard: " ++ heard.text)
