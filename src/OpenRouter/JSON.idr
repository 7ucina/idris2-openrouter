||| A small, total JSON library: a value type, a parser, two printers, and
||| the helpers the rest of the package builds and reads values with.
|||
||| Integers and other numbers are kept apart (`JInt`, `JNum`), so a token
||| count is printed as `256` and never as `256.0`.
module OpenRouter.JSON

import Data.List
import Data.Maybe
import Data.SnocList
import Data.String

%default total

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

public export
data JSON : Type where
  JNull   : JSON
  JBool   : Bool -> JSON
  ||| A number written without a fraction or an exponent.
  JInt    : Integer -> JSON
  JNum    : Double -> JSON
  JString : String -> JSON
  JArray  : List JSON -> JSON
  ||| The fields in the order they were written. On a repeated key, readers
  ||| take the first.
  JObject : List (String, JSON) -> JSON

mutual
  eqJSON : JSON -> JSON -> Bool
  eqJSON JNull        JNull        = True
  eqJSON (JBool a)    (JBool b)    = a == b
  eqJSON (JInt a)     (JInt b)     = a == b
  eqJSON (JNum a)     (JNum b)     = a == b
  eqJSON (JInt a)     (JNum b)     = cast a == b
  eqJSON (JNum a)     (JInt b)     = a == cast b
  eqJSON (JString a)  (JString b)  = a == b
  eqJSON (JArray a)   (JArray b)   = eqList a b
  eqJSON (JObject a)  (JObject b)  = eqFields a b
  eqJSON _            _            = False

  eqList : List JSON -> List JSON -> Bool
  eqList []        []        = True
  eqList (x :: xs) (y :: ys) = eqJSON x y && eqList xs ys
  eqList _         _         = False

  eqFields : List (String, JSON) -> List (String, JSON) -> Bool
  eqFields []             []             = True
  eqFields ((k, x) :: xs) ((l, y) :: ys) = k == l && eqJSON x y && eqFields xs ys
  eqFields _              _              = False

||| Structural equality. Object fields are compared in order.
export
Eq JSON where
  (==) = eqJSON

--------------------------------------------------------------------------------
-- Printing
--------------------------------------------------------------------------------

hexDigit : Int -> Char
hexDigit n = if n < 10 then chr (ord '0' + n) else chr (ord 'a' + n - 10)

escapeChar : Char -> List Char
escapeChar '"'  = ['\\', '"']
escapeChar '\\' = ['\\', '\\']
escapeChar '\n' = ['\\', 'n']
escapeChar '\r' = ['\\', 'r']
escapeChar '\t' = ['\\', 't']
escapeChar c    =
  let n = ord c
   in if n < 0x20 || n == 0x7f
         then ['\\', 'u', '0', '0', hexDigit (n `div` 16), hexDigit (n `mod` 16)]
         else [c]

needsEscape : Char -> Bool
needsEscape c = c == '"' || c == '\\' || ord c < 0x20 || ord c == 0x7f

||| A string as a JSON string literal, quotes included.
export
quote : String -> String
quote s =
  let cs = unpack s
   in if any needsEscape cs
         then pack ('"' :: foldr (\c, acc => escapeChar c ++ acc) ['"'] cs)
         else "\"" ++ s ++ "\""

showNum : Double -> String
showNum d =
  if d /= d || d - d /= 0 then "null"          -- NaN and the infinities have no JSON form
  else let s = show d
        in if isSuffixOf "." s then s ++ "0" else s

mutual
  compact : JSON -> SnocList String -> SnocList String
  compact JNull         acc = acc :< "null"
  compact (JBool True)  acc = acc :< "true"
  compact (JBool False) acc = acc :< "false"
  compact (JInt n)      acc = acc :< show n
  compact (JNum d)      acc = acc :< showNum d
  compact (JString s)   acc = acc :< quote s
  compact (JArray [])   acc = acc :< "[]"
  compact (JArray (x :: xs)) acc = compactItems xs (compact x (acc :< "[")) :< "]"
  compact (JObject [])  acc = acc :< "{}"
  compact (JObject ((k, v) :: fs)) acc =
    compactFields fs (compact v (acc :< "{" :< quote k :< ":")) :< "}"

  compactItems : List JSON -> SnocList String -> SnocList String
  compactItems []        acc = acc
  compactItems (x :: xs) acc = compactItems xs (compact x (acc :< ","))

  compactFields : List (String, JSON) -> SnocList String -> SnocList String
  compactFields []             acc = acc
  compactFields ((k, v) :: fs) acc = compactFields fs (compact v (acc :< "," :< quote k :< ":"))

