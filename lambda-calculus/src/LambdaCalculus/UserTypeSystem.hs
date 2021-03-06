{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module LambdaCalculus.UserTypeSystem where

import qualified Data.Text as Text
import           GHC.Generics (Generic)
import           Data.Hashable (Hashable, hashWithSalt)
import           Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HM
import           Utils.Exception (throw, Exception)
import           Data.Dynamic (Typeable)
import           Data.MemoCombinators.Class (MemoTable, table)
import           Data.MemoCombinators (Memo, memo2)
import           Data.Aeson (ToJSON(..), object, (.=))

import           LambdaCalculus.LambdaTypes (ApplicativeType(..), TypeException(..), Typed(..))
import           LambdaCalculus.Lambda (LambdaTerm)
import qualified LambdaCalculus.Lambda as L
import           LambdaCalculus.LambdaTypes (Name)
import qualified LambdaCalculus.LambdaTypes as T
import           Utils.Maths
import qualified Utils.Parsing as P

import           Utils.Resolver

import           Utils.Latex
import           Utils.Memoise ()

-- The following types define a wrapping typesystem which extends the
-- given typesystem `b`. The new types have simple text names and extend
-- respective applicative types from the typesystem `b`.

newtype ConstWrapper a = ConstWrapper a deriving (Generic)

instance (Typed c t, Eq t, PartialOrd t, MLattice (ApplicativeType t)) => Typed (ConstWrapper c) (TypeWrapper t) where
    typeOf (ConstWrapper x) = Type <$> typeOf x

deriving instance (Eq a) => Eq (ConstWrapper a)
instance (Show a) => Show (ConstWrapper a) where
    show (ConstWrapper a) = show a

deriving instance (Hashable a) => Hashable (ConstWrapper a)

data TypeWrapper b
    = Type    b
    | SubType Name (AppTypeWrapper b)
    deriving (Generic)

type AppTypeWrapper b = ApplicativeType (TypeWrapper b)

instance Eq b => Eq (TypeWrapper b) where
    (Type x)      == (Type y)      = x == y
    (SubType p _) == (SubType q _) = p == q
    _             == _             = False

instance forall b. (Hashable b) => Hashable (TypeWrapper b) where
    hashWithSalt salt (Type x)         = hashWithSalt salt (Left x     :: Either b Name)
    hashWithSalt salt (SubType name _) = hashWithSalt salt (Right name :: Either b Name)

instance (Eq b, PartialOrd b) => PartialOrd (ApplicativeType (TypeWrapper b)) where
    (<!) (Basic (Type x)) (Basic (Type y))   = x <! y
    (<!) (Application a b) (Application c d) = ((<!) a c) && ((<!) b d)
    (<!) (Basic (SubType x pa)) (r @ (Basic (SubType y _)))
        | x == y = True
        | otherwise = (<!) pa r
    (<!) (Basic (SubType _ pa)) (r @ (Basic (Type  _))) = (<!) pa r
    (<!) (Basic (SubType _ pa)) (r @ (Application _ _)) = (<!) pa r
    (<!) Wildcard    Wildcard          = True
    (<!) Wildcard    _                 = True
    (<!) _      Wildcard               = True
    (<!) _      _                      = False


instance (Show b, Eq b, Typeable b, PartialOrd b, MLattice (ApplicativeType b)) => MSemiLattice (ApplicativeType (TypeWrapper b)) where
    (/\) (Basic (Type x)) (Basic (Type y)) = Type <$> (Basic x) /\ (Basic y)
    (/\) (Application a b) (Application c d) = Application (a \/ c) (b /\ d)
    (/\) Wildcard x = x
    (/\) x Wildcard = x
    (/\) x y
        | x <! y = x
        | x !> y = y
        | otherwise    = throw $ CannotMeet x y

instance (Show b, Eq b, Typeable b, PartialOrd b, MLattice (ApplicativeType b)) => MLattice (ApplicativeType (TypeWrapper b)) where
    (\/) (Basic (Type x)) (Basic (Type y)) = Type <$> (Basic x) \/ (Basic y)
    (\/) (Application a b) (Application c d) = Application (a /\ c) (b \/ d)
    (\/) Wildcard x = x
    (\/) x Wildcard = x
    (\/) x y
        | x <! y = y
        | x !> y = x
        | otherwise    = throw $ CannotJoin x y

wrap :: (Eq t, PartialOrd t, MLattice (ApplicativeType t), Typed c t) => LambdaTerm t c -> LambdaTerm (TypeWrapper t) (ConstWrapper c)
wrap = L.transformConst wrapConst wrapType

unwrap :: (Eq t, PartialOrd t, MLattice (ApplicativeType t), Typed c t) => LambdaTerm (TypeWrapper t) (ConstWrapper c) -> LambdaTerm t c
unwrap = L.removeUselessCasts . (L.transformConst unwrapConst unwrapType)

wrapConst :: c -> ConstWrapper c
wrapConst = ConstWrapper

unwrapConst :: ConstWrapper c -> c
unwrapConst (ConstWrapper x) = x

wrapType :: t -> AppTypeWrapper t
wrapType = Basic . Type

wrapType' :: ApplicativeType t -> AppTypeWrapper t
wrapType' = T.transform wrapType

unwrapType :: TypeWrapper t -> ApplicativeType t
unwrapType (Type x) = Basic x
unwrapType (SubType _ parent) = T.transform unwrapType parent

unwrapType' :: AppTypeWrapper t -> ApplicativeType t
unwrapType' = T.transform unwrapType

-- parsing helpers
data SubtypeAssertion t = SubtypeAssertion T.Name (T.UnresolvedType t)

deriving instance (Show t) => Show (SubtypeAssertion t)
deriving instance (Eq t) => Eq (SubtypeAssertion t)

instance (P.Parseable t) => P.Parseable (SubtypeAssertion t) where
    parser = P.try $ do
        name    <- P.identifier
        _       <- P.operator "<"
        supType <- P.parser
        _       <- P.operator "."
        pure $ SubtypeAssertion name supType

type TypeWrappers t = HashMap T.Name (AppTypeWrapper t)

resolveTypeLibrary :: (Typeable t) => [SubtypeAssertion t] -> TypeWrappers t
resolveTypeLibrary = (resolveLibrary TWR)
    . (map (\(SubtypeAssertion x y) -> (x, y)))

resolveType :: (Typeable t) => TypeWrappers t -> T.UnresolvedType t -> AppTypeWrapper t
resolveType = resolveItem TWR

resolveBasicType :: (Typeable t) => TypeWrappers t -> T.Ref t -> AppTypeWrapper t
resolveBasicType m = (resolveType m) . T.Basic

data TWR t = TWR deriving (Show, Typeable) -- term wrapper resolver
instance (Typeable t) => Resolvable  (TWR t) where
    type Resolvee    (TWR t) = T.UnresolvedType t
    type ResolveKey  (TWR t) = T.Name
    type Resolved    (TWR t) = AppTypeWrapper t

    fv TWR = T.unresolvedNames
    substituteAll TWR m = T.transform resolveRef
        where
            resolveRef (T.BasicRef x) = Basic $ Type x
            resolveRef (T.UnresolvedName pos name)
                | (Just t) <- HM.lookup name m = t
                | otherwise = throw $ NoSuchType pos name

    preprocess TWR name t = Basic $ SubType name t

-- memo instances
instance (MemoTable t) => MemoTable (TypeWrapper t) where
    table = mkmemo (table :: Memo t) (table :: Memo (AppTypeWrapper t))
        where
            mkmemo :: forall t' b.
                      (forall a. (t'               -> a) -> (t'               -> a))
                   -> (forall a. ((AppTypeWrapper t') -> a) -> ((AppTypeWrapper t') -> a))
                   -> (TypeWrapper t' -> b)
                   -> (TypeWrapper t' -> b)
            mkmemo mt _   f (Type      x) = mt (f . Type) x
            mkmemo _  mwt f (SubType x y) = memo2 mname mwt (\a b -> f $ SubType a b) x y
                where
                    mname = table :: Memo Name

-- shows and latexes
instance (Latexable b) => Latexable (TypeWrapper b) where
    latex (Type b) = latex b
    latex (SubType name _) = name

instance (Show b) => Show (TypeWrapper b) where
    show (Type b) = show b
    show (SubType name _) = Text.unpack name

-- exceptions
data SubtypeException
    = NoSuchType P.SourcePos T.Name
    deriving (Typeable, Exception, Show)

-- JSON stuff
instance (ToJSON b) => ToJSON (TypeWrapper b) where
    toJSON (Type b)         = object ["_t" .= ("basic_type" :: String), "type" .= b]
    toJSON (SubType name t) = object ["_t" .= ("subtype" :: String),    "name" .= name, "parent" .= t]

deriving instance (ToJSON c) => ToJSON (ConstWrapper c)
