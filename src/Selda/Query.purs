module Selda.Query
  ( restrict
  , select
  , leftJoin
  , leftJoin'
  , WrapWithMaybe
  , SubQueryResult
  ) where

import Prelude

import Control.Monad.State (get, put)
import Data.Array ((:))
import Data.Maybe (Maybe)
import Data.Symbol (class IsSymbol, SProxy, reflectSymbol)
import Data.Tuple (Tuple(..))
import Heterogeneous.Mapping (class HMap, class HMapWithIndex, class Mapping, class MappingWithIndex, hmap, hmapWithIndex)
import Prim.RowList (kind RowList)
import Prim.RowList as RL
import Selda.Col (class ExtractCols, class ToCols, Col(..), getCols, toCols)
import Selda.Expr (Expr(..))
import Selda.Inner (Inner, OuterCols, outer)
import Selda.Query.Type (Query(..), SQL(..), Source(..), freshId, runQuery)
import Selda.Table (class TableColumns, Alias, Column(..), Table(..), tableColumns)
import Type.Proxy (Proxy(..))
import Type.Row (RLProxy(..))
import Unsafe.Coerce (unsafeCoerce)

restrict ∷ ∀ s. Col s Boolean → Query s Unit
restrict (Col e) = Query do
  st ← get
  put $ st { restricts = e : st.restricts }

select
  ∷ ∀ s r rl res i il
  . RL.RowToList r rl ⇒ TableColumns rl i ⇒ RL.RowToList i il ⇒ ToCols s i il res
  ⇒ Table r → Query s (Record res)
select table = do
  { res, sql } ← fromTable table
  st ← Query get
  Query $ put $ st { sources = Product sql : st.sources }
  pure res

leftJoin
  ∷ ∀ r s res rl il i mres
  . RL.RowToList r rl ⇒ TableColumns rl i ⇒ RL.RowToList i il ⇒ ToCols s i il res
  ⇒ HMap WrapWithMaybe (Record res) (Record mres)
  ⇒ Table r → (Record res → Col s Boolean) → Query s (Record mres)
leftJoin table on = do
  { res, sql } ← fromTable table
  let Col e = on res
  st ← Query get
  Query $ put $ st { sources = LeftJoin sql e : st.sources }
  pure $ hmap WrapWithMaybe res

-- | `leftJoin' on q`
-- | run sub query `q`;
-- | with this execute `on` to get JOIN constraint;
-- | add sub query to sources;
-- | return previously mapped record with each value in Col wrapped in Maybe
-- | (because LEFT JOIN can return null for each column)
leftJoin'
  ∷ ∀ s res res0 rl mres inner
  . HMap OuterCols (Record inner) (Record res0)
  ⇒ HMapWithIndex SubQueryResult (Record res0) (Record res)
  ⇒ HMap WrapWithMaybe (Record res) (Record mres)
  ⇒ RL.RowToList res0 rl ⇒ ExtractCols res0 rl
  ⇒ (Record res → Col s Boolean)
  → Query (Inner s) (Record inner)
  → Query s (Record mres)
leftJoin' on q = do
  { res, sql, alias } ← fromSubQuery q
  let Col e = on res
  st ← Query get
  Query $ put $ st { sources = LeftJoin sql e : st.sources }
  pure $ hmap WrapWithMaybe res

fromTable
  ∷ ∀ r s res rl il i
  . RL.RowToList r rl ⇒ TableColumns rl i ⇒ RL.RowToList i il ⇒ ToCols s i il res
  ⇒ Table r → Query s { res ∷ Record res , sql ∷ SQL }
fromTable (Table { name }) = do
  id ← freshId
  st ← Query get
  let
    aliased = { name, alias: name <> "_" <> show id }
    i = tableColumns aliased (RLProxy ∷ RLProxy rl)
    res = toCols (Proxy ∷ Proxy s) i (RLProxy ∷ RLProxy il)
  pure $ { res, sql: FromTable aliased }

data WrapWithMaybe = WrapWithMaybe
instance wrapWithMaybeInstance
    ∷ Mapping WrapWithMaybe (Col s a) (Col s (Maybe a))
  where
  mapping WrapWithMaybe = (unsafeCoerce ∷ Col s a → Col s (Maybe a))

subQueryAlias ∷ ∀ s. Query s Alias
subQueryAlias = do
  id ← freshId
  pure $ "sub" <> "_q" <> show id

fromSubQuery
  ∷ ∀ inner s rl res res0
  . HMap OuterCols (Record inner) (Record res0)
  ⇒ RL.RowToList res0 rl ⇒ ExtractCols res0 rl
  ⇒ HMapWithIndex SubQueryResult { | res0 } { | res }
  ⇒ Query (Inner s) (Record inner)
  → Query s { res ∷ Record res , sql ∷ SQL , alias ∷ Alias }
fromSubQuery q = do
  let (Tuple innerRes st) = runQuery q
  let res0 = outer innerRes
  let cols = getCols res0
  alias ← subQueryAlias
  let res = createSubQueryResult alias res0
  pure $ { res, sql: SubQuery alias $ st { cols = getCols res0 }, alias }

-- | Outside of the subquery, every returned col (in SELECT ...) 
-- | (no matter if it's just a column of some table or expression or function or ...)
-- | is seen as a column of this subquery.
-- | So it can just be `<subquery alias>.<col alias>`.
-- | 
-- | Creates record of Columns with namespace set as subquery alias
-- | and column name as its symbol in record
-- | 
-- | ```purescript
-- | i ∷ { a ∷ Col s Int , b ∷ Col s String } = { a: lit 1, b: people.name }
-- | createSubQueryResult namespace i
-- | ==
-- | ({ a: ...{ namespace, name: "a" }, b: ...{ namespace, name: "b" } }
-- |   ∷ { a ∷ Col s Int , b ∷ Col s String })
-- | ```
createSubQueryResult
  ∷ ∀ i o
  . HMapWithIndex SubQueryResult { | i } { | o }
  ⇒ Alias → { | i } → { | o }
createSubQueryResult = hmapWithIndex <<< SubQueryResult

data SubQueryResult = SubQueryResult Alias
instance subQueryResultInstance
    ∷ IsSymbol sym
    ⇒ MappingWithIndex SubQueryResult (SProxy sym) (Col s a) (Col s a)
  where
  mappingWithIndex (SubQueryResult namespace) sym (Col e) = 
    Col $ EColumn $ Column { namespace, name: reflectSymbol sym }