||| A value on one line, with no spaces.
export
render : JSON -> String
render j = concat (compact j [<])

mutual
  indented : (pad : String) -> JSON -> SnocList String -> SnocList String
  indented pad (JArray (x :: xs)) acc =
    let inner = pad ++ "  "
     in indentedItems inner xs (indented inner x (acc :< "[\n" :< inner)) :< "\n" :< pad :< "]"
  indented pad (JObject ((k, v) :: fs)) acc =
    let inner = pad ++ "  "
     in indentedFields inner fs (indented inner v (acc :< "{\n" :< inner :< quote k :< ": "))
          :< "\n" :< pad :< "}"
  indented pad j acc = compact j acc

  indentedItems : String -> List JSON -> SnocList String -> SnocList String
  indentedItems pad []        acc = acc
  indentedItems pad (x :: xs) acc = indentedItems pad xs (indented pad x (acc :< ",\n" :< pad))

  indentedFields : String -> List (String, JSON) -> SnocList String -> SnocList String
  indentedFields pad []             acc = acc
  indentedFields pad ((k, v) :: fs) acc =
    indentedFields pad fs (indented pad v (acc :< ",\n" :< pad :< quote k :< ": "))

||| A value over several lines, indented by two spaces.
export
pretty : JSON -> String
pretty j = concat (indented "" j [<])

export
Show JSON where
  show = render

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

||| Where a text stopped being JSON: how many characters in, and why.
public export
record ParseError where
  constructor MkParseError
  offset : Nat
  reason : String

export
Show ParseError where
  show e = e.reason ++ " at character " ++ show e.offset

-- A failure carries the input that was left, so the offset is only counted
-- when something goes wrong.
Res : Type -> Type
Res a = Either (String, List Char) (a, List Char)

skip : List Char -> List Char
skip (' '  :: cs) = skip cs
skip ('\n' :: cs) = skip cs
skip ('\r' :: cs) = skip cs
skip ('\t' :: cs) = skip cs
skip cs           = cs

hexVal : Char -> Maybe Int
hexVal c =
  if c >= '0' && c <= '9' then Just (ord c - ord '0')
  else if c >= 'a' && c <= 'f' then Just (ord c - ord 'a' + 10)
  else if c >= 'A' && c <= 'F' then Just (ord c - ord 'A' + 10)
  else Nothing

hex4 : Char -> Char -> Char -> Char -> Maybe Int
hex4 a b c d = [| combine (hexVal a) (hexVal b) (hexVal c) (hexVal d) |]
  where
    combine : Int -> Int -> Int -> Int -> Int
    combine w x y z = ((w * 16 + x) * 16 + y) * 16 + z

replacement : Char
replacement = chr 0xFFFD

-- The text of a string literal, after its opening quote.
str : SnocList Char -> List Char -> Res String
str acc ('"' :: cs) = Right (pack (acc <>> []), cs)
str acc ('\\' :: 'u' :: a :: b :: c :: d :: cs) =
  case hex4 a b c d of
    Nothing => Left ("a \\u escape needs four hex digits", a :: b :: c :: d :: cs)
    Just hi =>
      if hi >= 0xD800 && hi <= 0xDBFF
         then case cs of
           -- a surrogate pair is one character
           '\\' :: 'u' :: e :: f :: g :: h :: cs' =>
             case hex4 e f g h of
               Just lo =>
                 if lo >= 0xDC00 && lo <= 0xDFFF
                    then str (acc :< chr (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))) cs'
                    else str (acc :< replacement) cs
               Nothing => str (acc :< replacement) cs
           _ => str (acc :< replacement) cs
      else if hi >= 0xDC00 && hi <= 0xDFFF then str (acc :< replacement) cs
      else str (acc :< chr hi) cs
str acc ('\\' :: c :: cs) =
  case c of
    '"'  => str (acc :< '"') cs
    '\\' => str (acc :< '\\') cs
    '/'  => str (acc :< '/') cs
    'b'  => str (acc :< '\b') cs
    'f'  => str (acc :< '\f') cs
    'n'  => str (acc :< '\n') cs
    'r'  => str (acc :< '\r') cs
    't'  => str (acc :< '\t') cs
    _    => Left ("unknown escape", c :: cs)
