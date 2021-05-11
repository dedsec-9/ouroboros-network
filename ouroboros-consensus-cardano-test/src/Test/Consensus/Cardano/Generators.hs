{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuantifiedConstraints      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | 'Arbitrary' instances intended for serialisation roundtrip tests for
-- 'CardanoBlock' and its related types.
--
-- Because the generated values are only used in serialisation roundtrip tests,
-- they don't need to be valid blocks, transactions, etc.
--
-- We combine the Byron and Shelley-based instances defined elsewhere into
-- Cardano instances by picking randomly from one of the eras.
module Test.Consensus.Cardano.Generators (module Test.Consensus.Byron.Generators) where

import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Proxy
import           Data.SOP.Strict

import           Test.QuickCheck

import           Cardano.Crypto.KES.Class (Signable)
import           Cardano.Crypto.Util (SignableRepresentation)

import qualified Cardano.Ledger.Crypto as CryptoClass
import           Test.Cardano.Ledger.Alonzo.Serialisation.Generators ()

import           Ouroboros.Consensus.Block
import qualified Ouroboros.Consensus.HardFork.History as History
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.Serialisation (Some (..))
import           Ouroboros.Consensus.TypeFamilyWrappers
import           Ouroboros.Consensus.Util.Counting (NonEmpty (..),
                     nonEmptyFromList, nonEmptyToList)
import           Ouroboros.Consensus.Util.SOP (nsFromIndex)

import           Ouroboros.Consensus.HardFork.Combinator
import           Ouroboros.Consensus.HardFork.Combinator.Serialisation

import           Ouroboros.Consensus.Byron.Ledger

import           Ouroboros.Consensus.Shelley.Ledger

import           Ouroboros.Consensus.Cardano.Block
import           Ouroboros.Consensus.Cardano.Node (CardanoHardForkConstraints)

import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Serialisation.Roundtrip (WithVersion (..))

import           Test.Consensus.Byron.Generators

import           Test.Consensus.Shelley.Generators

import           Test.Consensus.Cardano.MockCrypto

{-------------------------------------------------------------------------------
  Disk
-------------------------------------------------------------------------------}

instance Arbitrary (CardanoBlock MockCryptoCompatByron) where
  arbitrary =
      oneof [
        BlockAllegra  <$> arbitrary
      , BlockByron    <$> arbitrary
      , BlockMary     <$> arbitrary
      , BlockShelley  <$> arbitrary
      ]

instance Arbitrary (CardanoHeader MockCryptoCompatByron) where
  arbitrary = getHeader <$> arbitrary

instance ( Signable (CryptoClass.KES c) ~ SignableRepresentation
         , CardanoHardForkConstraints c
         )
      => Arbitrary (OneEraHash (CardanoEras c)) where
  arbitrary = inj <$> arbitrary
    where
      inj :: NS WrapHeaderHash (CardanoEras c) -> OneEraHash (CardanoEras c)
      inj = hcollapse . hcmap proxySingle aux

      aux ::
           forall blk. SingleEraBlock blk
        => WrapHeaderHash blk -> K (OneEraHash (CardanoEras c)) blk
      aux = K . OneEraHash . toShortRawHash (Proxy @blk) . unwrapHeaderHash

instance (c ~ MockCryptoCompatByron, ShelleyBasedEra (ShelleyEra c))
      => Arbitrary (AnnTip (CardanoBlock c)) where
  arbitrary = AnnTip
      <$> (SlotNo <$> arbitrary)
      <*> arbitrary
      <*> (OneEraTipInfo <$> arbitrary)

{-------------------------------------------------------------------------------
  NodeToNode
-------------------------------------------------------------------------------}

instance CardanoHardForkConstraints c
      => Arbitrary (HardForkNodeToNodeVersion (CardanoEras c)) where
  arbitrary =
    elements $ Map.elems $ supportedNodeToNodeVersions (Proxy @(CardanoBlock c))

instance Arbitrary (BlockNodeToNodeVersion blk)
     => Arbitrary (EraNodeToNodeVersion blk) where
  arbitrary = frequency
    [ (1, pure EraNodeToNodeDisabled)
    , (9, EraNodeToNodeEnabled <$> arbitrary)
    ]

arbitraryNodeToNode
  :: ( Arbitrary (WithVersion ByronNodeToNodeVersion byron)
     , Arbitrary shelley
     , Arbitrary allegra
     , Arbitrary mary
     )
  => (byron   -> cardano)
  -> (shelley -> cardano)
  -> (allegra -> cardano)
  -> (mary    -> cardano)
  -> Gen (WithVersion (HardForkNodeToNodeVersion (CardanoEras c)) cardano)
arbitraryNodeToNode injByron injShelley injAllegra injMary = oneof
    -- Byron + HardFork disabled
    [ (\(WithVersion verByron b) ->
          WithVersion
            (HardForkNodeToNodeDisabled verByron)
            (injByron b))
        <$> arbitrary
    -- Byron + HardFork enabled.
    -- NOTE: Any value generated by the V1 generator is also fine when using
    -- V2.
    , (\(WithVersion verByron b) verShelley verAllegra verMary verAlonzo ->
          WithVersion
            (HardForkNodeToNodeEnabled
              maxBound
              (  EraNodeToNodeEnabled verByron
              :* EraNodeToNodeEnabled verShelley
              :* verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injByron b))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Shelley + HardFork enable
    , (\verByron (WithVersion verShelley s) verAllegra verMary verAlonzo ->
          WithVersion
            (HardForkNodeToNodeEnabled
              maxBound
              (  EraNodeToNodeEnabled verByron
              :* EraNodeToNodeEnabled verShelley
              :* verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injShelley s))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Allegra + HardFork enabled
    , (\verByron verShelley (WithVersion verAllegra a) verMary verAlonzo ->
          WithVersion
            (HardForkNodeToNodeEnabled
              maxBound
              (  EraNodeToNodeEnabled verByron
              :* EraNodeToNodeEnabled verShelley
              :* EraNodeToNodeEnabled verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injAllegra a))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Mary + HardFork enabled
    , (\verByron verShelley verAllegra (WithVersion verMary m) verAlonzo ->
          WithVersion
            (HardForkNodeToNodeEnabled
              maxBound
              (  EraNodeToNodeEnabled verByron
              :* EraNodeToNodeEnabled verShelley
              :* EraNodeToNodeEnabled verAllegra
              :* EraNodeToNodeEnabled verMary
              :* verAlonzo
              :* Nil
              ))
            (injMary m))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    ]

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToNodeVersion (CardanoEras c))
                                (SomeSecond (NestedCtxt Header) (CardanoBlock c))) where
  arbitrary = arbitraryNodeToNode injByron injShelley injAllegra injMary
    where
      injByron   = mapSomeNestedCtxt NCZ
      injShelley = mapSomeNestedCtxt (NCS . NCZ)
      injAllegra = mapSomeNestedCtxt (NCS . NCS . NCZ)
      injMary    = mapSomeNestedCtxt (NCS . NCS . NCS . NCZ)

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToNodeVersion (CardanoEras c))
                                (CardanoBlock c)) where
  arbitrary =
    arbitraryNodeToNode BlockByron BlockShelley BlockAllegra BlockMary

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToNodeVersion (CardanoEras c))
                                (CardanoHeader c)) where
  arbitrary =
    arbitraryNodeToNode HeaderByron HeaderShelley HeaderAllegra HeaderMary

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToNodeVersion (CardanoEras c))
                                (CardanoGenTx c)) where
  arbitrary =
    arbitraryNodeToNode GenTxByron GenTxShelley GenTxAllegra GenTxMary

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToNodeVersion (CardanoEras c))
                                (CardanoGenTxId c)) where
  arbitrary =
    arbitraryNodeToNode GenTxIdByron
                        GenTxIdShelley
                        GenTxIdAllegra
                        GenTxIdMary

