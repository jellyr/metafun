module Language.Kiff.Typing.Infer where

import Language.Kiff.Syntax
import Language.Kiff.Typing.Substitution
import Language.Kiff.Typing.Unify
import Language.Kiff.Typing.Instantiate
import Language.Kiff.CallGraph
    
import qualified Data.Map as Map
import Data.Supply
import Data.Either

import Debug.Trace    
    
data Ctx = Ctx { conmap :: Map.Map DataName Ty,
                 varmap :: Map.Map VarName (Ty, Bool)}
         deriving Show

tyFun :: [Ty] -> Ty
tyFun = foldr1 TyFun

tyApp :: [Ty] -> Ty
tyApp = foldr1 TyApp
         
mkCtx :: Supply TvId -> Ctx
mkCtx ids = Ctx { conmap = Map.fromList [("nil", tyList),
                                         ("cons", tyFun [TyVarId i, tyList, tyList])],
                  varmap = Map.fromList [("not",  (tyFun [TyPrimitive TyBool, TyPrimitive TyBool], True))]
                }
    where i = supplyValue ids
          tyList = TyApp (TyData "list") (TyVarId i)

addVar :: Ctx -> (VarName, (Ty, Bool)) -> Ctx
addVar ctx@Ctx{varmap = varmap} (name, (ty, poly)) = ctx{varmap = varmap'}
    where varmap' = Map.insert name (ty, poly) varmap
                   
addMonoVar :: Ctx -> (VarName, Ty) -> Ctx
addMonoVar ctx (name, ty) = addVar ctx (name, (ty, False))

addPolyVar :: Ctx -> (VarName, Ty) -> Ctx
addPolyVar ctx (name, ty) = addVar ctx (name, (ty, True))

inferDef :: Supply TvId -> Ctx -> Def -> Either [UnificationError] Ty
inferDef ids ctx (Def name decl defs) = case unify eqs of
                                          Left errs -> Left errs
                                          Right s -> fitDecl (xform s tau)
    where tau = TyVarId $ supplyValue ids
          (tys, eqss) = unzip $ zipWith collect (split ids) defs
          eqs = (map (tau :=:) tys) ++ (concat eqss)
          collect ids def = collectDefEq ids ctx def

          fitDecl tau' = case decl of
                         Nothing -> Right tau'
                         Just ty -> case checkDecl ty tau' of
                                      Left errs -> Left $ (CantFitDecl ty tau'):errs
                                      Right _ -> Right ty

inferDefs :: Supply TvId -> Ctx -> [Def] -> Either [UnificationError] Ctx
inferDefs ids ctx defs = foldl step (Right ctx) $ zip (split ids) $ trace (show $ map (map (\ (Def name _ _) -> name)) defgroups) $ defgroups
    where defgroups = sortDefs defs
          inferGroup ids ctx defs = case foldl combine (Right []) polyvars of
                                      Left err -> Left err
                                      Right eqs -> case unify eqs of
                                                     Left err -> Left err
                                                     Right s -> Right $ map (xformPoly s) polyvars
              where  (ids', ids'') = split2 ids
                                   
                     ctx' = foldl (\ ctx (name, _, ty) -> addMonoVar ctx (name, ty)) ctx vars
                     vars = zipWith mkVar (split ids'') defs
                            where  mkVar ids def@(Def name _ _) = (name, def, TyVarId $ supplyValue ids)
                                                                  
                     infer ids (name, def, tau) = (name, tau, inferDef ids ctx' def)

                     polyvars = zipWith infer (split ids') vars
                     xformPoly s (name, tau, tau') = (name, xform s tau)
                                                
                     combine (Right eqs)  (name, tau, Right tau')   = Right $ (tau :=: tau'):eqs
                     combine (Right _)    (name, _, Left err')  = Left err'
                     combine (Left err)   (name, _, Left err')  = Left $ err ++ err'
                     combine (Left err)   _                     = Left err
                                                                  
          step (Left err) (ids, defs) = Left err
                                        -- case inferGroup ids ctx defs of
                                        --   Left err'  -> Left $ err ++ err'
                                        --   Right _    -> Left err
          step (Right ctx) (ids, defs) = case inferGroup ids ctx defs of
                                           Left err    -> Left err
                                           Right vars  -> Right $ foldl addPolyVar ctx vars

collectDefEq :: Supply TvId -> Ctx -> DefEq -> (Ty, [TyEq])
collectDefEq ids ctx (DefEq pats body) = (tau, peqs ++ beqs)
    where (pts, ctx', peqs) = inferPats ids'' ctx pats
          (ids', ids'') = split2 ids
          (bt, beqs) = collectExpr ids' ctx' body
          tau = tyFun (pts ++ [bt])
          
          
                                   
collectExpr :: Supply TvId -> Ctx -> Expr -> (Ty, [TyEq])
collectExpr ids ctx (Var var) = case Map.lookup var (varmap ctx) of
                                  Just (tau, poly) -> (if poly then instantiate ids tau else tau, [])
                                  Nothing -> error $ show (var, map fst $ Map.toList $ varmap ctx)
collectExpr ids ctx (Con con) = case Map.lookup con (conmap ctx) of
                                  Just t -> (instantiate ids t, [])
collectExpr ids ctx (App f x) = (tau, (ft :=: TyFun xt tau):(feqs ++ xeqs))
    where  (ids', ids'') = split2 ids
           (ft, feqs) = collectExpr ids' ctx f
           (xt, xeqs) = collectExpr ids'' ctx x
           tau = TyVarId $ supplyValue ids              
collectExpr ids ctx (PrimBinOp op left right) = (alpha, (tau :=: tau'):(leqs ++ reqs))
    where  (ids', ids'') = split2 ids
           (lt, leqs) = collectExpr ids' ctx left
           (rt, reqs) = collectExpr ids'' ctx right
           (t1, t2, t3) = typeOfOp op
           tau = tyFun  [TyPrimitive t1, TyPrimitive t2, TyPrimitive t3]
           alpha = TyVarId $ supplyValue ids
           tau' = tyFun [lt, rt, alpha]               
collectExpr ids ctx (IfThenElse cond thn els) = (alpha, eqs++ceqs++teqs++eeqs)
    where  (ids', ids'', ids3) = split3 ids
           (ct, ceqs) = collectExpr ids' ctx cond
           (tt, teqs) = collectExpr ids'' ctx thn
           (et, eeqs) = collectExpr ids3 ctx els
           alpha = TyVarId $ supplyValue ids
           eqs = [tt :=: alpha, et :=: alpha, ct :=: TyPrimitive TyBool]               
collectExpr ids ctx (IntLit _) = (TyPrimitive TyInt, [])
collectExpr ids ctx (BoolLit _) = (TyPrimitive TyBool, [])
collectExpr ids ctx (UnaryMinus e) = (tyInt, (tyInt :=: tau):eqs)
    where  (tau, eqs) = collectExpr ids ctx e
           tyInt = TyPrimitive TyInt
collectExpr ids ctx (Lam pats body) = (tyFun (pts ++ [tau]), peqs ++ eqs)
    where  (ids', ids'') = split2 ids
           (pts, ctx', peqs) = inferPats ids' ctx pats
           (tau, eqs) = collectExpr ids'' ctx' body
collectExpr ids ctx (Let defs body) = collectExpr ids' ctx' body
    where (ids', ids'') = split2 ids
          ctx' = case inferDefs ids'' ctx defs of
                   Right ctx' -> ctx' -- TODO: error handling
                                         
collectPats :: Supply TvId -> Ctx -> [Pat] -> ([Ty], [(VarName, Ty)], [TyEq])
collectPats ids ctx pats = (tys, binds, eqs)
    where (tys, bindss, eqss) = unzip3 $ zipWith collect (split ids) pats
          collect ids pat = collectPat ids ctx pat
          binds = concat bindss -- TODO: Check that pattern variable names are unique
          eqs = concat eqss

inferPats :: Supply TvId -> Ctx -> [Pat] -> ([Ty], Ctx, [TyEq])
inferPats ids ctx pats = (tys, ctx', eqs)
    where (tys, binds, eqs) = collectPats ids ctx pats
          ctx' = foldl addMonoVar ctx binds

collectPat :: Supply TvId -> Ctx -> Pat -> (Ty, [(VarName, Ty)], [TyEq])
collectPat ids ctx Wildcard         = (TyVarId $ supplyValue ids, [], [])
collectPat ids ctx (IntPat _)       = (TyPrimitive TyInt, [], [])
collectPat ids ctx (BoolPat _)      = (TyPrimitive TyBool, [], [])
collectPat ids ctx (PVar var)       = let tau = TyVarId $ supplyValue ids
                                      in (tau, [(var, tau)], [])
collectPat ids ctx (PApp con pats)  = (alpha, binds, (t :=: tyFun (ts ++ [alpha])):eqs)
    where   (ids', ids'') = split2 ids
            t = case Map.lookup con (conmap ctx) of
                  Just t -> instantiate ids' t
            (ts, binds, eqs) = collectPats ids'' ctx pats
            alpha = TyVarId $ supplyValue ids
                
intOp = (TyInt, TyInt, TyInt)                                                                        
intRel = (TyInt, TyInt, TyBool)
boolOp = (TyBool, TyBool, TyBool)
        
typeOfOp OpAdd  = intOp
typeOfOp OpSub  = intOp
typeOfOp OpMul  = intOp
typeOfOp OpMod  = intOp
typeOfOp OpAnd  = boolOp
typeOfOp OpOr   = boolOp
typeOfOp OpEq   = intRel -- TODO
