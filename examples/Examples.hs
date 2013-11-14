{-# OPTIONS_GHC -Wall #-}
{-# Language RankNTypes #-}
{-# Language GADTs #-}
{-# Language DeriveFunctor #-}
{-# Language DeriveGeneric #-}

module Main where

--import GHC.Generics ( Generic1 )
import qualified Data.Vector as V

import Hascm.Vectorize
import Hascm.TypeNats
import Hascm.TypeVecs ( Vec(..), mkVec' )
import Hascm.Nlp
import Hascm.Sqp

myNlp :: Nlp (Vec D2) None (Vec D1)
myNlp = Nlp fg bx bg
  where
    bx = mkVec' [ (Just (-21), Just 0.5)
                , (Just (-2), Just 2)
                --, (Nothing, Nothing)
                ]
    bg = mkVec' [(Just (-10), Just 10)]
    
    fg :: forall a . Floating a => NlpInputs (Vec D2) None a -> NlpFun (Vec D1) a
    fg (NlpInputs xs' _) = NlpFun f g
      where
        f = (1-x)**2 + 100*(y - x**2)**2
        g = mkVec' [x]
        
        xs = vectorize xs'
        x = xs V.! 0
        y = xs V.! 1

--myNlp :: Nlp (Vec D2) (Vec D1)
--myNlp = Nlp fg bx bg
--  where
--    bx = mkVec' [(Just (31), Just (234)),(Just (-9), Just 9)]
--    --bg = mkVec' [(Just (-30), Just (-1))]
--    bg = mkVec' [(Just 3, Nothing)]
--    
--    fg :: forall a . Floating a => Vec D2 a -> NlpFun (Vec D1) a
--    fg xs' = NlpFun f g
--      where
--        f = x**4 + 3*y**4
--        g = mkVec' [y]
--        
--        xs = vectorize xs'
--        x = xs V.! 0
--        y = xs V.! 1

main :: IO ()
main = do
  (SqpIn x0 _ _ _, _, kktInf) <- solveSqp myNlp (mkVec' [-8,-8] :: Vec D2 Double) None
  putStrLn "\n\n"
  print x0
  print kktInf