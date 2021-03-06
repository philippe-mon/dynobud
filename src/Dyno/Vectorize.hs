{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}

module Dyno.Vectorize
       ( Vectorize(..)
       , None(..)
       , Id(..)
       , Tuple(..)
       , Triple(..)
       , vlength
       , vzipWith
       , vzipWith3
       , fill
       , GVectorize(..)
       , Generic1
       , Proxy(..)
       ) where


import GHC.Generics
import qualified Data.Vector as V
import Data.Foldable ( Foldable )
import Data.Traversable ( Traversable )
import Data.Proxy ( Proxy(..) )

import Dyno.Server.Accessors

-- | a length-0 vectorizable type
data None a = None
            deriving (Eq, Generic, Generic1, Functor, Foldable, Traversable, Show)
instance Vectorize None

-- | a length-1 vectorizable type
newtype Id a = Id a
             deriving (Eq, Generic, Generic1, Functor, Foldable, Traversable, Show)
instance Vectorize Id

-- | a length-2 vectorizable type
data Tuple f g a = Tuple (f a) (g a)
                 deriving (Eq, Generic, Generic1, Functor, Foldable, Traversable, Show)
instance (Vectorize f, Vectorize g) => Vectorize (Tuple f g)

-- | a length-3 vectorizable type
data Triple f g h a = Triple (f a) (g a) (h a)
                    deriving (Eq, Generic, Generic1, Functor, Foldable, Traversable, Show)
instance (Vectorize f, Vectorize g, Vectorize h) => Vectorize (Triple f g h)

instance Lookup (None a)
instance (Lookup a, Generic a) => Lookup (Id a)
instance (Lookup (f a), Generic (f a),
          Lookup (g a), Generic (g a)) => Lookup (Tuple f g a)
instance (Lookup (f a), Generic (f a),
          Lookup (g a), Generic (g a),
          Lookup (h a), Generic (h a)) => Lookup (Triple f g h a)

fill :: Vectorize f => a -> f a
fill x = fmap (const x) empty

-- | fmap f == devectorize . (V.map f) . vectorize
class Functor f => Vectorize (f :: * -> *) where
  vectorize :: f a -> V.Vector a
  devectorize :: V.Vector a -> f a
  empty :: f ()

  default vectorize :: (Generic1 f, GVectorize (Rep1 f)) => f a -> V.Vector a
  vectorize f = gvectorize (from1 f)

  default devectorize :: (Generic1 f, GVectorize (Rep1 f)) => V.Vector a -> f a
  devectorize f = to1 (gdevectorize f)

  default empty :: (Generic1 f, GVectorize (Rep1 f)) => f ()
  empty = to1 gempty

--vlength :: Vectorize f => Proxy f -> Int
--vlength = const (gvlength (Proxy :: Proxy (Rep1 f)))

vlength :: Vectorize f => Proxy f -> Int
vlength = V.length . vectorize . (empty `asFunctorOf`)
  where
    asFunctorOf :: f a -> Proxy f -> f a
    asFunctorOf x _ = x

class GVectorize (f :: * -> *) where
  gvectorize :: f a -> V.Vector a
  gdevectorize :: V.Vector a -> f a
  gempty :: f ()
  gvlength :: Proxy f -> Int

vzipWith :: Vectorize f => (a -> b -> c) -> f a -> f b -> f c
vzipWith f x y = devectorize $ V.zipWith f (vectorize x) (vectorize y)

vzipWith3 :: Vectorize f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
vzipWith3 f x y z = devectorize $ V.zipWith3 f (vectorize x) (vectorize y) (vectorize z)