{-------------------------------------------------------------------------------
  NodeToClient
-------------------------------------------------------------------------------}

instance CardanoHardForkConstraints c
      => Arbitrary (HardForkNodeToClientVersion (CardanoEras c)) where
  arbitrary =
    elements $ Map.elems $ supportedNodeToClientVersions (Proxy @(CardanoBlock c))

newtype HardForkEnabledNodeToClientVersion c = HardForkEnabledNodeToClientVersion {
      getHardForkEnabledNodeToClientVersion :: HardForkNodeToClientVersion (CardanoEras c)
    }

deriving newtype instance CardanoHardForkConstraints c
                       => Eq (HardForkEnabledNodeToClientVersion c)
deriving newtype instance CardanoHardForkConstraints c
                       => Show (HardForkEnabledNodeToClientVersion c)

instance CardanoHardForkConstraints c
      => Arbitrary (HardForkEnabledNodeToClientVersion c) where
  arbitrary =
        elements
      . map HardForkEnabledNodeToClientVersion
      . filter isHardForkNodeToClientEnabled
      . Map.elems
      . supportedNodeToClientVersions
      $ Proxy @(CardanoBlock c)

-- | Generate a supported 'HardForkNodeToClientVersion' of which the
-- 'HardForkSpecificNodeToClientVersion' satisfies the given predicate.
--
-- PRECONDITION: 'supportedNodeToClientVersions' must include a version that
-- satisfies this condition.
genWithHardForkSpecificNodeToClientVersion ::
     forall c. CardanoHardForkConstraints c
  => (HardForkSpecificNodeToClientVersion -> Bool)
  -> Gen (HardForkNodeToClientVersion (CardanoEras c))
