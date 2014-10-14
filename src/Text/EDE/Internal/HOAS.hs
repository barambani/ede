{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings    #-}

-- Module      : Text.EDE.Internal.HOAS
-- Copyright   : (c) 2013-2014 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Text.EDE.Internal.HOAS where

import           Control.Applicative
import           Control.Monad
import           Data.Aeson              hiding (Result, Success, Error)
import           Data.Scientific
import           Data.Text               (Text)
import qualified Data.Text.Lazy          as LText
import           Data.Text.Lazy.Builder
import           Text.EDE.Internal.Types

data Quoted
    = QLit !Value
    | QLam (Quoted -> Result Quoted)

instance Show Quoted where
    show (QLit v) = show v
    show _        = "<function>"

instance Eq Quoted where
    QLit a == QLit b = a == b
    _      == _      = False

typeOf :: Value -> String
typeOf = \case
    Null     -> "Null"
    Bool   _ -> "Bool"
    Number _ -> "Number"
    Object _ -> "Object"
    Array  _ -> "Array"
    String _ -> "String"

typeFun :: String
typeFun = "Function"

qapp :: Quoted -> Quoted -> Result Quoted
qapp a b = case (a, b) of
    (QLam f, x) -> f x
    (QLit x, _) -> throwError "unable to apply literal {} -> {}\n{}"
        [typeOf x, typeFun, show x]

bpoly :: Quote a => (Value -> Value -> a) -> Quoted
bpoly = quote

unum :: (Scientific -> Scientific) -> Quoted
unum = quote

bnum :: Quote a => (Scientific -> Scientific -> a) -> Quoted
bnum = quote

useq :: Quote a => (Text -> a) -> (Object -> a) -> (Array -> a) -> Quoted
useq f g h = QLam $ \case ->
    QLit (String t) -> pure . quote $ f t
    QLit (Object o) -> pure . quote $ g o
    QLit (Array  v) -> pure . quote $ h v
    QLit y          -> err (typeOf y)
    _               -> err typeFun
  where
    err = throwError "expected a String, Object, or Array, but got {}" . (:[])

class Quote a where
    quote :: a -> Quoted

instance Quote Quoted where
    quote = id

instance Quote Lit where
    quote = \case
        LBool b -> QLit (Bool b)
        LNum  n -> QLit (Number n)
        LText t -> QLit (String t)

instance Quote Value where
    quote = QLit

instance Quote Text where
    quote = QLit . String

instance Quote LText.Text where
    quote = quote . LText.toStrict

instance Quote Builder where
    quote = quote . toLazyText

instance Quote Bool where
    quote = QLit . Bool

instance Quote Int where
    quote = QLit . Number . fromIntegral

instance Quote Scientific where
    quote = QLit . Number

class Unquote a where
    unquote :: Quoted -> Result a

instance Unquote Value where
    unquote = \case
        QLit v -> pure v
        _      -> unexpected typeFun "Literal"

instance Unquote Text where
    unquote = unquote >=> \case
        String t -> pure t
        v        -> unexpected (typeOf v) "String"

instance Unquote LText.Text where
    unquote = fmap LText.fromStrict . unquote

instance Unquote Bool where
    unquote = unquote >=> \case
        Bool b -> pure b
        v      -> unexpected (typeOf v) "Bool"

instance Unquote Scientific where
    unquote = \case
        QLit (Number n) -> pure n
        QLit v          -> unexpected (typeOf v) "String"
        _               -> unexpected typeFun "String"

instance (Unquote a, Quote b) => Quote (a -> b) where
    quote f = QLam (fmap (quote . f) . unquote)

instance (Unquote a, Unquote b, Quote c) => Quote (a -> b -> c) where
    quote f = QLam $ \x ->
        pure . QLam $ \y ->
            \case
                QLam g -> join (qapp (quote f) <$> g x)
                _      -> quote <$> (f <$> unquote x <*> unquote y)

unexpected :: String -> String -> Result b
unexpected x y = throwError "unable to coerce {} -> {}" [x, y]
