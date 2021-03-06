{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveAnyClass        #-}

module Minipass.Language.Language where

import Data.Functor (($>))

import Utils.Parsing as P
import Utils.Maths
import GHC.Generics (Generic)
import Data.Hashable (Hashable)

import           Data.Aeson (ToJSON(..))
import           Data.MemoCombinators.Class (MemoTable, table)
import qualified Data.MemoCombinators as Memo

import qualified LambdaCalculus.LambdaTypes as T
import           LambdaCalculus.LambdaTypes (Typed)
import           LambdaCalculus.Lambda

import Data.Text (Text, pack)
import Utils.Latex

import Minipass.Language.Constants

data Types
    = GSet
    | String
    | Num
    | List
    | Anything
    deriving (Show, Eq, Generic, Enum)

deriving instance Hashable Types

instance PartialOrd Types where
    a <! b = a == b

instance PartialOrd (T.ApplicativeType Types) where
    (<!) = T.defaultLess

instance MSemiLattice (T.ApplicativeType Types) where
    (/\) = T.defaultPartialMeet

instance MLattice (T.ApplicativeType Types) where
    (\/) = T.defaultPartialJoin

instance P.Parseable Types where
    parser = P.word
        $   P.string "GSet"      $> GSet
        <|> P.string "String"   $> String
        <|> P.string "Num"      $> Num

type Term = LambdaTerm Types Constants

pts :: String -> Term
pts = pss

instance Typed Constants Types where
    typeOf (StringLiteral _) = T.Basic String
    typeOf (NumLiteral    _) = T.Basic Num

    typeOf Next              = T.Application (T.Basic List) (T.Application (T.Basic GSet) (T.Basic GSet))
    typeOf Get               = T.Application (T.Basic List) (T.Basic GSet)

    typeOf Or                = T.Application (T.Basic GSet) (T.Application (T.Basic GSet) (T.Basic GSet))
    typeOf And               = T.Application (T.Basic GSet) (T.Application (T.Basic GSet) (T.Basic GSet))
    typeOf Not               = T.Application (T.Basic GSet) (T.Basic GSet)

    typeOf ConsNum           = T.Application (T.Basic Num) (T.Application (T.Basic List) (T.Basic List))
    typeOf ConsString        = T.Application (T.Basic String) (T.Application (T.Basic List) (T.Basic List))
    typeOf ConsList          = T.Application (T.Basic List) (T.Application (T.Basic List) (T.Basic List))
    typeOf Empty             = T.Basic List

-- memo instances
instance MemoTable Types where
    table = Memo.enum

-- convenience for creating lists
data ListC
    = NumC      Float
    | StringC   Text
    | ListC     [ListC]
    deriving (Show)

listTerm :: [ListC] -> Term
listTerm []             = Constant Empty
listTerm (NumC n:xs)    = Application (Application (Constant ConsNum) (Constant $ NumLiteral n)) $ listTerm xs
listTerm (StringC n:xs) = Application (Application (Constant ConsString) (Constant $ StringLiteral n)) $ listTerm xs
listTerm (ListC n:xs)   = Application (Application (Constant ConsList) (listTerm n)) $ listTerm xs


instance Latexable Types where
    latex = pack . show

instance ToJSON Types where
    toJSON = toJSON . show