genWithHardForkSpecificNodeToClientVersion p =
      elements
    . filter p'
    . Map.elems
    . supportedNodeToClientVersions
    $ Proxy @(CardanoBlock c)
  where
    p' :: HardForkNodeToClientVersion (CardanoEras c) -> Bool
    p' (HardForkNodeToClientEnabled v _) = p v
    p' (HardForkNodeToClientDisabled {}) = False

instance Arbitrary (BlockNodeToClientVersion blk)
     => Arbitrary (EraNodeToClientVersion blk) where
  arbitrary = frequency
    [ (1, pure EraNodeToClientDisabled)
    , (9, EraNodeToClientEnabled <$> arbitrary)
    ]

arbitraryNodeToClient
  :: ( Arbitrary (WithVersion ByronNodeToClientVersion   byron)
     , Arbitrary (WithVersion ShelleyNodeToClientVersion shelley)
     , Arbitrary (WithVersion ShelleyNodeToClientVersion allegra)
     , Arbitrary (WithVersion ShelleyNodeToClientVersion mary)
     )
  => (byron   -> cardano)
  -> (shelley -> cardano)
  -> (allegra -> cardano)
  -> (mary    -> cardano)
  -> Gen (WithVersion (HardForkNodeToClientVersion (CardanoEras c)) cardano)
arbitraryNodeToClient injByron injShelley injAllegra injMary = oneof
    -- Byron + HardFork disabled
    [ (\(WithVersion verByron b) ->
          WithVersion
            (HardForkNodeToClientDisabled verByron)
            (injByron b))
        <$> arbitrary
    -- Byron + HardFork enabled.
    , (\(WithVersion verByron b) verShelley verAllegra verMary verAlonzo ->
          WithVersion
            (HardForkNodeToClientEnabled
              maxBound
              (  EraNodeToClientEnabled verByron
              :* EraNodeToClientEnabled verShelley
              :* verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injByron b))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Shelley + HardFork enabled
    , (\verByron (WithVersion verShelley s) verAllegra verMary verAlonzo ->
          WithVersion
            (HardForkNodeToClientEnabled
              maxBound
              (  EraNodeToClientEnabled verByron
              :* EraNodeToClientEnabled verShelley
              :* verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injShelley s))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Allegra + HardFork enabled
    , (\verByron verShelley (WithVersion verAllegra a) verMary verAlonzo ->
          WithVersion
            (HardForkNodeToClientEnabled
              maxBound
              (  EraNodeToClientEnabled verByron
              :* EraNodeToClientEnabled verShelley
              :* EraNodeToClientEnabled verAllegra
              :* verMary
              :* verAlonzo
              :* Nil
              ))
            (injAllegra a))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    -- Mary + HardFork enabled
    , (\verByron verShelley verAllegra (WithVersion verMary m) verAlonzo ->
          WithVersion
            (HardForkNodeToClientEnabled
              maxBound
              (  EraNodeToClientEnabled verByron
              :* EraNodeToClientEnabled verShelley
              :* EraNodeToClientEnabled verAllegra
              :* EraNodeToClientEnabled verMary
              :* verAlonzo
              :* Nil
              ))
            (injMary m))
        <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
    ]

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (CardanoBlock c)) where
  arbitrary = arbitraryNodeToClient BlockByron BlockShelley BlockAllegra BlockMary

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (CardanoGenTx c)) where
  arbitrary = arbitraryNodeToClient GenTxByron GenTxShelley GenTxAllegra GenTxMary

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (CardanoApplyTxErr c)) where
  arbitrary = frequency
      [ (8, arbitraryNodeToClient ApplyTxErrByron ApplyTxErrShelley ApplyTxErrAllegra ApplyTxErrMary)
      , (2, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> (HardForkApplyTxErrWrongEra <$> arbitrary))
      ]
{-   TODO
  shrink = traverse aux
    where
      aux :: CardanoApplyTxErr MockCryptoCompatByron
         -> [CardanoApplyTxErr MockCryptoCompatByron]
      aux (HardForkApplyTxErrFromEra (OneEraApplyTxErr x)) =
          HardForkApplyTxErrFromEra . OneEraApplyTxErr <$> shrink x
      aux (HardForkApplyTxErrWrongEra x) =
          HardForkApplyTxErrWrongEra <$> shrink x
-}

