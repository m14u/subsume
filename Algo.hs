-- Copyright 2015 Google Inc. All Rights Reserved.
--
-- Licensed under the Apache License, Version 2.0 (the "License")--
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

{-# LANGUAGE OverloadedStrings #-}

module Algo (otrsToTrs) where

import Debug.Trace
import Data.List ( intercalate, tails, inits )
import Data.Traversable
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Datatypes
import Signature
import Control.Monad.Writer.Strict (Writer, runWriter, tell)
import Terms
import Maranget

isBottom :: Term -> Bool
isBottom Bottom = True
isBottom _ = False

-- interleave abc ABC = Abc, aBc, abC
interleave :: [a] -> [a] -> [[a]]
interleave [] [] = []
interleave xs ys = zipWith3 glue (inits xs) ys (tails (tail xs))
  where glue xs x ys = xs ++ x : ys

complement :: Signature -> Term -> Term -> Term
complement sig p1 p2 = p1 \\ p2
  where
    appl f ps | any isBottom ps = Bottom
              | otherwise = Appl f ps

    plus Bottom u = u
    plus t Bottom = t
    plus t u = Plus t u

    sum = foldr plus Bottom

    alias x Bottom = Bottom
    alias x t = Alias x t

    u \\ (Var _) = Bottom
    u \\ Bottom = u
    (Var x) \\ p@(Appl g ps) = alias x (sum [pattern f \\ p | f <- fs])
      where fs = ctorsOfSameRange sig g
            pattern f = Appl f (replicate (arity sig f) (Var "_"))
    Bottom \\ Appl _ _ = Bottom
    Appl f ps \\ Appl g qs
        | f /= g || someUnchanged = appl f ps
        | otherwise = sum [appl f ps' | ps' <- interleave ps pqs]
      where pqs = zipWith (\\) ps qs
            someUnchanged = or (zipWith (==) ps pqs)
    Plus q1 q2 \\ p@(Appl _ _) = plus (q1 \\ p) (q2 \\ p)
    Alias x p1 \\ p2 = alias x (p1 \\ p2)
    p1 \\ Alias x p2 = p1 \\ p2
    p \\ (Plus p1 p2) = (p \\ p1) \\ p2

preMinimize :: [Term] -> [Term]
preMinimize patterns = filter (not . isMatched) patterns
  where isMatched p = any (matches' p) patterns
        matches' p q = not (matches p q) && matches q p

minimize :: Signature -> [Term] -> [Term]
minimize sig ps = minimize' ps []
  where minimize' [] kernel = kernel
        minimize' (p:ps) kernel =
           if subsumes sig (ps++kernel) p
              then shortest (minimize' ps (p:kernel)) (minimize' ps kernel)
              else minimize' ps (p:kernel)

        shortest xs ys = if length xs <= length ys then xs else ys

removePlusses :: Term -> S.Set Term
removePlusses (Plus p1 p2) = removePlusses p1 `S.union` removePlusses p2
removePlusses (Appl f ps) = S.map (Appl f) (traverseSet removePlusses ps)
  where traverseSet f s = S.fromList (traverse (S.toList . f) s)
removePlusses (Alias x p) = S.map (Alias x) (removePlusses p)
removePlusses (Var x) = S.singleton (Var x)
removePlusses Bottom = S.empty

removeAliases :: Rule -> Rule
removeAliases (Rule lhs rhs) = Rule lhs' (substitute subst rhs)
  where (lhs', subst) = collectAliases (renameUnderscores lhs)

        collectAliases t = runWriter (collect t)

        collect :: Term -> Writer Substitution Term
        collect (Appl f ts) = Appl f <$> (mapM collect ts)
        collect (Var x) = return (Var x)
        collect (Alias x t) = do
          t' <- collect t
          tell (M.singleton x t')
          return t'

expandAnti :: Signature -> Term -> Term
expandAnti sig t = expandAnti' t
  where expandAnti' (Appl f ts) = Appl f (map expandAnti' ts)
        expandAnti' (Plus t1 t2) = Plus (expandAnti' t1) (expandAnti' t2)
        expandAnti' (Compl t1 t2) = complement sig (expandAnti' t1) (expandAnti' t2)
        expandAnti' (Anti t) = complement sig (Var "_") (expandAnti' t)
        expandAnti' (Var x) = Var x
        expandAnti' Bottom = Bottom

antiTrsToOtrs :: Signature -> [Rule] -> [Rule]
antiTrsToOtrs sig rules = [Rule (expandAnti sig lhs) rhs | Rule lhs rhs <- rules]

otrsToAdditiveTrs :: Signature -> [Rule] -> [Rule]
otrsToAdditiveTrs sig rules = zipWith diff rules (inits patterns)
  where patterns = [lhs | Rule lhs _ <- rules]
        diff (Rule lhs rhs) lhss = Rule (complement sig lhs (sum lhss)) rhs
        sum = foldr Plus Bottom

aliasedTrsToTrs :: [Rule] -> [Rule]
aliasedTrsToTrs = map removeAliases

additiveTrsToAliasedTrs :: Signature -> [Rule] -> [Rule]
additiveTrsToAliasedTrs sig rules = concatMap transform rules
  where transform (Rule lhs rhs) = map (flip Rule rhs) (expand lhs)
        expand = minimize sig . preMinimize . S.toList . removePlusses

otrsToTrs sig = aliasedTrsToTrs
              . additiveTrsToAliasedTrs sig
              . otrsToAdditiveTrs sig
              . antiTrsToOtrs sig
