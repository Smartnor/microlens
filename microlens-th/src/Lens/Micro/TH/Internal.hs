{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}

#ifndef MIN_VERSION_template_haskell
#define MIN_VERSION_template_haskell(x,y,z) (defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ >= 706)
#endif

#ifdef TRUSTWORTHY
# if MIN_VERSION_template_haskell(2,12,0)
{-# LANGUAGE Safe #-}
# else
{-# LANGUAGE Trustworthy #-}
# endif
#endif

{- |
Module      :  Lens.Micro.TH.Internal
Copyright   :  (C) 2013-2016 Eric Mertens, Edward Kmett; 2018 Monadfix
License     :  BSD-style (see the file LICENSE)

Functions used by "Lens.Micro.TH". This is an internal module and it may go
away or change at any time; do not depend on it.
-}
module Lens.Micro.TH.Internal
(
  -- * Name utilities
  HasName(..),
  newNames,

  -- * Type variable utilities
  HasTypeVars(..),
  typeVars,
  substTypeVars,

  -- * Miscellaneous utilities
  inlinePragma,
  conAppsT,
  quantifyType, quantifyType',
)
where

import qualified Data.Map as Map
import           Data.Map (Map)
import qualified Data.Set as Set
import           Data.Set (Set)
import           Data.List (nub)
import           Data.Maybe
import           Lens.Micro
import           Language.Haskell.TH

#if __GLASGOW_HASKELL__ < 710
import           Control.Applicative
import           Data.Traversable (traverse, sequenceA)
#endif

-- | Has a 'Name'
class HasName t where
  -- | Extract (or modify) the 'Name' of something
  name :: Lens' t Name

instance HasName TyVarBndr where
  name f (PlainTV n) = PlainTV <$> f n
  name f (KindedTV n k) = (`KindedTV` k) <$> f n

instance HasName Name where
  name = id

-- | On @template-haskell-2.11.0.0@ or later, if a 'GadtC' or 'RecGadtC' has
-- multiple 'Name's, the leftmost 'Name' will be chosen.
instance HasName Con where
  name f (NormalC n tys)       = (`NormalC` tys) <$> f n
  name f (RecC n tys)          = (`RecC` tys) <$> f n
  name f (InfixC l n r)        = (\n' -> InfixC l n' r) <$> f n
  name f (ForallC bds ctx con) = ForallC bds ctx <$> name f con
#if MIN_VERSION_template_haskell(2,11,0)
  name f (GadtC ns argTys retTy) =
    (\n -> GadtC [n] argTys retTy) <$> f (head ns)
  name f (RecGadtC ns argTys retTy) =
    (\n -> RecGadtC [n] argTys retTy) <$> f (head ns)
#endif

-- | Generate many new names from a given base name.
newNames :: String {- ^ base name -} -> Int {- ^ count -} -> Q [Name]
newNames base n = sequence [ newName (base++show i) | i <- [1..n] ]

-- | Provides for the extraction of free type variables, and alpha renaming.
class HasTypeVars t where
  -- When performing substitution into this traversal you're not allowed
  -- to substitute in a name that is bound internally or you'll violate
  -- the 'Traversal' laws, when in doubt generate your names with 'newName'.
  typeVarsEx :: Set Name -> Traversal' t Name

instance HasTypeVars TyVarBndr where
  typeVarsEx s f b
    | Set.member (b^.name) s = pure b
    | otherwise              = name f b

instance HasTypeVars Name where
  typeVarsEx s f n
    | Set.member n s = pure n
    | otherwise      = f n

instance HasTypeVars Type where
  typeVarsEx s f (VarT n)            = VarT <$> typeVarsEx s f n
  typeVarsEx s f (AppT l r)          = AppT <$> typeVarsEx s f l <*> typeVarsEx s f r
  typeVarsEx s f (SigT t k)          = (`SigT` k) <$> typeVarsEx s f t
  typeVarsEx s f (ForallT bs ctx ty) = ForallT bs <$> typeVarsEx s' f ctx <*> typeVarsEx s' f ty
       where s' = s `Set.union` Set.fromList (bs ^.. typeVars)
  typeVarsEx _ _ t                   = pure t

#if !MIN_VERSION_template_haskell(2,10,0)
instance HasTypeVars Pred where
  typeVarsEx s f (ClassP n ts) = ClassP n <$> typeVarsEx s f ts
  typeVarsEx s f (EqualP l r)  = EqualP <$> typeVarsEx s f l <*> typeVarsEx s f r
#endif

instance HasTypeVars Con where
  typeVarsEx s f (NormalC n ts)     =
    NormalC n <$> (traverse . _2) (typeVarsEx s f) ts
  typeVarsEx s f (RecC n ts)        =
    RecC n <$> (traverse . _3) (typeVarsEx s f) ts
  typeVarsEx s f (InfixC l n r)     =
    InfixC <$> g l <*> pure n <*> g r
      where g (i, t) = (,) i <$> typeVarsEx s f t
  typeVarsEx s f (ForallC bs ctx c) =
    ForallC bs <$> typeVarsEx s' f ctx <*> typeVarsEx s' f c
      where s' = s `Set.union` Set.fromList (bs ^.. typeVars)
#if MIN_VERSION_template_haskell(2,11,0)
  typeVarsEx s f (GadtC ns argTys retTy) =
    GadtC ns <$> (traverse . _2) (typeVarsEx s f) argTys
             <*> typeVarsEx s f retTy
  typeVarsEx s f (RecGadtC ns argTys retTy) =
    RecGadtC ns <$> (traverse . _3) (typeVarsEx s f) argTys
                <*> typeVarsEx s f retTy
#endif

instance HasTypeVars t => HasTypeVars [t] where
  typeVarsEx s = traverse . typeVarsEx s

instance HasTypeVars t => HasTypeVars (Maybe t) where
  typeVarsEx s = traverse . typeVarsEx s

-- Traverse /free/ type variables
typeVars :: HasTypeVars t => Traversal' t Name
typeVars = typeVarsEx mempty

-- Substitute using a map of names in for /free/ type variables
substTypeVars :: HasTypeVars t => Map Name Name -> t -> t
substTypeVars m = over typeVars $ \n -> fromMaybe n (Map.lookup n m)

-- | Generate an INLINE pragma.
inlinePragma :: Name -> [DecQ]

#ifdef INLINING

#if MIN_VERSION_template_haskell(2,8,0)

# ifdef OLD_INLINE_PRAGMAS
-- 7.6rc1?
inlinePragma methodName = [pragInlD methodName (inlineSpecNoPhase Inline False)]
# else
-- 7.7.20120830
inlinePragma methodName = [pragInlD methodName Inline FunLike AllPhases]
# endif

#else
-- GHC <7.6, TH <2.8.0
inlinePragma methodName = [pragInlD methodName (inlineSpecNoPhase True False)]
#endif

#else

inlinePragma _ = []

#endif

-- | Apply arguments to a type constructor.
conAppsT :: Name -> [Type] -> Type
conAppsT conName = foldl AppT (ConT conName)

-- | Template Haskell wants type variables declared in a forall, so we find
-- all free type variables in a given type and declare them.
quantifyType :: Cxt -> Type -> Type
quantifyType = quantifyType' Set.empty

-- | This function works like 'quantifyType' except that it takes a list of
-- variables to exclude from quantification.
quantifyType' :: Set Name -> Cxt -> Type -> Type
quantifyType' exclude c t = ForallT vs c t
  where
    vs = map PlainTV
       $ filter (`Set.notMember` exclude)
       $ nub -- stable order
       $ toListOf typeVars t
