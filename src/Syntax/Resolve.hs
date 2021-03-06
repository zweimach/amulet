{-# LANGUAGE FlexibleContexts
  , ConstraintKinds
  , OverloadedStrings
  , MultiParamTypeClasses
  , TupleSections
  , TypeFamilies
  , ScopedTypeVariables
  , LambdaCase #-}

{- | The resolver is the first step after parsing. It performs several key
   actions:

    * Determines what variable every identifier is pointing to, including
      a module's variables and handling ambiguous variables.

    * Handles module definitions and @open@s.

    * Prohibit some dubious constructs, such as patterns which bind the
      same identifier multiple times.

    * Reorganise binary operators, taking precedence and associativity
      into account (the parser ignores these intentionally).
-}
module Syntax.Resolve
  ( resolveProgram
  , ResolveError(..)
  , ResolveResult(..)
  , VarKind(..)
  ) where

import Control.Lens hiding (Lazy, Context)
import Control.Monad.Chronicles
import Control.Monad.Reader
import Control.Applicative
import Control.Monad.Namey

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Traversable
import Data.Bifunctor
import Data.Foldable
import Data.Function
import Data.Spanned
import Data.Functor
import Data.Reason
import Data.Triple
import Data.Maybe
import Data.These
import Data.List
import Data.Span

import qualified CompileTarget as CT

import Syntax.Resolve.Import
import Syntax.Resolve.Scope
import Syntax.Resolve.Error
import Syntax.Subst
import Syntax

import Parser.Unicode

data ResolveResult = ResolveResult
  { program :: [Toplevel Resolved] -- ^ The resolved program
  -- | The exported signature, which other modules may import
  , exposed :: Signature
  -- | The current resolver state, suitable for use within REPL.
  , state :: Signature
  }

type MonadResolve m = ( MonadChronicles ResolveError m
                      , MonadReader Context m
                      , MonadImport m
                      , MonadNamey m )

-- | Resolve a program within a given 'Scope' and 'ModuleScope'
resolveProgram :: (MonadNamey m, MonadImport m)
               => CT.Target -- ^ The backend we're using
               -> Signature -- ^ The scope in which to resolve this program
               -> [Toplevel Parsed] -- ^ The program to resolve
               -> m (Either [ResolveError] ResolveResult)
               -- ^ The resolved program or a list of resolution errors
resolveProgram ct sc ts
  = (these (Left . toList) (\(s, exposed, inner) -> Right (ResolveResult s exposed inner)) (\x _ -> Left (toList x))<$>)
  . runChronicleT . flip runReaderT (mkContext ct & scope .~ sc)
  $ reTops ts mempty

-- | Resolve the whole program
reTops :: MonadResolve m
       => [Toplevel Parsed] -> Signature
       -> m ([Toplevel Resolved], Signature, Signature)
reTops [] sig = views scope ([], sig,)

reTops (r@(LetStmt re am bs a):rest) sig = do
  (bs', vs, ts) <- unzip3 <$> traverse reBinding bs
  let body = extendTyvars (concat ts) $
        LetStmt re am <$> traverse (uncurry (flip (<$>) . reExpr . view bindBody)) (zip bs bs') <*> pure a
      addBinds m = foldr (\(Name v, _) -> Map.insert v (annotation r)) m (concat vs)
  case re of
    NonRecursive -> reTopsWith am rest sig (withVals (concat vs)) . pure =<< local (nonRecs %~ addBinds) body
    Recursive -> reTopsWith am rest sig (withVals (concat vs)) body

reTops (r@(ForeignVal am v t ty a):rest) sig = do
  v' <- tagVar v
  reTopsWith am rest sig (withVal v v') $
    ForeignVal am
          <$> lookupEx v `catchJunk` r
          <*> pure t
          <*> reType (wrap ty)
          <*> pure a

  where wrap x = foldr (TyPi . flip (`Invisible` Nothing) Spec) x (toList (ftv x))

reTops (d@(TySymDecl am t vs ty ann):ts) sig = do
  t' <- tagVar t
  (vs', sc) <- resolveTele d vs
  decl <- extendTyvars sc $
    TySymDecl am t' vs' <$> reType ty <*> pure ann
  reTopsWith am ts sig (withTy t t') (pure decl)

reTops (d@(TypeFunDecl am tau args kindsig eqs ann):rest) sig = do
  tau' <- tagVar tau
  (args, vars) <- resolveTele d args
  reTopsWith am rest sig (withTy tau tau') $ do
    eqs <- for eqs $ \clause@(TyFunClause lhs@(TyApps t xs) rhs ann) -> do
      case t of
        TyCon t' _ | t' == tau -> pure ()
        _ -> confesses (ArisingFrom (TFClauseWrongHead t tau) (BecauseOf clause))

      let vis TyInvisArg{} = False
          vis _ = True
      when (length xs /= length (filter vis args)) $
        confesses (ArisingFrom (TFClauseWrongArity (length xs) (length args)) (BecauseOf clause))

      let fv = Set.toList (ftv lhs)
      fv' <- traverse tagVar fv
      extendTyvars (zip fv fv') $
        (\x y -> TyFunClause x y ann) <$> reType lhs <*> reType rhs

    kindsig <- extendTyvars vars $ traverse reType kindsig
    pure $ TypeFunDecl am tau' args kindsig eqs ann


reTops (d@(TypeDecl am t vs cs ann):rest) sig = do
  t'  <- tagVar t
  (vs', sc) <- resolveTele d vs
  let c = maybe [] (map extractCons) cs
  c' <- traverse tagVar c
  decl <- local (scope %~ withTy t t') $
    TypeDecl am t' vs'
      <$> maybe (pure Nothing) (fmap Just . traverse (resolveCons sc) . zip c') cs
      <*> pure ann
  reTopsWith am rest sig (withTy t t' . withVals (zip c c')) (pure decl)

  where resolveCons _  (v', UnitCon ac _ a) = pure $ UnitCon ac v' a
        resolveCons vs (v', ArgCon ac _ t a) = ArgCon ac v' <$> extendTyvars vs (reType t) <*> pure a
        resolveCons _  (v', GadtCon ac _ t a) = do
          let fvs = toList (ftv t)
          fresh <- traverse tagVar fvs
          t' <- extendTyvars (zip fvs fresh) (reType t)
          pure (GadtCon ac v' t' a)

        extractCons (UnitCon _ v _) = v
        extractCons (ArgCon _ v _ _) = v
        extractCons (GadtCon _ v _ _) = v

reTops (r@(Open mod):rest) sig = do
  (mod', sig') <- retcons (wrapError r) $ reModule mod
  case sig' of
    Nothing -> confess empty
    Just sig' -> local (scope %~ (<>sig')) $ first3 (Open mod':) <$> reTops rest sig

reTops (r@(Include mod):rest) sig = do
  (mod', sig') <- retcons (wrapError r) $ reModule mod
  case sig' of
    Nothing -> confess empty
    Just sig' -> local (scope %~ (<>sig')) $ do
      (prog, siga, sigb) <- reTops rest sig
      pure (Include mod':prog, siga <> sig', sigb)

reTops (r@(Module am name mod):rest) sig = do
  name' <- tagVar name
  (mod', sig') <- retcons (wrapError r) $ reModule mod
  reTopsWith am rest sig (withMod name name' sig') $ pure (Module am name' mod')

reTops (DeriveInstance t ann:rest) sig = do
  t <- reType t
  first3 (DeriveInstance t ann:) <$> reTops rest sig

reTops (t@(Class name am ctx tvs fds ms ann):rest) sig = do
  name' <- tagVar name
  (tvs', tvss) <- resolveTele t tvs

  (ctx', fds', (ms', vs')) <- local (scope %~ withTy name name') $ do
    tyfuns <- fmap concat . for ms $ \case
      AssocType name _ _ _ -> (:[]) . (name,) <$> tagVar name
      _ -> pure []

    extendTyvars tvss . local (scope %~ withTys tyfuns) $
      (,,) <$> traverse reType ctx
           <*> traverse reFd fds
           <*> reClassItem (map fst tvss) ms

  let (vars, types) = partition ((\case { AssocType{} -> False; _ -> True}) . snd) (zip vs' ms)

  reTopsWith am rest sig (withVals (map fst vars) . withTys ((name, name') : map fst types)) $ do
    ms'' <- extendTyvars tvss $ sequence ms'
    pure $ Class name' am ctx' tvs' fds' ms'' ann

  where
    reClassItem tvs' ((MethodSig name ty an):rest) = do
      (ra, rb) <- reClassItem tvs' rest
      name' <- tagVar name
      pure ( (MethodSig name' <$> reType (wrap tvs' ty) <*> pure an):ra
           , (name, name'):rb )
    reClassItem tvs' (m@(AssocType name args ty an):rest) = do
      name' <- lookupTy name
      (ra, rb) <- reClassItem tvs' rest
      (tele, _) <- resolveTele m args
      pure ( (AssocType name' tele <$> reType (wrap tvs' ty) <*> pure an):ra
           , (name, name'):rb )
    reClassItem tvs' (DefaultMethod b an:rest) = do
      (ra, rb) <- reClassItem tvs' rest
      pure ( (DefaultMethod <$> (fmap unMethodImpl . fst =<< reMethod (MethodImpl b)) <*> pure an):ra
           , rb )
    reClassItem _ [] = pure ([], [])

    unMethodImpl (MethodImpl x) = x
    unMethodImpl _ = undefined

    wrap tvs' x = foldr (TyPi . flip (`Invisible` Nothing) Spec) x (ftv x `Set.difference` Set.fromList tvs')
    reFd fd@(Fundep f t a) = Fundep <$> traverse tv f <*> traverse tv t <*> pure a where
      tv x = lookupTyvar x `catchJunk` fd


reTops (t@(Instance cls ctx head ms _ ann):rest) sig = do
  cls' <- lookupTy cls `catchJunk` t

  let fvs = toList (foldMap ftv ctx <> ftv head)
  fvs' <- traverse tagVar fvs

  t' <- extendTyvars (zip fvs fvs') $ do
    ctx' <- traverse reType ctx
    head' <- reType head

    (ms', vs) <- unzip <$> traverse reMethod ms
    ms'' <- extendVals (concat vs) (sequence ms')

    pure (Instance cls' ctx' head' ms'' False ann)

  first3 (t':) <$> reTops rest sig

reTopsWith :: MonadResolve m
           => TopAccess -> [Toplevel Parsed] -> Signature
           -> (Signature -> Signature)
           -> m (Toplevel Resolved)
           -> m ([Toplevel Resolved], Signature, Signature)
reTopsWith am ts sig extend t = do
  let sig' = case am of
        Public -> extend sig
        Private -> sig
  local (scope %~ extend) $ do
    t' <- t
    first3 (t':) <$> reTops ts sig'

-- | Resolve a module term.
reModule :: MonadResolve m
         => ModuleTerm Parsed
         -> m (ModuleTerm Resolved, Maybe Signature)
reModule (ModStruct bod an) = do
  res <- recover Nothing $ Just <$> reTops bod mempty
  pure $ case res of
    Nothing -> (ModStruct [] an, Nothing)
    Just (bod', sig, _) -> (ModStruct bod' an, Just sig)
reModule (ModRef ref an) = do
  (ref', sig) <- recover (junkVar, Nothing)
               $ view scope >>= lookupIn (^.modules) (const mempty) ref VarModule
  pure (ModRef ref' an, sig)
reModule r@(ModImport path a) = do
  result <- importModule a path
  (var, sig) <- case result of
    Imported var sig -> pure (var, Just sig)
    Errored -> do
      -- Mark us as having failed resolution, but don't print an error for this
      -- module.
      dictate mempty
      pure (junkVar, Nothing)
    ImportCycle loop -> do
      dictates (wrapError r (ImportLoop loop))
      pure (junkVar, Nothing)
    NotFound search -> do
      dictates (wrapError r (UnresolvedImport path search))
      pure (junkVar, Nothing)

  -- Replace this with a reference so we don't have to care later on
  -- about this. Bit ugly, but I'll survive
  pure (ModRef var a, sig)

reModule r@(ModTargetImport mods a) = do
  target <- view target
  case filter ((==CT.name target) . importBackend) mods of
    [] -> dictates (wrapError r (NoMatchingImport target)) $> junk
    [TargetImport _ path ann] -> reModule (ModImport path ann)
    xs -> dictates (ManyMatchingImports target xs a) $> junk

  where junk = (ModRef junkVar a, Nothing)

resolveTele :: (MonadResolve m, Reasonable f p)
            => f p -> [TyConArg Parsed] -> m ([TyConArg Resolved], [(Var Parsed, Var Resolved)])
resolveTele r (TyVarArg v:as) = do
  v' <- tagVar v
  extendTyvar v v' $ do
    (as, vs) <- resolveTele r as
    pure (TyVarArg v':as, (v, v'):vs)
resolveTele r (TyAnnArg v k:as) = do
  v' <- tagVar v
  extendTyvar v v' $ do
    ((as, vs), k) <-
      (,) <$> resolveTele r as <*> reType k
    pure (TyAnnArg v' k:as, (v, v'):vs)
resolveTele r (TyInvisArg v k:as) = do
  v' <- tagVar v
  extendTyvar v v' $ do
    ((as, vs), k) <-
      (,) <$> resolveTele r as <*> reType k
    pure (TyInvisArg v' k:as, (v, v'):vs)
resolveTele _ [] = pure ([], [])

reExpr :: MonadResolve m => Expr Parsed -> m (Expr Resolved)
reExpr r@(VarRef v a) = flip VarRef a <$> (lookupEx v `catchJunk` r)

reExpr (Let re bs c a) = do
  (bs', vs, ts) <- unzip3 <$> traverse reBinding bs
  let extend = extendTyvars (concat ts) . extendVals (concat vs)
      reBody = traverse (uncurry (flip (<$>) . reExpr . view bindBody)) (zip bs bs')
      addBinds m = foldr (\(Name v, _) -> Map.insert v a) m (concat vs)
  case re of
    NonRecursive -> Let re <$> local (nonRecs %~ addBinds) reBody <*> extend (reExpr c) <*> pure a
    Recursive -> extend $ Let re <$> reBody <*> reExpr c <*> pure a
reExpr (If c t b a) = If <$> reExpr c <*> reExpr t <*> reExpr b <*> pure a
reExpr (App f p a) = App <$> reExpr f <*> reExpr p <*> pure a
reExpr (Fun p e a) = do
  let reWholePattern' (PatParam p) = do
        (p', vs, ts) <- reWholePattern p
        pure (PatParam p', vs, ts)
      reWholePattern' _ = error "EvParam resolve"
  (p', vs, ts) <- reWholePattern' p
  extendTyvars ts . extendVals vs $ Fun p' <$> reExpr e <*> pure a

reExpr r@(Begin [] a) = dictates (wrapError r EmptyBegin) $> junkExpr a
reExpr (Begin es a) = Begin <$> traverse reExpr es <*> pure a

reExpr (Literal l a) = pure (Literal l a)

reExpr (Match e ps p a) = do
  e' <- reExpr e
  ps' <- traverse reArm ps
  pure (Match e' ps' p a)

reExpr (Function ps p a) = do
  ps' <- traverse reArm ps
  pure (Function ps' p a)

reExpr (BinOp l o r a) = BinOp <$> reExpr l <*> reExpr o <*> reExpr r <*> pure a
reExpr (Hole v a) = Hole <$> tagVar v <*> pure a
reExpr (Ascription e t a) = do
  t <- reType t
  let boundByT (TyPi (Invisible v@(TgName p _) _ _) t) = (Name p, v):boundByT t
      boundByT _ = []
  Ascription <$> extendTyvars (boundByT t) (reExpr e) <*> pure t <*> pure a
reExpr e@(Record fs a) = do
  let ls = map (view fName) fs
      dupes = mapMaybe (listToMaybe . tail) . group . sort $ ls
  traverse_ (dictates . NonLinearRecord e) dupes
  Record <$> traverse reField fs <*> pure a
reExpr ex@(RecordExt e fs a) = do
  let ls = map (view fName) fs
      dupes = mapMaybe (listToMaybe . tail) . group . sort $ ls
  traverse_ (dictates . NonLinearRecord ex) dupes
  RecordExt <$> reExpr e <*> traverse reField fs <*> pure a

reExpr (Access e t a) = Access <$> reExpr e <*> pure t <*> pure a
reExpr (LeftSection o r a) = LeftSection <$> reExpr o <*> reExpr r <*> pure a
reExpr (RightSection l o a) = RightSection <$> reExpr l <*> reExpr o <*> pure a
reExpr (BothSection o a) = BothSection <$> reExpr o <*> pure a
reExpr (AccessSection t a) = pure (AccessSection t a)
reExpr (Parens e a) = flip Parens a <$> reExpr e

reExpr (Tuple es a) = Tuple <$> traverse reExpr es <*> pure a
reExpr (ListExp es a) = ListExp <$> traverse reExpr es <*> pure a
reExpr (TupleSection es a) = TupleSection <$> traverse (traverse reExpr) es <*> pure a

reExpr r@(OpenIn m e a) = retcons (wrapError r) $ do
  -- Disable structs in local lets - they may bind variables, and we don't
  -- currently support that.
  case m of
    ModStruct{} -> dictates (wrapError r LetOpenStruct)
    _ -> pure ()

  (m', sig) <- reModule m
  case sig of
    Nothing -> pure $ OpenIn m' (junkExpr a) a
    Just sig -> OpenIn m' <$> local (scope %~ (<>sig)) (reExpr e) <*> pure a

reExpr (Lazy e a) = Lazy <$> reExpr e <*> pure a
reExpr (Vta e t a) = Vta <$> reExpr e <*> reType t <*> pure a

reExpr (ListComp e qs a) =
  let go (CompGuard e:qs) acc = do
        e <- reExpr e
        go qs (CompGuard e:acc)
      go (CompGen b e an:qs) acc = do
        e <- reExpr e
        (b, es, ts) <- reWholePattern b
        extendTyvars ts . extendVals es $
          go qs (CompGen b e an:acc)
      go (CompLet bs an:qs) acc =do
        (bs', vs, ts) <- unzip3 <$> traverse reBinding bs
        extendTyvars (concat ts) . extendVals (concat vs) $ do
          bs <- traverse (uncurry (flip (<$>) . reExpr . view bindBody)) (zip bs bs')
          go qs (CompLet bs an:acc)
      go [] acc = ListComp <$> reExpr e <*> pure (reverse acc) <*> pure a
  in go qs []

reExpr r@(Idiom vp va es a) = Idiom <$> lookupEx' vp <*> lookupEx' va <*> reExpr es <*> pure a where
  lookupEx' v = lookupEx v `catchJunk` r

reExpr r@(ListFrom v x a) = ListFrom <$> lookupEx' v <*> reExpr x <*> pure a where
  lookupEx' v = lookupEx v `catchJunk` r

reExpr r@(ListFromTo v x y a) = ListFromTo <$> lookupEx' v <*> reExpr x <*> reExpr y <*> pure a where
  lookupEx' v = lookupEx v `catchJunk` r

reExpr r@(ListFromThen v x y a) = ListFromThen <$> lookupEx' v <*> reExpr x <*> reExpr y <*> pure a where
  lookupEx' v = lookupEx v `catchJunk` r

reExpr r@(ListFromThenTo v x y z a) =
  ListFromThenTo <$> lookupEx' v <*> reExpr x <*> reExpr y <*> reExpr z <*> pure a
    where lookupEx' v = lookupEx v `catchJunk` r

reExpr r@(MLet bind pat ex body a) = do
  bind <- lookupEx bind `catchJunk` r
  (p, vs, ts) <- reWholePattern pat
  ex <- reExpr ex
  extendTyvars ts . extendVals vs $ do
    body <- reExpr body
    pure (MLet bind p ex body a)

reExpr ExprWrapper{} = error "resolve cast"

reField :: MonadResolve m => Field Parsed -> m (Field Resolved)
reField (Field n e s) = Field n <$> reExpr e <*> pure s

reArm :: MonadResolve m
      => Arm Parsed -> m (Arm Resolved)
reArm (Arm p g b a) = do
  (p', vs, ts) <- reWholePattern p
  extendTyvars ts . extendVals vs $
    Arm p' <$> traverse reExpr g <*> reExpr b <*> pure a

reType :: MonadResolve m => Type Parsed -> m (Type Resolved)
reType t@(TyCon v a) = TyCon <$> (lookupTy v `catchJunk` InType t a) <*> pure a
reType t@(TyVar v a) = TyVar <$> (lookupTyvar v `catchJunk` InType t a) <*> pure a
reType t@(TyPromotedCon v a) = TyPromotedCon <$> (lookupEx v `catchJunk` InType t a) <*> pure a
reType v@TySkol{} = error ("impossible! resolving skol " ++ show v)
reType v@TyWithConstraints{} = error ("impossible! resolving withcons " ++ show v)
reType (TyLit v) = pure (TyLit v)
reType (TyPi (Invisible v k req) ty) = do
  v' <- tagVar v
  ty' <- extendTyvar v v' $ reType ty
  k <- traverse reType k
  pure (TyPi (Invisible v' k req) ty')
reType (TyPi (Anon f) x) = TyPi . Anon <$> reType f <*> reType x
reType (TyPi (Implicit f) x) = TyPi . Implicit <$> reType f <*> reType x
reType (TyApp f x) = TyApp <$> reType f <*> reType x
reType (TyRows t f) = TyRows <$> reType t
                             <*> traverse (\(a, b) -> (a,) <$> reType b) f
reType (TyExactRows f) = TyExactRows <$> traverse (\(a, b) -> (a,) <$> reType b) f
reType (TyTuple ta tb) = TyTuple <$> reType ta <*> reType tb
reType (TyTupleL ta tb) = TyTupleL <$> reType ta <*> reType tb
reType (TyWildcard _) = pure (TyWildcard Nothing)
reType (TyParens t) = TyParens <$> reType t
reType (TyOperator tl o tr) = TyOperator <$> reType tl <*> reType o <*> reType tr
reType TyType = pure TyType

reWholePattern :: forall m. MonadResolve m
               => Pattern Parsed
               -> m ( Pattern Resolved
                    , [(Var Parsed, Var Resolved)]
                    , [(Var Parsed, Var Resolved)])
reWholePattern p = do
  -- Resolves a pattern and ensures it is linear
  (p', vs, ts) <- rePattern p
  checkLinear p vs
  checkLinear p ts
  pure (p', map lim vs, map lim ts)
  where lim (a, b, _) = (a, b)

checkLinear :: MonadResolve m => Pattern Parsed -> [(Var Parsed, Var Resolved, Pattern Resolved)] -> m ()
checkLinear p = traverse_ (\vs@((_,v, _):_) -> dictates . wrapError p $ NonLinearPattern v (map thd3 vs))
              . filter ((>1) . length)
              . groupBy ((==) `on` fst3)
              . sortOn fst3

rePattern :: MonadResolve m
          => Pattern Parsed
          -> m ( Pattern Resolved
               , [(Var Parsed, Var Resolved, Pattern Resolved)]
               , [(Var Parsed, Var Resolved, Pattern Resolved)])
rePattern (Wildcard a) = pure (Wildcard a, [], [])
rePattern (Capture v a) = do
  v' <- tagVar v
  let p = Capture v' a
  pure (p, [(v, v', p)], [])
rePattern (PAs p v a) = do
  v' <- tagVar v
  (p', vs, ts) <- rePattern p
  let as = PAs p' v' a
  pure (as, (v, v', as):vs, ts)
rePattern r@(Destructure v Nothing a) = do
  v' <- lookupEx v `catchJunk` r
  pure (Destructure v' Nothing a, [], [])
rePattern r@(Destructure v p a) = do
  v' <- lookupEx v `catchJunk` r
  (p', vs, ts) <- case p of
    Nothing -> pure (Nothing, [], [])
    Just pat -> do
      (p', vs, ts) <- rePattern pat
      pure (Just p', vs, ts)
  pure (Destructure v' p' a, vs, ts)
rePattern (PType p t a) = do
  (p', vs, ts) <- rePattern p
  let fvs = toList (ftv t)
  fresh <- for fvs $ \x -> lookupTyvar x `absolving` tagVar x
  t' <- extendTyvars (zip fvs fresh) (reType t)
  let r' = PType p' t' a
  pure (r', vs, zip3 fvs fresh (repeat r') ++ ts)
rePattern (PRecord f a) = do
  (f', vss, tss) <- unzip3 <$> traverse (\(n, p) -> do
                                       (p', vs, ts) <- rePattern p
                                       pure ((n, p'), vs, ts))
                              f
  pure (PRecord f' a, concat vss, concat tss)
rePattern (PTuple ps a) = do
  (ps', vss, tss) <- unzip3 <$> traverse rePattern ps
  pure (PTuple ps' a, concat vss, concat tss)
rePattern (PList ps a) = do
  (ps', vss, tss) <- unzip3 <$> traverse rePattern ps
  pure (PList ps' a, concat vss, concat tss)
rePattern pat@(POr p q a) = do
  (p', pvs, pts) <- rePattern p
  (q', qvs, qts) <- rePattern q
  -- We require q to be linear now, as we won't validate it later.
  checkLinear q qvs
  checkLinear q qts
  let avs = set pvs <> set pts
      bvs = set qvs <> set qts
  unless (avs == bvs) $
    confesses (ArisingFrom (UnequalVarBinds p (Set.toList avs) q (Set.toList bvs)) (BecauseOf pat))

  let q'' = fixPattern (matchup pvs qvs <> matchup pts qts) q'
  pure (POr p' q'' a, pvs, pts)

  where
    matchup :: (Ord a, Ord b) => [(a, b, c)] -> [(a, b, c)] -> Map.Map b b
    matchup old new =
      let old' = foldMap (\(a, b, _) -> Map.singleton a b) old in
      foldMap (\(a, b, _) -> Map.singleton b (old' Map.! a)) new
    set  = Set.fromList . map (view _1)
rePattern (PLiteral l a) = pure (PLiteral l a, [], [])
rePattern PGadtCon{} = error "Impossible PGadtCon"

fixPattern :: Map.Map (Var Resolved) (Var Resolved) -> Pattern Resolved -> Pattern Resolved
fixPattern vs = go where
  ts = (`TyVar` undefined) <$> vs

  get v = fromMaybe v (Map.lookup v vs)
  go (Wildcard a) = Wildcard a
  go (Capture v a) = Capture (get v) a
  go (PAs p v a) = PAs (go p) (get v) a
  go (Destructure v p a) = Destructure v (go <$> p) a
  go (PType p t a) = PType (go p) (apply ts t) a
  go (PRecord f a) = PRecord (map (second go) f) a
  go (PTuple ps a) = PTuple (map go ps) a
  go (PList ps a) = PList (map go ps) a
  go (POr l r a) = POr (go l ) (go r) a
  go (PLiteral l a) = PLiteral l a
  go PGadtCon{} = error "Impossible"

reBinding :: MonadResolve m
          => Binding Parsed
          -> m ( Expr Resolved -> Binding Resolved
               , [(Var Parsed, Var Resolved)]
               , [(Var Parsed, Var Resolved)] )
reBinding (Binding v vp _ c a) = do
  v' <- tagVar v
  pure ( \e' -> Binding v' vp e' c a, [(v, v')], [])
reBinding (Matching p _ a) = do
  (p', vs, ts) <- reWholePattern p
  pure ( \e' -> Matching p' e' a, vs, ts)
reBinding TypedMatching{} = error "reBinding TypedMatching{}"

reMethod :: MonadResolve m
         => InstanceItem Parsed
         -> m (m (InstanceItem Resolved), [(Var Parsed, Var Resolved)])
reMethod (MethodImpl b@(Binding var vp bod c an)) = do
  var' <- retcons (wrapError b) $ lookupEx var
  pure ( (\bod' -> MethodImpl (Binding var' vp bod' c an)) <$> reExpr bod
       , [(var, var')] )
reMethod (MethodImpl b@(Matching (Capture var vp) bod an)) = do
  var' <- retcons (wrapError b) $ lookupEx var
  pure ( (\bod' -> MethodImpl (Binding var' vp bod' True an)) <$> reExpr bod
       , [(var, var')] )
reMethod (MethodImpl b@Matching{}) =
  confesses (ArisingFrom IllegalMethod (BecauseOf b))

reMethod b@(TypeImpl var args exp ann) = do
  var' <- retcons (wrapError b) $ lookupTy var
  (args, sc) <- resolveTele b args
  exp <- extendTyvars sc $ reType exp
  pure (pure (TypeImpl var' args exp ann), [(var, var')])

reMethod (MethodImpl TypedMatching{}) = error "reBinding TypedMatching{}"

-- | Lookup a variable in a signature, using a specific lens.
lookupIn :: MonadResolve m
         => (Signature -> Map.Map VarName a)
         -> (Context -> Map.Map VarName Span)
         -> Var Parsed -> VarKind -> Signature
         -> m a
lookupIn g nonRec v k = go v where
  go (Name n) env =
    case Map.lookup n (g env) of
      Nothing -> do
        pos <- asks (Map.lookup n . nonRec)
        confesses (NotInScope k v pos)
      Just x -> pure x
  go (InModule m n) env =
    case Map.lookup m (env ^. modules) of
      Nothing -> confesses (NotInScope k v Nothing)
      -- Abort without an error if the module is unresolved. This is "safe", as
      -- we'll have already produced an error at the original error.
      Just (_, Nothing) -> confess mempty
      Just (_, Just env) -> go n env

-- | Convert a slot into a concrete variable
lookupSlot :: MonadResolve m
           => Var Parsed -> Slot
           -> m (Var Resolved)
lookupSlot v (SVar x) = pure $
  let toName (Name x) = x
      toName (InModule t x) = t <> T.singleton '.' <> toName x
   in case x of
     TgInternal n -> TgInternal n
     TgName _ id -> TgName (toName v) id
lookupSlot v (SAmbiguous vs) = confesses (Ambiguous v vs)

-- | Lookup a value/expression variable.
lookupEx :: MonadResolve m => Var Parsed -> m (Var Resolved)
lookupEx v = view scope
         >>= lookupIn (^.vals) (^.nonRecs) v (if isCtorVar v then VarCtor else VarVar)
         >>= lookupSlot v

-- | Lookup a type name.
lookupTy :: MonadResolve m => Var Parsed -> m (Var Resolved)
lookupTy v = view scope
         >>= lookupIn (^.types) (const mempty) v (if isCtorVar v then VarCtor else VarType)
         >>= lookupSlot v

-- | Lookup a tyvar.
lookupTyvar :: MonadResolve m => Var Parsed -> m (Var Resolved)
lookupTyvar v@(Name n) = do
  vars <- view tyvars
  case Map.lookup n vars of
    Nothing -> confesses (NotInScope VarTyvar v Nothing)
    Just x -> lookupSlot v x
lookupTyvar InModule{} = error "Impossible: InModule tyvar"

-- | A garbage variable used when we cannot resolve something.
junkVar :: Var Resolved
junkVar = TgInternal "<missing>"

junkExpr :: Ann Resolved -> Expr Resolved
junkExpr = VarRef junkVar

wrapError :: Reasonable e p => e p -> ResolveError -> ResolveError
wrapError _  e@ArisingFrom{} = e
wrapError _  e@ManyMatchingImports{} = e
wrapError r e = ArisingFrom e (BecauseOf r)

-- | Catch an error, returning a junk variable instead.
catchJunk :: (MonadResolve m, Reasonable e p)
          => m (Var Resolved) -> e p -> m (Var Resolved)
catchJunk m r = recover junkVar (retcons (wrapError r) m)

isCtorVar :: Var Parsed -> Bool
isCtorVar (Name t) = T.length t > 0 && classify (T.head t) == Upper
isCtorVar (InModule _ v) = isCtorVar v
