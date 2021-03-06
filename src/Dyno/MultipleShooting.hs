{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language DeriveFunctor #-}
{-# Language DeriveGeneric #-}
{-# Language RankNTypes #-}

module Dyno.MultipleShooting
       ( MsTraj(..)
       , MsPoint(..)
       , MsConstraints(..)
       , MsOcp(..)
       , makeNlp
       ) where

import qualified Data.Vector as V
import Linear.Metric ( dot )
import Linear.V ( Dim )

import Dyno.TypeVecs ( Vec )
import qualified Dyno.TypeVecs as TV
import Dyno.Vectorize
import Dyno.Nlp

data MsOcp x u c h =
  MsOcp { msMayer :: forall a. Floating a => x a -> V.Vector a
        , msLagrange :: forall a. Floating a => x a -> u a -> V.Vector a
        , msDae :: forall a. Floating a => x a -> u a -> x a
        , msBc :: forall a. Floating a => x a -> x a -> c a
        , msPathC :: forall a. Floating a => x a -> u a -> h a
        , msPathCBnds :: h (Maybe Double, Maybe Double)
        , msXbnd :: x (Maybe Double, Maybe Double)
        , msUbnd :: u (Maybe Double, Maybe Double)
        , msT :: Double
        }

-- multiple shooting
data MsPoint x u a = MsPoint (x a) (u a) deriving (Functor, Generic1)
instance (Vectorize x, Vectorize u) => Vectorize (MsPoint x u)
data MsTraj x u n a = MsTraj (Vec n (MsPoint x u a)) (x a) deriving (Functor, Generic1)
instance (Vectorize x, Vectorize u, Dim n) => Vectorize (MsTraj x u n)

data MsConstraints x n c h a =
  MsConstraints
  { mscBc :: c a
  , mscPathc :: Vec n (h a)
  , mscDynamics :: Vec n (x a)
  } deriving (Functor, Generic1, Show)

instance (Vectorize x, Vectorize c, Vectorize h, Dim n) =>
         Vectorize (MsConstraints x n c h)

getDvBnds ::
  forall x u c h n . (Dim n) =>
  MsOcp x u c h -> MsTraj x u n (Maybe Double, Maybe Double)
getDvBnds ocp = MsTraj xus x
  where
    xus = fill (MsPoint (msXbnd ocp) (msUbnd ocp))
    x = msXbnd ocp

getGBnds ::
  (Vectorize x, Vectorize c, Dim n) =>
  MsOcp x u c h ->
  MsConstraints x n c h (Maybe Double, Maybe Double)
getGBnds ocp =
  MsConstraints
  { mscBc = fill (Just 0, Just 0)
  , mscPathc = fill (msPathCBnds ocp)
  , mscDynamics = fill (fill (Just 0, Just 0))
  }

getFg :: forall x u c h n a .
  (Floating a, Vectorize x, Dim n) =>
  MsOcp x u c h ->
  (x a -> u a -> x a) ->
  (MsTraj x u n a, None a) ->
  (a, MsConstraints x n c h)
getFg ocp integrator (MsTraj xus xf, _) = (objective, constraints)
  where
    xs = fmap (\(MsPoint x _) -> x) xus
    us = fmap (\(MsPoint _ u) -> u) xus
--    n = TV.tvlength us
--    tf = msT ocp
--    ts = tf / (fromIntegral n)
    constraints =
      MsConstraints
      { mscBc = msBc ocp (TV.tvhead xs) xf
      , mscPathc = TV.tvzipWith (msPathC ocp) xs us
      , mscDynamics = vzipWith3 integrator' xs us x1s
      }
      where
        integrator' x0 u0 = vzipWith (-) x1'
          where
            x1' = integrator x0 u0
        x1s :: Vec n (x a)
        x1s = TV.tvshiftl xs xf

    objective = objective' `dot` objective'
    objective' = msMayer ocp xf

--    objectiveL = V.foldl' f 0 (vectorize xus)
--      where
--        f acc (MsPoint x u) = integrator dae' ts x u + acc
--          where
--            dae' = Dae (\x None u p' -> ocpLagrange ocp x None u p')
--            ddtL l = ocpLagrange ocp x None u p
--        (ssum (tvzipWith (\x u -> ocpLagrange ocp x None u p) xs us)) / fromIntegral (tvlength us
--
--ssum :: Num a => Vec n a -> a
--ssum = F.foldl' (+) 0

makeNlp ::
  (Vectorize x, Vectorize u, Vectorize c, Dim n) =>
  MsOcp x u c h ->
  (forall a. Floating a => x a -> u a -> x a) ->
  Nlp (MsTraj x u n) None (MsConstraints x n c h)
makeNlp ocp integrator = Nlp { nlpFG = getFg ocp integrator
                             , nlpBX = getDvBnds ocp
                             , nlpBG = getGBnds ocp
                             , nlpX0 = fill 0
                             , nlpP = None
                             }
