{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE OverloadedStrings #-}

module LambdaTypes where

import qualified Parsing as P
import Parsing ((<|>))
import Data.Functor (($>))

data ApplicativeType b
    = Basic b
    | Application (ApplicativeType b) (ApplicativeType b)
    | TypeError

class Typed a b | a -> b where  -- items of haskell type a have basic types from b
    typ :: a -> ApplicativeType b

instance (Show b) => Show (ApplicativeType b) where
    show (Basic x) = show x
    show (Application a b) = "(" ++ show a ++ " -> " ++ show b ++ ")"
    show TypeError = "type_error"

instance (Eq b) => Eq (ApplicativeType b) where
    Basic x == Basic y = x == y
    Application x y == Application p q = x == p && y == q
    _ == _ = False

instance (P.Parseable b) => P.Parseable (ApplicativeType b) where
    parser = typeExprParser

typeExprParser :: (P.Parseable b) => P.Parser (ApplicativeType b)
typeExprParser = P.makeExprParser typeTermParser
    [ [ P.InfixR (P.operator "->" $> Application) ]
    ]

typeTermParser :: (P.Parseable b) => P.Parser (ApplicativeType b)
typeTermParser
    =   P.braces typeExprParser
    <|> (Basic <$> P.parser)