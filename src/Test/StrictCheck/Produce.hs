module Test.StrictCheck.Produce
  ( Produce(..)
  , part
  , field
  , producePrimitive
  -- , Lazy(..)
  , returning
  , returning1
  , Producing
  , runProducing
  , Input
  , Inputs
  ) where

import Test.QuickCheck hiding (Args, Result)
import Test.QuickCheck.Gen.Unsafe

import           Data.Urn ( Urn, Weight )
import qualified Data.Urn          as Urn
import qualified Data.Urn.Internal as Urn ( uninsert )

import Data.Monoid ((<>))

import Test.StrictCheck.Internal.Inputs
import Test.StrictCheck.Consume
import Test.StrictCheck.Curry
import Test.StrictCheck.Curry.Function

import Control.Monad.Reader

import Generics.SOP


-------------------------------------------------------
-- The user interface for creating Produce instances --
-------------------------------------------------------

newtype Producing b =
  Producing (ReaderT Inputs Gen b)
  deriving newtype (Functor, Applicative, Monad)

runProducing :: Producing b -> Inputs -> Gen b
runProducing (Producing r) i = runReaderT r i

part :: Producing b -> Producing b
part produceWhole =
  Producing . ReaderT $ \(Inputs is) ->
    do (vs, is') <- unzip <$> mapM draws is
       vary (mconcat vs) $
         runProducing produceWhole (Inputs is')

-- | Produce an arbitrary construction, but using Inputs to drive the
-- implicit destruction of the original input value.
class Produce b where
  produce :: Producing b

-- | Destruct some inputs to generate an output. This function handles the
-- interleaving of input destruction with output construction. It should always
-- be immediately called (on the supplied Inputs) at every recursive position
field :: Produce a => Producing a
field = part produce

-- | Use the Arbitrary instance for a type to produce it. This should only be
-- used for "flat" types, i.e. those which contain no interesting substructure.
producePrimitive :: Arbitrary b => Producing b
producePrimitive = Producing . ReaderT $ const arbitrary


---------------------------------------
-- How to make random lazy functions --
---------------------------------------

-- NOTE: This instance must be defined in this module, as it has to break the
-- abstraction of the Inputs type. No other instance needs to break this.
-- Incidentally, it also must break Gen's abstraction barrier, because it needs
-- to use promote to make a function.

instance (Consume a, Produce b) => Produce (a -> b) where
  produce = returning1 produce

returning1 :: Consume a => Producing b -> Producing (a -> b)
returning1 out =
  Producing . ReaderT $ \(Inputs inputs) ->
    promote $ \a ->
      runProducing (part out) (Inputs (consume a : inputs))

returning :: forall args result. (All Consume args, Curry args result, SListI args )
          => Producing result -> Producing (args -..-> result)
returning out =
  Producing . ReaderT $ \(Inputs inputs) ->
    fmap (curryFunction @args . toFunction) . promote $ \args ->
      runProducing (part out) . Inputs . (++ inputs) $
        hcollapse $ hcliftA (Proxy :: Proxy Consume) (K . consume . unI) args


-------------------------------------------------------------------------
-- Random destruction of the original input, as transformed into Input --
-------------------------------------------------------------------------

-- | Pattern-match on a randomly chosen single constructor of the input, and
-- produce the corresponding Variant, whose value depends on which constructor
-- was matched.
draw :: Input -> Gen (Variant, Input)
draw (Input i) =
  case i of
    Nothing  -> return $ (mempty, Input i)
    Just urn -> do
      (_, (v, Input inner), outer) <- Urn.remove urn
      return $ (v, Input $ merge inner outer)
  where
    merge :: Maybe (Urn a) -> Maybe (Urn a) -> Maybe (Urn a)
    merge left right =
      case (left, right) of
        (Nothing, Nothing) -> Nothing
        (Nothing, Just r)  -> Just r
        (Just l, Nothing)  -> Just l
        (Just l, Just r)   -> Just $ Urn.addToUrn l (contents r)

    contents :: Urn a -> [(Weight, a)]
    contents urn =
      case Urn.uninsert urn of
        (weight, a, _, Just urn') -> (weight, a) : contents urn'
        (weight, a, _, Nothing)   -> [(weight, a)]

-- | Destruct some randomly chosen subparts of the input, and return a composite
-- Variant whose entropy is derived from all the inputs destructed. The
-- probability of n pieces of input being consumed decreases as n increases.
draws :: Input -> Gen (Variant, Input)
draws i =
  oneof [ return (mempty, i)
        , do (v, i')   <- draw i
             (v', i'') <- draws i'
             return (v <> v', i'') ]


---------------------------------------------
-- Integration with QuickCheck's Arbitrary --
---------------------------------------------

-- -- | We hook into QuickCheck's existing Arbitrary infrastructure by using
-- -- a newtype to differentiate our special way of generating things.
-- newtype Lazy a = Lazy { runLazy :: a }

-- instance Produce a => Arbitrary (Lazy a) where
--   arbitrary = Lazy <$> lazy

-- -- | A universal generator for all that can be produced (including functions).
-- lazy :: Produce a => Gen a
-- lazy = produce (Inputs [])