-- product type (concatination)
instance (GVectorize f, GVectorize g) => GVectorize (f :*: g) where
  gvectorize (f :*: g) = gvectorize f V.++ gvectorize g
  gdevectorize v0s
    | V.length v0s < n0 =
      error $ "gdevectorize (f :*: g): V.length v0s < vlength f0  (" ++
              show (V.length v0s) ++ " < " ++ show n0 ++ ")"
    | V.length v1 /= n1 =
      error $ "gdevectorize (f :*: g): V.length v1 /= vlength f1  (" ++
               show (V.length v1) ++ " /= " ++ show n1 ++ ")"
    | otherwise = f0 :*: f1
    where
      f0 = gdevectorize v0
      f1 = gdevectorize v1

      n0 = gvlength (Proxy :: Proxy f)
      n1 = gvlength (Proxy :: Proxy g)

      (v0,v1) = V.splitAt n0 v0s

  gempty = gempty :*: gempty
  gvlength = const (nf + ng)
    where
      nf = gvlength (Proxy :: Proxy f)
      ng = gvlength (Proxy :: Proxy g)

-- Metadata (constructor name, etc)
instance GVectorize f => GVectorize (M1 i c f) where
  gvectorize = gvectorize . unM1
  gdevectorize = M1 . gdevectorize
  gempty = M1 gempty
  gvlength = gvlength . proxy
    where
      proxy :: Proxy (M1 i c f) -> Proxy f
      proxy = const Proxy

-- singleton
instance GVectorize Par1 where
  gvectorize = V.singleton . unPar1
  gdevectorize v = case V.toList v of
    [] -> error "gdevectorize Par1: got empty list"
    [x] -> Par1 x
    xs -> error $ "gdevectorize Par1: got non-1 length: " ++ show (length xs)
  gempty = Par1 ()
  gvlength = const 1

-- data with no fields
instance GVectorize U1 where
  gvectorize = const V.empty
  gdevectorize v
    | V.null v = U1
    | otherwise = error $ "gdevectorize U1: got non-null vector, length: " ++ show (V.length v)
  gempty = U1
  gvlength = const 0

-- Constants, additional parameters, and rank-1 recursion
instance Vectorize f => GVectorize (Rec1 f) where
  gvectorize = vectorize . unRec1
  gdevectorize = Rec1 . devectorize
  gempty = Rec1 empty
  gvlength = vlength . proxy
    where
      proxy :: Proxy (Rec1 f) -> Proxy f
      proxy = const Proxy

-- composition
instance (Vectorize f, GVectorize g) => GVectorize (f :.: g) where
  gempty = Comp1 (devectorize (V.replicate k gempty))
    where
      k = vlength (Proxy :: Proxy f)
  gvectorize = V.concatMap gvectorize . vectorize . unComp1
  gdevectorize v = Comp1 (devectorize vs)
    where
      kf = vlength (Proxy :: Proxy f)
      kg = gvlength (Proxy :: Proxy g)

      -- vs :: V.Vector (g a)
      vs = fmap gdevectorize (splitsAt kg kf v {-:: Vec nf (Vec ng a)-} )
  gvlength = const (nf * ng)
    where
      nf = vlength (Proxy :: Proxy f)
      ng = gvlength (Proxy :: Proxy g)

-- break a vector jOuter vectors, each of length kInner
splitsAt' :: Int -> Int -> V.Vector a -> [V.Vector a]
splitsAt' 0 jOuter v
  | V.null v = replicate jOuter V.empty
  | otherwise = error $ "splitsAt 0 " ++ show jOuter ++ ": got non-zero vector"
splitsAt' kInner 0 v
  | V.null v = []
  | otherwise = error $ "splitsAt " ++ show kInner ++ " 0: leftover vector of length: " ++ show (V.length v)
splitsAt' kInner jOuter v
  | kv0 < kInner =
    error $ "splitsAt " ++ show kInner ++ " " ++ show jOuter ++ ": " ++ "ran out of vector input"
  | otherwise = v0 : splitsAt' kInner (jOuter - 1) v1
  where
    kv0 = V.length v0
    (v0,v1) = V.splitAt kInner v

-- break a vector jOuter vectors, each of length kInner
splitsAt :: Int -> Int -> V.Vector a -> V.Vector (V.Vector a)
splitsAt k j = V.fromList . splitsAt' k j
