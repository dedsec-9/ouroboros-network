#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C.UTF-8
fd -p ouroboros-consensus \
    -e hs \
    -E Setup.hs \
    -E ouroboros-consensus/src/Ouroboros/Consensus/Storage/LedgerDB/InMemory.hs \
    -E ouroboros-consensus/src/Ouroboros/Consensus/Storage/LedgerDB/OnDisk.hs \
    -E ouroboros-consensus/src/Ouroboros/Consensus/Mempool/Impl/Pure.hs \
    -E ouroboros-consensus/src/Ouroboros/Consensus/Mempool/Impl/Types.hs \
    -E ouroboros-consensus/src/Ouroboros/Consensus/Mempool/TxLimits.hs \
    -X stylish-haskell \
    -c .stylish-haskell.yaml -i

# We don't want these deprecation warnings to be removed accidentally
grep "DEPRECATED" ouroboros-consensus/src/Ouroboros/Consensus/Storage/LedgerDB/InMemory.hs >/dev/null 2>&1
grep "DEPRECATED" ouroboros-consensus/src/Ouroboros/Consensus/Storage/LedgerDB/OnDisk.hs   >/dev/null 2>&1
grep "DEPRECATED" ouroboros-consensus/src/Ouroboros/Consensus/Mempool/Impl/Pure.hs         >/dev/null 2>&1
grep "DEPRECATED" ouroboros-consensus/src/Ouroboros/Consensus/Mempool/Impl/Types.hs        >/dev/null 2>&1
grep "DEPRECATED" ouroboros-consensus/src/Ouroboros/Consensus/Mempool/TxLimits.hs          >/dev/null 2>&1