str acc (c :: cs) =
  if ord c < 0x20 then Left ("control character in a string", c :: cs) else str (acc :< c) cs
str acc [] = Left ("unterminated string", [])

digits : SnocList Char -> List Char -> (SnocList Char, List Char)
digits acc (c :: cs) = if isDigit c then digits (acc :< c) cs else (acc, c :: cs)
digits acc []        = (acc, [])

-- A number, by the JSON grammar: -? int frac? exp?
number : List Char -> Res JSON
number cs0 =
  let (sign, cs1) = the (SnocList Char, List Char) $ case cs0 of
                      '-' :: r => ([< '-'], r)
                      _        => ([<], cs0)
      (int, cs2)  = digits sign cs1
   in if int == sign then Left ("expected a digit", cs1)
      else case cs1 of
        -- a leading zero stands alone
        '0' :: d :: _ => if isDigit d then Left ("a number cannot start with 0", cs1) else rest int cs2
        _             => rest int cs2
  where
    done : (isInt : Bool) -> SnocList Char -> List Char -> Res JSON
    done True  acc cs = Right (JInt (cast (pack (acc <>> []))), cs)
    done False acc cs = Right (JNum (cast (pack (acc <>> []))), cs)

    expo : (isInt : Bool) -> SnocList Char -> List Char -> Res JSON
    expo isInt acc (e :: cs) =
      if e == 'e' || e == 'E'
         then let (acc', cs') = the (SnocList Char, List Char) $ case cs of
                                  '+' :: r => (acc :< 'e', r)
                                  '-' :: r => (acc :< 'e' :< '-', r)
                                  _        => (acc :< 'e', cs)
                  (ds, cs'')  = digits acc' cs'
               in if ds == acc' then Left ("expected a digit in the exponent", cs') else done False ds cs''
         else done isInt acc (e :: cs)
    expo isInt acc [] = done isInt acc []

    rest : SnocList Char -> List Char -> Res JSON
    rest acc ('.' :: cs) =
      let (ds, cs') = digits (acc :< '.') cs
       in if ds == acc :< '.' then Left ("expected a digit after the point", cs) else expo False ds cs'
    rest acc cs = expo True acc cs

mutual
  value : (fuel : Nat) -> List Char -> Res JSON
  value Z     cs = Left ("too deeply nested", cs)
  value (S k) cs = case skip cs of
    '"' :: r => map (\(s, r') => (JString s, r')) (str [<] r)
    '{' :: r => case skip r of
      '}' :: r' => Right (JObject [], r')
      r'        => fields k [<] r'
    '[' :: r => case skip r of
      ']' :: r' => Right (JArray [], r')
      r'        => items k [<] r'
    't' :: 'r' :: 'u' :: 'e' :: r        => Right (JBool True, r)
    'f' :: 'a' :: 'l' :: 's' :: 'e' :: r => Right (JBool False, r)
    'n' :: 'u' :: 'l' :: 'l' :: r        => Right (JNull, r)
    c :: r => if c == '-' || isDigit c then number (c :: r) else Left ("unexpected character", c :: r)
    []     => Left ("unexpected end of input", [])

  items : (fuel : Nat) -> SnocList JSON -> List Char -> Res JSON
  items Z     acc cs = Left ("too deeply nested", cs)
  items (S k) acc cs = case value k cs of
    Left e        => Left e
    Right (v, r)  => case skip r of
      ',' :: r' => items k (acc :< v) r'
      ']' :: r' => Right (JArray (acc <>> [v]), r')
      r'        => Left ("expected , or ]", r')

  fields : (fuel : Nat) -> SnocList (String, JSON) -> List Char -> Res JSON
  fields Z     acc cs = Left ("too deeply nested", cs)
  fields (S k) acc cs = case skip cs of
    '"' :: r => case str [<] r of
      Left e         => Left e
      Right (key, r1) => case skip r1 of
        ':' :: r2 => case value k r2 of
          Left e        => Left e
          Right (v, r3) => case skip r3 of
            ',' :: r4 => fields k (acc :< (key, v)) r4
            '}' :: r4 => Right (JObject (acc <>> [(key, v)]), r4)
            r4        => Left ("expected , or }", r4)
        r2 => Left ("expected :", r2)
    r => Left ("expected a string key", r)

