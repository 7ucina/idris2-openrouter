||| Make a picture and save it. The prompt is the first argument, if there
||| is one.
|||
|||   pack exec examples/Image.idr "a lighthouse at dusk, woodcut"
module Image

import OpenRouter
import System

main : IO ()
main = do
  Just client <- fromEnv
    | Nothing => putStrLn "Set OPENROUTER_API_KEY to run this example."
  args <- getArgs
  let prompt = case args of
                 (_ :: p :: _) => p
                 _             => "a small red fox, flat vector illustration"
  Right response <- generateImage client $
      imageRequest "recraft/recraft-v4.1-flash-v2" prompt [AspectRatio "1:1"]
    | Left err => putStrLn ("Error: " ++ show err)
  let [image] = response.images
    | _ => putStrLn "The model returned no image."
  -- name the file after the format the provider chose
  let file = case image.mediaType of
               Just "image/png"  => "picture.png"
               Just "image/jpeg" => "picture.jpg"
               Just "image/webp" => "picture.webp"
               _                 => "picture.img"
  Just bytes <- saveBase64 file image.base64
    | Nothing => putStrLn ("Could not write " ++ file)
  putStrLn ("Wrote " ++ file ++ " (" ++ show bytes ++ " bytes"
              ++ maybe "" (\c => ", $" ++ show c) (response.usage >>= cost) ++ ")")
