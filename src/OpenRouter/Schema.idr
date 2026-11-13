||| Typed JSON Schemas.
|||
||| A `Schema a` is two things at once: the JSON Schema to send to a model,
||| and a decoder that turns the model's JSON into an `a`. Since both come
||| from one description, the shape asked for and the type read back cannot
||| drift apart.
|||
||| ```idris
||| forecast : Schema (HList [String, Double, Maybe String])
||| forecast = object
|||   [ prop "city" string
|||   , prop "celsius" number
|||   , prop "advice" (nullable string)
|||   ]
||| ```
module OpenRouter.Schema

import public Data.List.Quantifiers
import Data.String
import OpenRouter.JSON

%default total

mutual
  public export
  data Schema : Type -> Type where
    SString   : Schema String
    SInteger  : Schema Integer
    SNumber   : Schema Double
    SBool     : Schema Bool
    ||| One of the listed strings.
    SEnum     : (allowed : List String) -> Schema String
    SArray    : Schema a -> Schema (List a)
    ||| The value or `null`. As an object property it may also be left out.
    SNullable : Schema a -> Schema (Maybe a)
    SObject   : Props ts -> Schema (HList ts)
    ||| A description for the model to read.
    SDescribe : String -> Schema a -> Schema a
    ||| Read a value, then convert or reject it. The schema sent is unchanged.
    SRefine   : (a -> Either String b) -> Schema a -> Schema b
    ||| Any JSON at all, under the given JSON Schema.
    SRaw      : JSON -> Schema JSON

  ||| The properties of an object, with the type of each.
  public export
  data Props : List Type -> Type where
    Nil  : Props []
    (::) : (String, Schema t) -> Props ts -> Props (t :: ts)

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

public export %inline
string : Schema String
string = SString

public export %inline
integer : Schema Integer
integer = SInteger

public export %inline
number : Schema Double
number = SNumber

public export %inline
boolean : Schema Bool
boolean = SBool

public export %inline
enum : List String -> Schema String
enum = SEnum

public export %inline
array : Schema a -> Schema (List a)
array = SArray

public export %inline
nullable : Schema a -> Schema (Maybe a)
nullable = SNullable

public export %inline
object : Props ts -> Schema (HList ts)
object = SObject

||| One property of an object: its name and what it holds.
public export %inline
prop : String -> Schema t -> (String, Schema t)
prop = MkPair

||| Attach a description: ``string `describe` "An IATA airport code"``.
public export %inline
describe : Schema a -> String -> Schema a
describe s d = SDescribe d s

||| Convert what was read, or reject it with a reason.
public export %inline
refine : (a -> Either String b) -> Schema a -> Schema b
refine = SRefine

||| A whole number that is not negative.
public export
natural : Schema Nat
natural = refine (\n => if n >= 0 then Right (cast n) else Left "expected a number that is not negative") SInteger

export
Functor Schema where
  map f = SRefine (Right . f)

--------------------------------------------------------------------------------
-- The JSON Schema
--------------------------------------------------------------------------------

typed : String -> JSON
typed t = JObject [("type", JString t)]

-- Allow null as well. A plain {"type": "x", ...} gets a second type; anything
-- else is wrapped.
orNull : JSON -> JSON
orNull (JObject (("type", JString t) :: fs)) =
  case lookup "enum" fs of
    Just (JArray xs) => JObject (("type", JArray [JString t, JString "null"])
                          :: map (\(k, v) => if k == "enum" then (k, JArray (xs ++ [JNull])) else (k, v)) fs)
    _                => JObject (("type", JArray [JString t, JString "null"]) :: fs)
orNull j = JObject [("anyOf", JArray [j, typed "null"])]

withDescription : String -> JSON -> JSON
withDescription d (JObject fs) = JObject (filter ((/= "description") . fst) fs ++ [("description", JString d)])
withDescription d j            = j

