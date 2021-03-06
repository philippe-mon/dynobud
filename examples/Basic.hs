-- | Minimize the Rosenbrock function (plus a trivial constraint) using
-- the basic NLP interface.

{-# OPTIONS_GHC -Wall #-}
{-# Language DeriveFunctor #-}
{-# Language DeriveGeneric #-}

module Main where

import Dyno.Vectorize
import Dyno.Nlp
import Dyno.NlpSolver
import Dyno.Ipopt
import Dyno.Casadi.SXElement


data X a = X a a deriving (Functor, Generic1, Show)
data G a = G a deriving (Functor, Generic1, Show)

instance Vectorize X
instance Vectorize G

myNlp :: Nlp X None G SXElement
myNlp = Nlp { nlpFG = fg
            , nlpBX = bx
            , nlpBG = bg
            , nlpX0 = x0
            , nlpP = None
            }
  where
    x0 :: X Double
    x0 = X (-8) (-8)

    bx :: X Bounds
    bx = X (Just (-21), Just 0.5)
           (Just (-2), Just 2)

    bg :: G Bounds
    bg = G (Just (-10), Just 10)

    fg :: X SXElement -> None SXElement -> (SXElement, G SXElement)
    fg (X x y) _ = (f, g)
      where
        f = (1-x)**2 + 100*(y - x**2)**2
        g = G x


main :: IO ()
main = do
  opt <- solveNlp ipoptSolver myNlp Nothing
  print opt
