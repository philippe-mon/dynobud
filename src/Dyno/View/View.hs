{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE InstanceSigs #-}

module Dyno.View.View
       ( J(..), mkJ, unJ, unJ', View(..), JVec(..), JNone(..), S(..)
       , JV(..)
       , JTuple(..)
       , jreplicate, jreplicate'
       , reifyJVec, jfill
       ) where

import GHC.Generics hiding ( S )

import Data.Foldable ( Foldable )
import qualified Data.Foldable as F
import qualified Data.Sequence as Seq
import Data.Traversable ( Traversable )
import Data.Proxy ( Proxy(..) )
import Linear.V ( Dim(..) )
import Data.Vector ( Vector )
import qualified Data.Vector as V
import Data.Serialize ( Serialize(..) )

import Dyno.TypeVecs ( Vec(..), unVec, mkVec, mkVec', reifyVector )
import Dyno.View.Viewable ( Viewable(..) )
import Dyno.Vectorize ( Vectorize(..), vlength )
import Dyno.Server.Accessors ( Lookup(..), AccessorTree )

data JTuple f g a = JTuple (J f a) (J g a) deriving ( Generic, Show )
instance (View f, View g) => View (JTuple f g)
--instance View Id
--instance View Xy
--instance View Xyz
--instance View f => View (Fctr f)

newtype J (f :: * -> *) (a :: *) = UnsafeJ { unsafeUnJ :: a } deriving (Eq, Functor, Generic)


mkJ :: forall f a . (View f, Viewable a) => a -> J f a
mkJ x
  | nx == nx' = UnsafeJ x
  | otherwise = error $ "mkJ length mismatch: typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x

unJ :: forall f a . (View f, Viewable a) => J f a -> a
unJ (UnsafeJ x)
  | nx == nx' = x
  | otherwise = error $ "unJ length mismatch: typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x

unJ' :: forall f a . (View f, Viewable a) => String -> J f a -> a
unJ' msg (UnsafeJ x)
  | nx == nx' = x
  | otherwise = error $ "unJ length mismatch in \"" ++ msg ++ "\": typed size: " ++ show nx ++
                ", actual size: " ++ show nx'
  where
    nx = size (Proxy :: Proxy f)
    nx' = vsize1 x

instance Serialize a => Serialize (J f a)
instance Show a => Show (J f a) where
  showsPrec p (UnsafeJ x) = showsPrec p x
instance (Show a, Lookup a) => Lookup (J S (Vector a)) where
  toAccessorTree :: J S (Vector a) -> (b -> J S (Vector a)) -> AccessorTree b
  toAccessorTree (UnsafeJ x) f =
    toAccessorTree (V.head x) (V.head . unJ . f)

-- | vectors in View
newtype JVec n f a = JVec { unJVec :: Vec n (J f a) } deriving ( Show, Eq )
instance (Dim n, View f) => View (JVec n f) where
  cat = mkJ . vveccat . fmap unJ . unVec . unJVec
  split = JVec . fmap mkJ . mkVec . flip vvertsplit ks . unJ
    where
      ks = V.fromList (take (n+1) [0,m..])
      n = reflectDim (Proxy :: Proxy n)
      m = size (Proxy :: Proxy f)
  size = const (n * m)
    where
      n = reflectDim (Proxy :: Proxy n)
      m = size (Proxy :: Proxy f)
  sizes = const . Seq.iterateN n (+m) . (+ m)
    where
      n = reflectDim (Proxy :: Proxy n)
      m = size (Proxy :: Proxy f)
instance (Dim n, Serialize (J f a)) => Serialize (JVec n f a) where
  get = fmap (JVec . mkVec') get
  put = put . F.toList . unJVec

jreplicate' :: forall a n f . (Dim n, View f) => J f a -> JVec n f a
jreplicate' el =  ret
  where
    ret = JVec (mkVec (V.replicate nvec el))
    nvec = size (Proxy :: Proxy (JVec n S))

jreplicate :: forall a n f . (Dim n, View f, Viewable a) => J f a -> J (JVec n f) a
jreplicate = cat . jreplicate'

jfill :: forall a f . (View f, Show a) => a -> J f (Vector a)
jfill x = mkJ (V.replicate n x)
  where
    n = size (Proxy :: Proxy f)

reifyJVec :: forall a f r . Vector (J f a) -> (forall (n :: *). Dim n => JVec n f a -> r) -> r
reifyJVec v f = reifyVector v $ \(v' :: Vec n (J f a)) -> f (JVec v' :: JVec n f a)
{-# INLINE reifyJVec #-}

-- | view into a None, for convenience
data JNone a = JNone deriving ( Eq, Generic, Generic1, Show, Functor, Foldable, Traversable )
instance Vectorize JNone where
instance View JNone where

-- | view into a scalar, for convenience
newtype S a = S { unS :: a } deriving ( Eq, Num, Fractional, Floating, Generic, Generic1, Show, Functor, Foldable, Traversable )
instance View S where
  cat :: forall a . Viewable a => S a -> J S a
  cat (S x) = mkJ x
  size = const 1
  sizes = const . Seq.singleton . (1 +)
  split :: forall a . Viewable a => J S a -> S a
  split = S . unJ

instance (Vectorize f, Lookup (f a), Show a) => Lookup (J (JV f) (Vector a)) where
  toAccessorTree x g = toAccessorTree (devectorize (unJ x) :: f a) (devectorize . unJ . g)

newtype JV f a = JV { unJV :: f a } deriving Generic
instance Vectorize f => View (JV f) where
  cat :: forall a . Viewable a => JV f a -> J (JV f) a
  cat = mkJ . vveccat . vectorize . unJV
  size = const $ vlength (Proxy :: Proxy f)
  sizes = const . Seq.singleton . (vlength (Proxy :: Proxy f) +)
  split :: forall a . Viewable a => J (JV f) a -> JV f a
  split = JV . devectorize . flip vvertsplit ks. unJ
    where
      ks = V.fromList (take (n+1) [0..])
      n = size (Proxy :: Proxy (JV f))


-- | Type-save "views" into vectors, which can access subvectors
--   without splitting then concatenating everything.
class View f where
  cat :: Viewable a => f a -> J f a
  default cat :: (GCat (Rep (f a)) a, Generic (f a), Viewable a) => f a -> J f a
  cat = mkJ . vveccat . V.fromList . F.toList . gcat . from

  size :: Proxy f -> Int
  default size :: (GSize (Rep (f ())), Generic (f ())) => Proxy f -> Int
  size = gsize . reproxy
    where
      reproxy :: Proxy g -> Proxy ((Rep (g ())) p)
      reproxy = const Proxy

  sizes :: Int -> Proxy f -> Seq.Seq Int
  default sizes :: (GSize (Rep (f ())), Generic (f ())) => Int -> Proxy f -> Seq.Seq Int
  sizes k0 = gsizes k0 . reproxy
    where
      reproxy :: Proxy g -> Proxy ((Rep (g ())) p)
      reproxy = const Proxy

  split :: Viewable a => J f a -> f a
  default split :: (GBuild (Rep (f a)) a, Generic (f a), Viewable a) => J f a -> f a
  split x'
    | null leftovers = to ret
    | otherwise = error $ unlines
                  [ "split got " ++ show (length leftovers) ++ " leftover fields"
                  , "ns: " ++ show ns ++ "\n" ++ show (map vsize1 leftovers)
                  , "x: " ++ show x'
                  , "size1(x): " ++ show (vsize1 (unJ x'))
                  , "leftovers: " ++ show leftovers
                  , "errors: " ++ show (reverse errors)
                  ]
    where
      x = unJ x'
      (ret,leftovers,errors) = gbuild [] xs
      xs = V.toList $ vvertsplit x (V.fromList ns)
      ns :: [Int]
      ns = (0 :) $ F.toList $ sizes 0 (Proxy :: Proxy f)

------------------------------------ SIZE ------------------------------
class GSize f where
  gsize :: Proxy (f p) -> Int
  gsizes :: Int -> Proxy (f p) -> Seq.Seq Int

instance (GSize f, GSize g) => GSize (f :*: g) where
  gsize pxy = gsize px + gsize py
    where
      reproxy :: Proxy ((x :*: y) p) -> (Proxy (x p), Proxy (y p))
      reproxy = const (Proxy,Proxy)
      (px, py) = reproxy pxy
  gsizes k0 pxy = xs Seq.>< ys
    where
      xs = gsizes k0 px
      ys = gsizes k1 py
      k1 = case Seq.viewr xs of
        Seq.EmptyR -> k0
        _ Seq.:> k1' -> k1'

      reproxy :: Proxy ((x :*: y) p) -> (Proxy (x p), Proxy (y p))
      reproxy = const (Proxy,Proxy)
      (px, py) = reproxy pxy
instance GSize f => GSize (M1 i d f) where
  gsize = gsize . reproxy
    where
      reproxy :: Proxy (M1 i d f p) -> Proxy (f p)
      reproxy _ = Proxy
  gsizes k0 = gsizes k0 . reproxy
    where
      reproxy :: Proxy (M1 i d f p) -> Proxy (f p)
      reproxy _ = Proxy

instance View f => GSize (Rec0 (J f a)) where
  gsize = size . reproxy
    where
      reproxy :: Proxy (Rec0 (J f a) p) -> Proxy f
      reproxy _ = Proxy
  gsizes k0 = Seq.singleton . (k0 +) . size . reproxy
    where
      reproxy :: Proxy (Rec0 (J f a) p) -> Proxy f
      reproxy _ = Proxy

instance GSize U1 where
  gsize = const 0
  gsizes = const . Seq.singleton

----------------------------- CAT -------------------------------
class GCat f a where
  gcat :: f p -> Seq.Seq a

-- concatenate fields recursively
instance (GCat f a, GCat g a) => GCat (f :*: g) a where
  gcat (x :*: y) = x' Seq.>< y'
    where
      x' = gcat x
      y' = gcat y
-- discard the metadata
instance GCat f a => GCat (M1 i d f) a where
  gcat = gcat . unM1

-- any field should just hold a view, no recursion here
instance (View f, Viewable a) => GCat (Rec0 (J f a)) a where
  gcat (K1 x) = Seq.singleton (unJ x)

instance GCat U1 a where
  gcat U1 = Seq.empty

-------------------------
class GBuild f a where
  gbuild :: [String] -> [a] -> (f p, [a], [String])

-- split fields recursively
instance (GBuild f a, GBuild g a, GSize f, GSize g) => GBuild (f :*: g) a where
  gbuild errs0 xs0 = (x :*: y, xs2, errs2)
    where
      (x,xs1,errs1) = gbuild errs0 xs0
      (y,xs2,errs2) = gbuild errs1 xs1

instance (GBuild f a, Datatype d) => GBuild (D1 d f) a where
  gbuild :: forall p . [String] -> [a] -> (D1 d f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = moduleName ret ++ "." ++ datatypeName ret :: String
      ret = M1 x :: D1 d f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

instance (GBuild f a, Constructor c) => GBuild (C1 c f) a where
  gbuild :: forall p . [String] -> [a] -> (C1 c f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = conName ret :: String
      ret = M1 x :: C1 c f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

instance (GBuild f a, Selector s) => GBuild (S1 s f) a where
  gbuild :: forall p . [String] -> [a] -> (S1 s f p, [a], [String])
  gbuild errs0 xs0 = (ret, xs1, errs1)
    where
      err = selName ret :: String
      ret = M1 x :: S1 s f p
      (x,xs1,errs1) = gbuild (err:errs0) xs0

-- any field should just hold a view, no recursion here
instance (View f, Viewable a) => GBuild (Rec0 (J f a)) a where
  gbuild errs (x:xs) = (K1 (mkJ x), xs, errs)
  gbuild errs [] = error $ "GBuild (Rec0 (J f a)) a: empty list" ++ show (reverse errs)

instance Viewable a => GBuild U1 a where
  gbuild errs (x:xs)
    | vsize1 x /= 0 = error $ "GBuild U1: got non-empty element: " ++
                      show (vsize1 x) ++ "\n" ++ show (reverse errs)
    | otherwise = (U1, xs, errs)
  gbuild errs [] = error $ "GBuild U1: got empty" ++ show (reverse errs)