||| Read one JSON value, which must be the whole text.
export
parse : String -> Either ParseError JSON
parse s =
  let cs  = unpack s
      len = length cs
      bad : (String, List Char) -> ParseError
      bad (why, left) = MkParseError (len `minus` length left) why
   in case value (S len) cs of
        Left e        => Left (bad e)
        Right (v, r)  => case skip r of
          []   => Right v
          left => Left (bad ("unexpected text after the value", left))

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

public export
interface ToJSON a where
  toJSON : a -> JSON

export ToJSON JSON    where toJSON = id
export ToJSON String  where toJSON = JString
export ToJSON Bool    where toJSON = JBool
export ToJSON Integer where toJSON = JInt
export ToJSON Int     where toJSON = JInt . cast
export ToJSON Nat     where toJSON = JInt . cast
export ToJSON Double  where toJSON = JNum

export
ToJSON a => ToJSON (List a) where
  toJSON = JArray . map toJSON

export
ToJSON a => ToJSON (Maybe a) where
  toJSON = maybe JNull toJSON

||| One field of an object under construction.
export
field : ToJSON a => String -> a -> List (String, JSON)
field k v = [(k, toJSON v)]

||| A field that is left out when its value is `Nothing`.
export
optional : ToJSON a => String -> Maybe a -> List (String, JSON)
optional k = maybe [] (field k)

||| A field that is left out when its list is empty.
export
nonEmpty : ToJSON a => String -> List a -> List (String, JSON)
nonEmpty k [] = []
nonEmpty k xs = field k xs

||| An object from groups of fields: `objectOf [field "a" 1, optional "b" mb]`.
export
objectOf : List (List (String, JSON)) -> JSON
objectOf = JObject . concat

||| Keep the last value given for each key, at the place the key first appeared.
export
lastWins : List (String, JSON) -> List (String, JSON)
lastWins = go [<]
  where
    put : String -> JSON -> List (String, JSON) -> Maybe (List (String, JSON))
    put k v []             = Nothing
    put k v ((l, w) :: fs) = if k == l then Just ((k, v) :: fs) else ((l, w) ::) <$> put k v fs

    go : SnocList (String, JSON) -> List (String, JSON) -> List (String, JSON)
    go acc []             = acc <>> []
    go acc ((k, v) :: fs) = case put k v (acc <>> []) of
      Just acc' => go (cast acc') fs
      Nothing   => go (acc :< (k, v)) fs

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

||| The field of an object, or `JNull` when the value is not an object or has
||| no such field. Reads chain without a check at each step:
||| `asString (get "name" (get "function" call))`.
export
get : String -> JSON -> JSON
get k (JObject fs) = fromMaybe JNull (lookup k fs)
get k _            = JNull

||| `get` along a path of keys.
export
path : List String -> JSON -> JSON
path ks j = foldl (flip get) j ks

export
isNull : JSON -> Bool
isNull JNull = True
isNull _     = False

export
asString : JSON -> Maybe String
asString (JString s) = Just s
asString _           = Nothing

export
asBool : JSON -> Maybe Bool
asBool (JBool b) = Just b
asBool _         = Nothing

||| A whole number, whether it was written `3` or `3.0`.
export
asInteger : JSON -> Maybe Integer
asInteger (JInt n) = Just n
asInteger (JNum d) = let n = the Integer (cast d) in if cast n == d then Just n else Nothing
asInteger _        = Nothing

||| A whole number that is not negative.
export
asNat : JSON -> Maybe Nat
asNat j = asInteger j >>= \n => if n >= 0 then Just (cast n) else Nothing

export
asDouble : JSON -> Maybe Double
asDouble (JInt n) = Just (cast n)
asDouble (JNum d) = Just d
asDouble _        = Nothing

||| A number, or a string holding one: OpenRouter sends prices as `"0.0000015"`.
export
asAmount : JSON -> Maybe Double
asAmount (JString s) = case parse (trim s) of
  Right j => asDouble j
  Left _  => Nothing
asAmount j = asDouble j

||| The items of an array; none for any other value.
export
asList : JSON -> List JSON
asList (JArray xs) = xs
asList _           = []

||| The fields of an object; none for any other value.
export
asFields : JSON -> List (String, JSON)
asFields (JObject fs) = fs
asFields _            = []

||| The strings in an array. Other items are dropped.
export
asStrings : JSON -> List String
asStrings = mapMaybe asString . asList
