{-# LANGUAGE OverloadedStrings, OverloadedLists #-}
module Calculator.Evaluator (evalS, getPriorities, FunMap, VarMap, OpMap, Maps, Result2) where

import           Calculator.Types (Assoc (..), Expr (..), exprToString,
                                   preprocess, showRational, showT)
import           Control.Lens     ((%~), (&), (.~), (^.), _1, _2, _3)
import           Data.Either      (rights)
import           Data.List        (foldl')
import           Data.Map.Strict  (Map)
import qualified Data.Map.Strict  as M
import           Data.Ratio
import           Control.Arrow    (second)
import           Control.Monad.State
import           Control.Monad.Except
import           Data.Text        (Text)
import qualified Data.Text        as T
import           Data.Bits        ((.|.), (.&.), xor)
import           Numeric          (showHex)

type FunMap = Map (Text, Int) ([Text], Expr)
type VarMap = Map Text Rational
type OpMap = Map Text ((Int, Assoc), Expr)
type Maps = (VarMap, FunMap, OpMap)

funNames :: FunMap -> [(Text, Text)]
funNames = map (\(f,_) -> (f, f)) . M.keys

goInside :: (Expr -> Either Text Expr) -> Expr -> Either Text Expr
goInside f ex = case ex of
  (OpCall op e1 e2) -> OpCall op <$> f e1 <*> f e2
  (Par e)           -> Par <$> f e
  (UMinus e)        -> UMinus <$> f e
  (FunCall n e)     -> FunCall n <$> mapM f e
  e                 -> return e

substitute :: ([Text], [Expr]) -> Expr -> Either Text Expr
substitute ([],[]) e = return e
substitute (x,y) _ | length x /= length y =
  Left $ "Bad argument number: " <> showT (length y) <> " instead of " <> showT (length x)
substitute (x:xs, y:ys) (Id i) = if i == x
                                    then return $ case y of
                                                           n@(Number _) -> n
                                                           iD@(Id _) -> iD
                                                           p@(Par _) -> p
                                                           t -> Par t
                                    else substitute (xs, ys) (Id i)
substitute s@(x:xs, Id fname:ys) (FunCall n e) = if n == x
  then FunCall fname <$> mapM (substitute s) e
  else do
    t <- mapM (substitute s) e
    substitute (xs, ys) (FunCall n t)
substitute s@(_:xs, _:ys) (FunCall n e) = do
  t <- mapM (substitute s) e
  substitute (xs, ys) (FunCall n t)
substitute s ex = goInside (substitute s) ex

localize :: [Text] -> Expr -> Either Text Expr
localize [] e = return e
localize (x:xs) (Id i) = if i == x then return $ Id (T.cons '@' i) else localize xs (Id i)
localize s@(x:xs) (FunCall nm e) = if nm == x
  then FunCall (T.cons '@' nm) <$> mapM (localize s) e
  else do
    t <- mapM (localize s) e
    localize xs (FunCall nm t)
localize s ex = goInside (localize s) ex

catchVar :: (VarMap, FunMap) -> Expr -> Either Text Expr
catchVar (vm, fm) ex = case ex of
  (Id i) | T.head i == '@' -> return $ Id i
  (Id i) ->
    let a = M.lookup i vm :: Maybe Rational
        getNames = map (\f -> (f,f)) . M.keys
        fNames = getNames mathFuns ++ getNames intFuns ++ getNames compFuns
        b = lookup i (funNames fm ++ fNames) :: Maybe Text
    in case a of
         Just n -> return $ Number n
         Nothing -> case b of
                     Just s  -> return $ Id s
                     Nothing -> Left $ "No such variable: " <> i
  e -> goInside st e
    where st = catchVar (vm, fm)

compFuns :: Map Text (Rational -> Rational -> Bool)
compFuns = [("lt",(<)), ("gt",(>)), ("eq",(==))
  ,("ne",(/=)), ("le",(<=)), ("ge",(>=))]

compOps :: Map Text (Rational -> Rational -> Bool)
compOps = [("<",(<)), (">",(>)), ("==",(==))
  ,("!=",(/=)), ("<=",(<=)), (">=",(>=))]

mathFuns :: Map Text (Double -> Double)
mathFuns = [("sin",sin), ("cos",cos), ("asin",asin), ("acos",acos), ("tan",tan), ("atan",atan)
        ,("log",log), ("exp",exp), ("sqrt",sqrt), ("abs",abs)]

intFuns :: Map Text (Integer -> Integer -> Integer)
intFuns = [("gcd", gcd), ("lcm", lcm), ("div", div), ("mod", mod), ("quot", quot), ("rem", rem), ("xor", xor)]

fmod :: Rational -> Rational -> Rational
fmod x y = fromInteger $ mod (floor x) (floor y)

mathOps :: Map Text (Rational -> Rational -> Rational)
mathOps = [("+",(+)), ("-",(-)), ("*",(*)), ("/",(/)), ("%",fmod), ("^",pow)]

bitOps :: Map Text (Integer -> Integer -> Integer)
bitOps = [("|", (.|.)), ("&", (.&.))]

pow :: Rational -> Rational -> Rational
pow a b | denominator a ==1 && denominator b == 1 && numerator b < 0 = toRational $ (fromRational a :: Double) ^^ numerator b
pow a b | denominator a == 1 && denominator b == 1 = toRational $ numerator a ^ numerator b
pow a b = toRational $ (fromRational a :: Double) ** (fromRational b :: Double)

getPriorities :: OpMap -> Map Text Int
getPriorities om = let lst = M.toList om
                       ps = M.fromList $ map (second (fst . fst)) lst
                   in ps

-- type Result = StateT Maps (Except Text)
type Result2 = ExceptT Text (State Maps)

evalS :: Expr -> Result2 Rational
evalS ex = case ex of
  Asgn s _ | s `elem` (["m.pi", "m.e", "m.phi", "_"] :: [T.Text]) -> throwError $ "Cannot change a constant value: " <> s
  Asgn s e -> do
    r <- evm e
    modify (\maps -> maps & _1 %~ M.insert s r)
    throwError ("Constant " <> s <> "=" <> showRational r)
  UDF n [s] (FunCall "df" [e, Id x]) | s == x -> do
    let de = derivative e (Id x)
    either throwError (evm . UDF n [s]) de
  UDF n s e -> do
    maps <- get
    let newe = localize s e >>= catchVar (maps^._1, maps ^._2)
    either throwError (\r -> do
      let newmap = M.insert (n, length s) (map (T.cons '@') s, r) $ maps^._2
      modify (\m -> m & _2 .~ newmap)
      throwError ("Function " <> n <> "/" <> showT (length s))) newe
  UDO n (-1) _ e@(OpCall op _ _) -> do
    maps <- get
    case M.lookup op (maps^._3) of
      Just ((p, a), _) -> do
        let newmap = M.insert n ((p, a), e) (maps^._3)
        modify (\m -> m & _3 .~ newmap)
        throwError ("Operator alias " <> n <> " = " <> op)
      Nothing -> throwError $ "No such operator: " <> op
  UDO n p a e
    | M.member n mathOps || M.member n compOps || M.member n bitOps || n == "=" -> throwError $ "Can not redefine the embedded operator: " <> n
    | p < 1 || p > 6 ->  throwError $ "Bad priority: " <> showT p
    | otherwise -> do
        maps <- get
        let t = localize ["x","y"] e >>= catchVar (maps^._1, maps^._2)
        either throwError (\r -> do
          let newmap = M.insert n ((p, a), r) (maps^._3)
          modify (\m -> m & _3 .~ newmap)
          throwError ("Operator " <> n <> " p=" <> showT p <> " a=" <> (if a == L then "left" else "right"))) t
  FunCall "df" [a,x] -> do
      let e = derivative a x
      either throwError (throwError . exprToString . preprocess) e
  FunCall "int" [Id fun, a, b, s] -> do
      maps <- get
      a1 <- evm a
      b1 <- evm b
      s1 <- evm s
      let list = [a1,a1+s1..b1-s1]
      return (foldl' (\acc next -> acc + s1 * next) 0 $
                rights . map (\n -> procListElem maps fun (n+1/2*s1)) $ list)
  FunCall "atan" [OpCall "/" e1 e2] -> do
    t1 <- evm e1
    t2 <- evm e2
    return . toRational $ atan2 (fromRational t1 :: Double) (fromRational t2 :: Double)
  FunCall "prat" [e] -> do
    t1 <- evm e
    throwError $ showT (numerator t1) <> " / " <> showT (denominator t1)
  FunCall "hex" [e] -> do
    t1 <- evm e
    if denominator t1 == 1
      then throwError . T.pack . ("0x" ++) . (`showHex` "") . numerator $ t1 
      else throwError "Cant convert float to hex yet"
  FunCall f [e1, e2] | M.member f intFuns -> evalInt f e1 e2
  FunCall name [a]   | M.member name mathFuns -> do
    let fun = mathFuns M.! name
    n <- evm a
    let r = (\x -> if abs x <= sin pi then 0 else x) . fun . fromRational $ n
    if isNaN r 
      then throwError "NaN"
      else return $ toRational r 
  FunCall n [a,b] | M.member n compFuns -> cmp n a b compFuns
  FunCall "if" [a,b,c] -> do
    cond <- evm a
    if cond /= 0
      then evm b
      else evm c
  FunCall name e -> do
    maps <- get
    case (M.lookup (name, length e) (maps^._2) :: Maybe ([Text],Expr)) of
      Just (al, expr) -> do
        let expr1 = substitute (al, e) expr
        either throwError evm expr1
      Nothing -> case name of
        x | T.head x == '@' -> throwError $ "Expression instead of a function name: " <> T.tail x <> "/" <> showT (length e)
        _ -> throwError $ "No such function: " <> name <> "/" <> showT (length e)
  Id s     -> do 
    maps <- get
    mte ("No such variable: " <> s) (M.lookup s (maps^._1) :: Maybe Rational)
  Number x -> return x
  OpCall op1 x s@(OpCall op2 y z) -> do
    maps <- get
    let pr = getPriorities (maps^._3)
    let a = M.lookup op1 pr
    let b = M.lookup op2 pr
    if a == b
    then case a of
      Nothing -> throwError $ "No such operators: " <> op1 <> " " <> op2
      Just _ -> do
        let ((_, asc1), _) = (maps^._3) M.! op1
        let ((_, asc2), _) = (maps^._3) M.! op2
        case (asc1, asc2) of
          (L, L) -> evm $ OpCall op2 (OpCall op1 x y) z
          (R, R) -> evm s >>= evm . OpCall op1 x . Number
          _ -> throwError $ "Operators with a different associativity: " <> op1 <> " and " <> op2
    else evm s >>= evm . OpCall op1 x . Number
  oc@(OpCall "/" x y) -> do
    n <- evm y
    n1 <- evm x
    if n == 0 then throwError $ "Division by zero: " <> exprToString oc else return (n1 / n)
  oc@(OpCall "%" x y) -> do
    n <- evm y
    n1 <- evm x
    if n == 0
    then throwError $ "Division by zero: " <> exprToString oc
    else return (fromInteger $ mod (floor n1) (floor n))
  OpCall op x y | M.member op compOps -> cmp op x y compOps
  OpCall op x y | M.member op mathOps -> eval' ( mathOps M.! op) op x y
  OpCall op x y | M.member op bitOps  -> bitEval ( bitOps M.! op) x y
  OpCall op x y  -> do
    maps <- get
    case (M.lookup op (maps^._3) :: Maybe ((Int, Assoc),Expr)) of
      Just (_, expr) -> do
        let expr1 = substitute (["@x", "@y"], [x,y]) expr
        either throwError evm expr1
      Nothing -> case op of
        opn | T.head opn == '@' -> throwError $ "Expression instead of a function name: " <> T.tail opn <> "/2"
        _ -> throwError $ "No such operator: " <> op <> "/2"
  UMinus (OpCall "^" x y) -> evm $ OpCall "^" (UMinus x) y
  UMinus x         -> (0-) <$> evm x
  Par e            -> evm e
  where
    mte s = maybe (throwError s) return
    tooBig = 2^(8000000 :: Integer) :: Rational
    cmp op x y mp = do
      let fun = mp M.! op
      n <- evm x
      n1 <- evm y
      return $ if fun n n1
        then 1
        else 0
    bitEval op x y = do
      n <- evm x
      n1 <- evm y
      if denominator n == 1 && denominator n1 == 1
        then return . toRational $ op (numerator n) (numerator n1)
        else throwError "Cannot perform bitwise operator on a float"
    evm x = do
      r <- evalS x
      if r > tooBig
         then throwError "Too much!"
         else return r
    evalInt f x y = do
      t1 <- evm x
      t2 <- evm y
      if denominator t1 == 1 && denominator t2 == 1
         then return . toRational $ (intFuns M.! f) (numerator t1) (numerator t2)
         else throwError "Cannot use integral function on real numbers!"
    eval' :: (Rational -> Rational -> Rational) -> Text -> Expr -> Expr -> Result2 Rational
    eval' f op x y = do
      t1 <- evm x
      t2 <- evm y
      if ( op == "^" && logBase 10 (fromRational t1 :: Double) * (fromRational t2 :: Double) > 2408240) ||
         f t1 t2 > tooBig
         then throwError "Too much!"
         else return (f t1 t2)
    procListElem m fun n = evalState (runExceptT (evm (FunCall fun [Number n]))) m

derivative :: Expr -> Expr -> Either Text Expr
derivative e x = case e of
  Par ex -> Par <$> derivative ex x
  UMinus ex -> UMinus <$> derivative ex x
  Number _ -> return $ Number 0
  i@(Id _) | i == x -> return $ Number 1
  (Id _) -> return $ Number 0
  OpCall "^" i (Number n) | i == x->
    return $ OpCall "*" (Number n) (OpCall "^" i (Number (n-1)))
  OpCall "^" (Number a) i | i == x -> return $ OpCall "*" e (FunCall "log" [Number a])
  OpCall op ex1 ex2 | op == "-" || op == "+" -> OpCall op <$> derivative ex1 x <*> derivative ex2 x
  OpCall "*" ex1 ex2 -> do
    d1 <- derivative ex1 x
    d2 <- derivative ex2 x
    return $ OpCall "+" (OpCall "*" d1 ex2) (OpCall "*" d2 ex1)
  OpCall "/" ex1 ex2 -> do
    d1 <- derivative ex1 x
    d2 <- derivative ex2 x
    return $ OpCall "/" (OpCall "-" (OpCall "*" d1 ex2) (OpCall "*" d2 ex1)) (OpCall "^" ex2 (Number 2))
  ex@(FunCall "exp" [i]) | i == x -> return ex
  FunCall "log" [i] | i == x -> return $ OpCall "/" (Number 1) i
  FunCall "sin" [i] | i == x -> return $ FunCall "cos" [i]
  FunCall "cos" [i] | i == x -> return $ UMinus (FunCall "sin" [i])
  FunCall "tan" [i] | i == x ->
    return $ OpCall "/" (Number 1) (OpCall "^" (FunCall "cos" [i]) (Number 2))
  ex@(FunCall _ [i]) -> OpCall "*" <$> derivative ex i <*> derivative i x
  _ -> Left "No such derivative"