mutual
  ||| The JSON Schema a model is given. Objects list every property as
  ||| required and allow no others, which is what strict structured output
  ||| asks for; a property that may be absent is written `nullable`.
  export
  jsonSchema : Schema a -> JSON
  jsonSchema SString         = typed "string"
  jsonSchema SInteger        = typed "integer"
  jsonSchema SNumber         = typed "number"
  jsonSchema SBool           = typed "boolean"
  jsonSchema (SEnum xs)      = JObject [("type", JString "string"), ("enum", JArray (map JString xs))]
  jsonSchema (SArray s)      = JObject [("type", JString "array"), ("items", jsonSchema s)]
  jsonSchema (SNullable s)   = orNull (jsonSchema s)
  jsonSchema (SObject ps)    =
    JObject [ ("type", JString "object")
            , ("properties", JObject (propSchemas ps))
            , ("required", JArray (map JString (propNames ps)))
            , ("additionalProperties", JBool False) ]
  jsonSchema (SDescribe d s) = withDescription d (jsonSchema s)
  jsonSchema (SRefine _ s)   = jsonSchema s
  jsonSchema (SRaw j)        = j

  propSchemas : Props ts -> List (String, JSON)
  propSchemas []               = []
  propSchemas ((k, s) :: rest) = (k, jsonSchema s) :: propSchemas rest

  propNames : Props ts -> List String
  propNames []               = []
  propNames ((k, _) :: rest) = k :: propNames rest

--------------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------------

||| Why a value did not fit a schema, and where: `$.days[2].high`.
public export
record Mismatch where
  constructor MkMismatch
  location : String
  reason   : String

export
Show Mismatch where
  show m = m.location ++ ": " ++ m.reason

kind : JSON -> String
kind JNull       = "null"
kind (JBool _)   = "a boolean"
kind (JInt _)    = "an integer"
kind (JNum _)    = "a number"
kind (JString _) = "a string"
kind (JArray _)  = "an array"
kind (JObject _) = "an object"

wrong : (at : String) -> (wanted : String) -> JSON -> Either Mismatch a
wrong at wanted j = Left (MkMismatch at ("expected " ++ wanted ++ ", found " ++ kind j))

mutual
  decodeAt : (at : String) -> Schema a -> JSON -> Either Mismatch a
  decodeAt at SString (JString s) = Right s
  decodeAt at SString j           = wrong at "a string" j
  decodeAt at SInteger j          = maybe (wrong at "an integer" j) Right (asInteger j)
  decodeAt at SNumber j           = maybe (wrong at "a number" j) Right (asDouble j)
  decodeAt at SBool (JBool b)     = Right b
  decodeAt at SBool j             = wrong at "a boolean" j
  decodeAt at (SEnum xs) (JString s) =
    if elem s xs then Right s
    else Left (MkMismatch at (quote s ++ " is not one of " ++ joinBy ", " (map quote xs)))
  decodeAt at (SEnum xs) j        = wrong at "a string" j
  decodeAt at (SArray s) (JArray xs) = decodeItems at 0 s xs
  decodeAt at (SArray s) j        = wrong at "an array" j
  decodeAt at (SNullable s) JNull = Right Nothing
  decodeAt at (SNullable s) j     = Just <$> decodeAt at s j
  decodeAt at (SObject ps) (JObject fs) = decodeProps at ps fs
  decodeAt at (SObject ps) j      = wrong at "an object" j
  decodeAt at (SDescribe _ s) j   = decodeAt at s j
  decodeAt at (SRefine f s) j     = decodeAt at s j >>= \x => mapFst (MkMismatch at) (f x)
  decodeAt at (SRaw _) j          = Right j

  decodeItems : String -> Nat -> Schema a -> List JSON -> Either Mismatch (List a)
  decodeItems at i s []        = Right []
  decodeItems at i s (x :: xs) =
    [| decodeAt (at ++ "[" ++ show i ++ "]") s x :: decodeItems at (S i) s xs |]

  decodeProps : String -> Props ts -> List (String, JSON) -> Either Mismatch (HList ts)
  decodeProps at []               fs = Right []
  decodeProps at ((k, s) :: rest) fs =
    let here = at ++ "." ++ k
        mine = case lookup k fs of
                 Just j  => decodeAt here s j
                 Nothing => case decodeAt here s JNull of   -- only a nullable property may be absent
                   Right v => Right v
                   Left _  => Left (MkMismatch here "missing")
     in [| mine :: decodeProps at rest fs |]

||| Read a JSON value by a schema.
export
decode : Schema a -> JSON -> Either Mismatch a
decode = decodeAt "$"

||| Read JSON text by a schema.
export
decodeText : Schema a -> String -> Either Mismatch a
decodeText s text = case parse text of
  Left e  => Left (MkMismatch "$" ("not JSON: " ++ show e))
  Right j => decode s j
