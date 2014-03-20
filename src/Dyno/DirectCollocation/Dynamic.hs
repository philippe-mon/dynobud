{-# OPTIONS_GHC -Wall -fno-warn-orphans #-}
{-# Language ScopedTypeVariables #-}
{-# Language DeriveGeneric #-}

module Dyno.DirectCollocation.Dynamic
       ( DynCollTraj(..)
       , DynPlotPoints
       , CollTrajMeta(..)
       , MetaTree
       , forestFromMeta
       , toMeta
       , ctToDynamic
       , dynPlotPointsL
       , PlotPoints(..)
       , PlotPointsL(..)
       , toPlotTree
       , NameTree(..)
       ) where

import Control.Arrow ( second )
import Data.List ( mapAccumL )
import Data.Tree ( Tree(..) )
import qualified Data.Vector as V
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import qualified Data.Tree as Tree
import Data.Serialize ( Serialize(..) )
import GHC.Generics ( Generic )
import Linear.V

import Dyno.Server.Accessors ( AccessorTree(..), Lookup(..), accessors )
import Dyno.Vectorize
import Dyno.Cov
import qualified Dyno.TypeVecs as TV
import Dyno.TypeVecs ( Vec )

import Dyno.DirectCollocation.Types
import Dyno.DirectCollocation.Formulate ( mkTaus, interpolate )
import Dyno.DirectCollocation.Reify


data PlotPoints n deg x z u a =
  PlotPoints (Vec n ((a, x a), Vec deg (a, x a, z a, u a), (a, x a))) (a, x a)

data PlotPointsL x z u a =
  PlotPointsL [[(a, x a)]] [[(a, z a)]] [[(a, u a)]]

plotPoints ::
  forall x z u p s n deg a .
  (Dim n, Dim deg, Fractional a, Vectorize x)
  => CollTraj x z u p s n deg a ->
  PlotPoints n deg x z u a
plotPoints ct@(CollTraj tf _ _ stages xf) = PlotPoints ret (tf', xf)
  where
    (tf', ret) = T.mapAccumL f 0 stages
    nStages = TV.tvlength stages
    h = tf / fromIntegral nStages
    taus = mkTaus (ctDeg ct)

    f :: a -> CollStage x z u deg a -> (a, ((a, x a), Vec deg (a, x a, z a, u a), (a, x a)))
    f t0 (CollStage x0 xs) = (tnext, stage)
      where
        tnext = t0 + h
        stage = ( (t0, x0)
                , TV.tvzipWith (\(CollPoint x z u) tau -> (t0 + h*tau, x, z, u)) xs taus
                , (tnext, interpolate taus x0 (fmap getX xs))
                )

-- plotPointLists :: forall n deg x z u a .
--                   (RealFrac a, Read a, Vectorize x, Vectorize z, Vectorize u) =>
--                   PlotPoints n deg x z u a ->
--                   PlotPointsL x z u a
-- plotPointLists (PlotPoints vec txf) =
--   PlotPointsL (xs' ++ [[txf]]) zs' us'
--   where
--     (xs', zs', us') = unzip3 $ map f (F.toList vec)
--
--     f :: ((a, x a), Vec deg (a, x a, z a, u a), (a, x a)) -> ([(a, x a)], [(a, z a)], [(a, u a)])
--     f (x0, stage, xf) = (x0 : xs ++ [xf], zs, us)
--       where
--         (xs,zs,us) = unzip3 $ map (\(t, x, z, u) -> ((t,x), (t,z), (t,u))) (F.toList stage)

plotPointLists' :: forall n deg x z u a .
                  (RealFrac a, Read a, Vectorize x, Vectorize z, Vectorize u) =>
                  PlotPoints n deg x z u a ->
                  PlotPointsL V.Vector V.Vector V.Vector a
plotPointLists' (PlotPoints vec txf) =
  PlotPointsL (xs' ++ [[second vectorize txf]]) zs' us'
  where
    (xs', zs', us') = unzip3 $ map f (F.toList vec)

    f :: ((a, x a), Vec deg (a, x a, z a, u a), (a, x a)) -> ([(a, V.Vector a)], [(a, V.Vector a)], [(a, V.Vector a)])
    f ((t0,x0), stage, (tf,xf)) = ((t0,vectorize x0) : xs ++ [(tf,vectorize xf)], zs, us)
      where
        (xs,zs,us) = unzip3 $ map (\(t, x, z, u) -> ((t,vectorize x), (t,vectorize z), (t,vectorize u))) (F.toList stage)

toPlotTree :: forall x z u .
              (Lookup (x Double), Lookup (z Double), Lookup (u Double),
               Vectorize x, Vectorize z, Vectorize u) =>
              Tree (String, String, Maybe (PlotPointsL x z u Double -> [[(Double, Double)]]))
toPlotTree = Node ("trajectory", "trajectory", Nothing) [xtree, ztree, utree]
  where
    xtree :: Tree ( String, String, Maybe (PlotPointsL x z u Double -> [[(Double, Double)]]))
    xtree = toGetterTree (\(PlotPointsL x _ _) -> x) "differential states" $ accessors (fill 0)

    ztree :: Tree ( String, String, Maybe (PlotPointsL x z u Double -> [[(Double, Double)]]))
    ztree = toGetterTree (\(PlotPointsL _ z _) -> z) "algebraic variables" $ accessors (fill 0)

    utree :: Tree ( String, String, Maybe (PlotPointsL x z u Double -> [[(Double, Double)]]))
    utree = toGetterTree (\(PlotPointsL _ _ u) -> u) "controls" $ accessors (fill 0)

    toGetterTree toXs name (Getter f) = Node (name, name, Just g) []
      where
        g = map (map (second f)) . toXs
    toGetterTree toXs name (Data (_,name') children) =
      Node (name, name', Nothing) $ map (uncurry (toGetterTree toXs)) children


data NameTree = NameTreeNode (String,String) [(String,NameTree)]
              | NameTreeLeaf Int
              deriving (Show, Eq, Generic)
instance Serialize NameTree

data CollTrajMeta = CollTrajMeta { ctmX :: NameTree
                                 , ctmZ :: NameTree
                                 , ctmU :: NameTree
                                 , ctmP :: NameTree
                                 , ctmN :: Int
                                 , ctmDeg :: Int
                                 } deriving (Eq, Generic)
instance Serialize CollTrajMeta

namesFromAccTree :: AccessorTree a -> NameTree
namesFromAccTree x = (\(_,(_,y)) -> y) $ namesFromAccTree' 0 ("",x)

namesFromAccTree' :: Int -> (String, AccessorTree a) -> (Int, (String, NameTree))
namesFromAccTree' k (nm, Getter _) = (k+1, (nm, NameTreeLeaf k))
namesFromAccTree' k0 (nm, Data names ats) = (k, (nm, NameTreeNode names children))
  where
    (k, children) = mapAccumL namesFromAccTree' k0 ats


dynPlotPointsL ::
  forall a . (RealFrac a, Read a) =>
  DynCollTraj a -> PlotPointsL V.Vector V.Vector V.Vector a
dynPlotPointsL (DynCollTraj x) = reifyCollTraj x (plotPointLists' . plotPoints)

type DynPlotPoints a = PlotPointsL V.Vector V.Vector V.Vector a
type MetaTree a = Tree.Forest (String, String, Maybe (DynPlotPoints a -> [[(a,a)]]))

forestFromMeta :: CollTrajMeta -> MetaTree Double
forestFromMeta meta = [xTree,zTree,uTree]
  where
    xTree = blah (\(PlotPointsL x _ _) -> x) "differential states" (ctmX meta)
    zTree = blah (\(PlotPointsL _ z _) -> z) "algebraic variables" (ctmZ meta)
    uTree = blah (\(PlotPointsL _ _ u) -> u) "controls" (ctmU meta)

    blah :: (c -> [[(t, V.Vector t1)]]) -> String -> NameTree ->
            Tree (String, String, Maybe (c -> [[(t, t1)]]))
    blah f myname (NameTreeNode (nm1,_) children) =
      Tree.Node (myname,nm1,Nothing) $ map (uncurry (blah f)) children
    blah f myname (NameTreeLeaf k) = Tree.Node (myname,"",Just (woo . f)) []
      where
        woo = map (map (\(t,x) -> (t, x V.! k)))


toMeta :: forall x z u p s n deg a .
          (Lookup (x ()), Lookup (z ()), Lookup (u ()), Lookup (p ()),
           Vectorize x, Vectorize z, Vectorize u, Vectorize p,
           Dim n, Dim deg)
          => CollTraj x z u p s n deg a -> CollTrajMeta
toMeta ct =
  CollTrajMeta { ctmX = namesFromAccTree $ accessors (fill () :: x ())
               , ctmZ = namesFromAccTree $ accessors (fill () :: z ())
               , ctmU = namesFromAccTree $ accessors (fill () :: u ())
               , ctmP = namesFromAccTree $ accessors (fill () :: p ())
               , ctmN = ctN ct
               , ctmDeg = ctDeg ct
               }

newtype DynCollTraj a = DynCollTraj (CollTraj V.Vector V.Vector V.Vector V.Vector V.Vector () () a)
                      deriving Generic
instance Serialize a => Serialize (DynCollTraj a)
instance Serialize a => Serialize (V.Vector a) where
  put = put . V.toList
  get = fmap V.fromList get

ctToDynamic ::
  (Vectorize x, Vectorize z, Vectorize u, Vectorize p, Vectorize s) =>
  CollTraj x z u p s n deg a -> DynCollTraj a
ctToDynamic (CollTraj t (Cov p0) p stages xf) = DynCollTraj $
  CollTraj t (Cov p0) (vectorize p) (TV.mkUnit (fmap csToDynamic stages)) (vectorize xf)

csToDynamic ::
  (Vectorize x, Vectorize z, Vectorize u) =>
  CollStage x z u deg a -> CollStage V.Vector V.Vector V.Vector () a
csToDynamic (CollStage x0 xzus) = CollStage (vectorize x0) (TV.mkUnit (fmap cpToDynamic xzus))

cpToDynamic ::
  (Vectorize x, Vectorize z, Vectorize u) =>
  CollPoint x z u a -> CollPoint V.Vector V.Vector V.Vector a
cpToDynamic (CollPoint x z u) = CollPoint (vectorize x) (vectorize z) (vectorize u)