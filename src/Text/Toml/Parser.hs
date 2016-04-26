{-# LANGUAGE OverloadedStrings #-}
module Text.Toml.Parser
    ( parseToml
    ) where

import Text.Toml.Combinators
import Text.Toml.Tokenizer
import Text.Toml.Types.Toml

import Control.Monad ((<=<))
import Data.Bifunctor (first)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import Data.List (foldl')
import Data.Time.LocalTime
import Text.Parsec

-- Internal types for converting from parsed data to final Toml datatype
type SectionKey = [Text]
data Section = ObjSection SectionKey [(Text, TNamable)]
             | ArraySection SectionKey [(Text, TNamable)]

firstDup :: Ord a => [a] -> Maybe a
firstDup xs = dup xs Set.empty
  where dup [] _ = Nothing
        dup (a:as) s = if Set.member a s
                       then Just a
                       else dup as (Set.insert a s)

parseToml :: String -> Text -> Either String Toml
parseToml src = first show . parse parser src <=< tokenize

mergeSection :: Section -> Toml -> Toml
mergeSection (ObjSection key lst) t = insertChildren key lst t
mergeSection (ArraySection key lst) t = appendChildren key lst t

parser :: Parser Toml
parser = do (intro, rest) <- sections <* eof
            case firstDup (map fst intro) of
               Just x -> unexpected $ "duplicate " ++ (T.unpack x)
               Nothing ->
                  case firstDup (map skey rest) of
                     Just x -> unexpected $ "duplicate section " ++ (T.unpack (T.intercalate "." x))
                     Nothing -> return $ foldr mergeSection (fromList intro) rest

skey :: Section -> SectionKey
skey (ObjSection k _) = k
skey (ArraySection k _) = k

sections :: Parser ([(Text, TNamable)], [Section])
sections = (,) <$> many assignment <*> many section

sectionKey :: Parser SectionKey
sectionKey = (choice [identifier, quoted]) `sepBy1` period

section :: Parser Section
section = ArraySection <$> (try $ doubleBracketed sectionKey) <*> many assignment
      <|> ObjSection   <$> (bracketed sectionKey)       <*> many assignment

assignment :: Parser (Text, TNamable)
assignment = (,) <$> ((identifier <|> quoted) <* equal) <*> value

value :: Parser TNamable
value = choice
    [ array
    , TBoolean <$> bool
    , TString <$> quoted
    , TInteger . fromIntegral <$> integer
    , TDouble <$> float
    , TDatetime . zonedTimeToUTC <$> date
    , TDatetime . localTimeToUTC tz <$> localDate
    ] <?> "value"

  where
    tz :: TimeZone
    tz = error "required IO poses a small problem..."

allSame, allArray, allBoolean, allInteger, allString, allDouble, allDatetime :: [TNamable] -> Bool
allSame [] = True
allSame ((TArray{}):xs) = allArray xs
allSame ((TBoolean{}):xs) = allBoolean xs
allSame ((TString{}):xs) = allString xs
allSame ((TInteger{}):xs) = allInteger xs
allSame ((TDouble{}):xs) = allDouble xs
allSame ((TDatetime{}):xs) = allDatetime xs

allArray [] = True
allArray ((TArray{}):as) = allArray as
allArray _ = False

allBoolean [] = True
allBoolean ((TBoolean{}):as) = allBoolean as
allBoolean _ = False

allInteger [] = True
allInteger ((TInteger{}):as) = allInteger as
allInteger _ = False

allString [] = True
allString ((TString{}):as) = allString as
allString _ = False

allDouble [] = True
allDouble ((TDouble{}):as) = allDouble as
allDouble _ = False

allDatetime [] = True
allDatetime ((TDatetime{}):as) = allDatetime as
allDatetime _ = False

array :: Parser TNamable
array = do elms <- p
           if not $ allSame elms
           then unexpected "Types do not match"
           else return $ TArray Inline elms
    where p = between lbracket rbracket (try (endBy value comma) <|> sepBy value comma)