instance Arbitrary (Some QueryAnytime) where
  arbitrary = return $ Some GetEraStart

instance CardanoHardForkConstraints c
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (Some (QueryHardFork (CardanoEras c)))) where
  arbitrary = frequency
      [ (1, do version <- getHardForkEnabledNodeToClientVersion <$> arbitrary
               return $ WithVersion version (Some GetInterpreter))
      , (1, do version <- genWithHardForkSpecificNodeToClientVersion
                            (>= HardForkSpecificNodeToClientVersion2)
               return $ WithVersion version (Some GetCurrentEra))
      ]

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (SomeSecond Query (CardanoBlock c))) where
  arbitrary = frequency
      [ (1, arbitraryNodeToClient injByron injShelley injAllegra injMary)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> (injAnytimeByron <$> arbitrary))
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> (injAnytimeShelley <$> arbitrary))
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> (injAnytimeAllegra <$> arbitrary))
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> (injAnytimeMary <$> arbitrary))
      , (1, fmap injHardFork <$> arbitrary)
      ]
    where
      injByron          (SomeSecond query) = SomeSecond (QueryIfCurrentByron     query)
      injShelley        (SomeSecond query) = SomeSecond (QueryIfCurrentShelley   query)
      injAllegra        (SomeSecond query) = SomeSecond (QueryIfCurrentAllegra   query)
      injMary           (SomeSecond query) = SomeSecond (QueryIfCurrentMary      query)
      injAnytimeByron   (Some      query)  = SomeSecond (QueryAnytimeByron       query)
      injAnytimeShelley (Some      query)  = SomeSecond (QueryAnytimeShelley     query)
      injAnytimeAllegra (Some      query)  = SomeSecond (QueryAnytimeAllegra     query)
      injAnytimeMary    (Some      query)  = SomeSecond (QueryAnytimeMary        query)
      injHardFork       (Some      query)  = SomeSecond (QueryHardFork           query)

instance Arbitrary History.EraEnd where
  arbitrary = oneof
      [ History.EraEnd <$> arbitrary
      , return History.EraUnbounded
      ]

instance Arbitrary History.SafeZone where
  arbitrary = oneof
      [ History.StandardSafeZone <$> arbitrary
      , return History.UnsafeIndefiniteSafeZone
      ]

instance Arbitrary History.EraParams where
  arbitrary = History.EraParams
      <$> (EpochSize <$> arbitrary)
      <*> arbitrary
      <*> arbitrary

instance Arbitrary History.EraSummary where
  arbitrary = History.EraSummary
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary

instance (Arbitrary a, SListI xs) => Arbitrary (NonEmpty xs a) where
  arbitrary = do
      let nbXs = lengthSList (Proxy @xs)
      len <- choose (1, nbXs)
      xs  <- vectorOf len arbitrary
      return $ fromMaybe (error "nonEmptyFromList failed") $ nonEmptyFromList xs

instance Arbitrary (History.Interpreter (CardanoEras c)) where
  arbitrary =
      History.mkInterpreter . History.Summary . enforceInvariant <$> arbitrary
    where
      -- Enforce the invariant that when the last era in the summary is the
      -- final era, it is unbounded. The decoder relies on this.
      enforceInvariant xs
        | length (nonEmptyToList xs) == lengthSList (Proxy @(CardanoEras c))
        = fixEndBound xs
        | otherwise
        = xs

      fixEndBound ::
           NonEmpty xs History.EraSummary
        -> NonEmpty xs History.EraSummary
      fixEndBound (NonEmptyCons e es) = NonEmptyCons e (fixEndBound es)
      fixEndBound (NonEmptyOne  e)    =
          NonEmptyOne  e { History.eraEnd = History.EraUnbounded }

instance Arbitrary (EraIndex (CardanoEras c)) where
  arbitrary = do
    let nbEras = lengthSList (Proxy @(CardanoEras c))
    index <- choose (0, fromIntegral nbEras - 1)
    case nsFromIndex index of
      Nothing -> error $ "nsFromIndex failed for " <> show index
      Just ns -> return $ eraIndexFromNS ns

instance c ~ MockCryptoCompatByron
      => Arbitrary (WithVersion (HardForkNodeToClientVersion (CardanoEras c))
                                (SomeResult (CardanoBlock c))) where
  arbitrary = frequency
      [ (1, arbitraryNodeToClient injByron injShelley injAllegra injMary)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryIfCurrentResultEraMismatch)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryAnytimeResultByron)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryAnytimeResultShelley)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryAnytimeResultAllegra)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryAnytimeResultMary)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryAnytimeResultAlonzo)
      , (1, WithVersion
              <$> (getHardForkEnabledNodeToClientVersion <$> arbitrary)
              <*> genQueryHardForkResult)
      ]
    where
      injByron   (SomeResult q r) = SomeResult (QueryIfCurrentByron     q) (QueryResultSuccess r)
      injShelley (SomeResult q r) = SomeResult (QueryIfCurrentShelley   q) (QueryResultSuccess r)
      injAllegra (SomeResult q r) = SomeResult (QueryIfCurrentAllegra   q) (QueryResultSuccess r)
      injMary    (SomeResult q r) = SomeResult (QueryIfCurrentMary      q) (QueryResultSuccess r)

      -- In practice, when sending a Byron query you'll never get a mismatch
      -- saying that your query is from the Shelley era while the ledger is
      -- from Byron. Only the inverse. We ignore that in this generator, as it
      -- doesn't matter for serialisation purposes, we just generate a random
      -- 'MismatchEraInfo'.
      genQueryIfCurrentResultEraMismatch :: Gen (SomeResult (CardanoBlock c))
      genQueryIfCurrentResultEraMismatch = oneof
          [ (\(SomeResult q (_ :: result)) mismatch ->
                SomeResult (QueryIfCurrentByron q) (Left @_ @result mismatch))
              <$> arbitrary <*> arbitrary
          , (\(SomeResult q (_ :: result)) mismatch ->
                SomeResult (QueryIfCurrentShelley q) (Left @_ @result mismatch))
              <$> arbitrary <*> arbitrary
          , (\(SomeResult q (_ :: result)) mismatch ->
                SomeResult (QueryIfCurrentAllegra q) (Left @_ @result mismatch))
              <$> arbitrary <*> arbitrary
          , (\(SomeResult q (_ :: result)) mismatch ->
                SomeResult (QueryIfCurrentMary q) (Left @_ @result mismatch))
              <$> arbitrary <*> arbitrary
          ]

      genQueryAnytimeResultByron :: Gen (SomeResult (CardanoBlock c))
      genQueryAnytimeResultByron =
          SomeResult (QueryAnytimeByron GetEraStart) <$> arbitrary

      genQueryAnytimeResultShelley :: Gen (SomeResult (CardanoBlock c))
      genQueryAnytimeResultShelley =
          SomeResult (QueryAnytimeShelley GetEraStart) <$> arbitrary

      genQueryAnytimeResultAllegra :: Gen (SomeResult (CardanoBlock c))
      genQueryAnytimeResultAllegra =
          SomeResult (QueryAnytimeAllegra GetEraStart) <$> arbitrary

      genQueryAnytimeResultMary :: Gen (SomeResult (CardanoBlock c))
      genQueryAnytimeResultMary =
          SomeResult (QueryAnytimeMary GetEraStart) <$> arbitrary

      genQueryAnytimeResultAlonzo :: Gen (SomeResult (CardanoBlock c))
      genQueryAnytimeResultAlonzo =
          SomeResult (QueryAnytimeAlonzo GetEraStart) <$> arbitrary

      genQueryHardForkResult :: Gen (SomeResult (CardanoBlock c))
      genQueryHardForkResult = oneof
          [ SomeResult (QueryHardFork GetInterpreter) <$> arbitrary
          , SomeResult (QueryHardFork GetCurrentEra)  <$> arbitrary
          ]
