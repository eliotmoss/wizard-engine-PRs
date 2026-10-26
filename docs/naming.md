# Names

On 2026-10-26 the persistence code's classes, files, methods and test groups
were renamed so that each name says what the code does and how it relates to
the code around it. The rename changes no behaviour: the unit suite registers
the same 2,088 tests, each under its old name with the group prefix mapped as
below; 2,081 pass and the same 7 fail as expected
(`test/unittest.failures.x86-64-linux`), as in
`results/20261025T112614Z-sean-tan-PC-unit-suite`.

Results recorded before the rename (every `results/` directory up to and
including 2026-10-25) and older commit messages use the old names. This table
maps them; docs and code use the new ones.

## The interface in one paragraph

A `StorageBackend` opens a `StorageRegion` (`open(size, access, mode)`, with
`OpenMode.FORMAT` or `ATTACH`). The region owns one `PersistenceProvider`,
through which every store, line write-back (`writeBackLine()`) and fence
(`fence()`) passes. The allocator and the log call three region methods:
`writeBack(offset, size)` starts writing changed bytes back, one
`writeBackLine()` per 64-byte line; `drain()` completes every write-back since
the last drain (one fence, and on a file backend the sync it stands for);
`persist(offset, size)` writes one range back and fences. `NativeProvider` executes
`CLWB` and `SFENCE` (the PMEM region); `MarkingProvider` marks each line's
4 KiB unit over a `StoreOnlyProvider` (the mapped-file and direct-I/O
regions); `RecordingProvider` records the trace.

## Files

| Old | New |
|---|---|
| `TxnBackend.v3` | `StorageRegion.v3` |
| `X86_64TxnBackend.v3` | `X86_64MappedBackends.v3` |
| `X86_64PersistentOperations.v3` | `X86_64Providers.v3` |
| `X86_64PersistentTrace.v3` | `X86_64PersistenceTrace.v3` |
| `X86_64DualTxnWal.v3` | `X86_64TwoSlotWal.v3` |
| `X86_64MultiTxnWal.v3` | `X86_64RingWal.v3` |
| `X86_64TxnPWRegion.v3` | `X86_64RegionAllocator.v3` |
| `X86_64PWRegion.v3` | `X86_64RegionAllocators.v3` |
| `X86_64PersistentImage.v3` | `X86_64CrashModel.v3` |
| `X86_64PersistentExplorer.v3` | `X86_64CrashExplorer.v3` |
| `X86_64PersistentLazyExplorer.v3` | `X86_64ReadDrivenExplorer.v3` |
| `X86_64PersistentRecovery.v3` | `X86_64CrashRecovery.v3` |
| `TxnPWRegionTest.v3` | `RegionAllocatorTest.v3` |
| `DualTxnWalTest.v3` | `TwoSlotWalTest.v3` |
| `FileMmapRegionTest.v3` | `MappedFileRegionTest.v3` |
| `MultiTxnWalTest.v3` | `RingWalTest.v3` |
| `RegionTransactionTest.v3` | `TransactionCacheTest.v3` |
| `PersistentOperationsTest.v3` | `ProviderTest.v3` |
| `PersistentTraceTest.v3` | `PersistenceTraceTest.v3` |
| `PersistentImageTest.v3` | `CrashModelTest.v3` |
| `PersistentExplorerTest.v3` | `CrashExplorerTest.v3` |
| `PersistentLazyExplorerTest.v3` | `ReadDrivenExplorerTest.v3` |
| `PersistentRecoveryTest.v3` | `CrashRecoveryTest.v3` |
| `PersistentAllocatorTest.v3` | `AllocatorCrashTest.v3` |
| `PersistentBTreeTest.v3` | `BTreeCrashTest.v3` |
| `PersistentSieveTest.v3` | `SieveCrashTest.v3` |
| `PersistentControlTest.v3` | `CrashControlTest.v3` |
| `ElidedWritebackOps.v3` | `ElidedWriteBackProvider.v3` |

Moved, under their new names: `WalRecordHeader`, `WalRecordTrailer` and
`WalPendingEntry` from `X86_64RingWal.v3`, and `WalEntry` and `WalEntryHandle`
from `X86_64RegionAllocator.v3`, to the new `X86_64WalRecord.v3`;
`MarkingProvider`, `StoreOnlyProvider` and `DirtyUnits` from
`X86_64DirectIoBackend.v3` to `X86_64Providers.v3`.

## The storage interface

| Old | New |
|---|---|
| `PersistentOperations` | `PersistenceProvider` |
| `BackendRegion` | `StorageRegion` |
| `TxnRegionBackend` | `StorageBackend` |
| `PersistentLoadObserver` | `LoadObserver` |
| `persistentOperations` | `provider` |
| `setPersistentOperations` | `setProvider` |
| `persistentOperationProvider` | `currentProvider` |
| `create(size, prot, fresh: bool)` | `open(size, access, mode: OpenMode)` |
| `fresh` / `forceFormat` / `initializeFresh` (`bool`) | `mode: OpenMode` (`FORMAT` for `true`, `ATTACH` for `false`) |
| `clwb(cacheLine)` (provider) | `writeBackLine(lineOffset)` |
| `sfence()` (provider) | `fence()` |
| `prepareChangedRange()` | `writeBack()` |
| `persistChanges()` | `drain()` |
| `persistRange()` | `persist()` |
| `observe()` (load observer, region reader) | `beforeLoad()` |

## Backends and regions

| Old | New |
|---|---|
| `FdMmapRegion` | `FileBackedRegion` |
| `PmemMmapRegion` | `PmemRegion` |
| `PmemMmapBackend` | `PmemBackend` |
| `FileMmapRegion` | `MappedFileRegion` |
| `FileMmapBackend` | `MappedFileBackend` |
| `FileBoundary` | `MappedFileSync` |
| `selectBoundary` | `selectSync` |
| `RegionFileIO` | `BackingFile` |
| `makePersistentRegion` | `makePmemRegion` |
| `makeFileRegion` | `makeMappedFileRegion` |
| `getPersistent` | `pmem` |
| `getFileMapped` | `mappedFile` |
| `getVolatile` | `volatile` |
| `onRangePrepared` | `onWriteBack` |
| `FileBoundary.FDATASYNC` / `MSYNC` / `LEGACY` | `MappedFileSync.FDATASYNC_ONCE` / `MSYNC_PER_RUN` / `LEGACY_RANGE_MSYNC` (the benchmarks' `boundary=` values are unchanged) |
| `boundary` (mapped-file region and backend field) | `sync` |
| `MmapRegionUtils.CACHE_LINE_SIZE`, `flushRange()` | `CacheLines.CACHE_LINE_SIZE`, `writeBackLines()` |
| `MmapRegionUtils.flushCacheLine()`, `storeFence()` | `X86_64CacheControl.writeBackLine()`, `fence()` |
| `MmapRegionUtils.PAGE_SIZE`, `convertProt()` | `RegionMapping.PAGE_SIZE`, `convertProt()` |

## Providers

| Old | New |
|---|---|
| `X86_64PersistentOperations` | `NativeProvider` |
| `RecordingPersistentOperations` | `RecordingProvider` |
| `DirectIoOperations` | `MarkingProvider` |
| `DirectIoStagingOperations` | `StoreOnlyProvider` |
| `DirectIoDirtyUnits` | `DirtyUnits` |
| `wrapProvider` | `setInnerProvider` |
| `X86_64PersistentOps` | `NativeProviders` |
| `ensureFor` | `installIfAbsent` |
| `CountingPersistentOperations` | `CountingProvider` |
| `TimingPersistentOperations` | `TimingProvider` |
| `CountingStagingOperations` | `CountingStoreOnlyProvider` |
| `PWBTreeCountingOps` | `PWBTreeCountingProvider` |
| `PersistentOperationsTester` | `ProviderTester` |
| `PersistentRewritingObserver` | `RewritingLoadObserver` |
| `PersistentLazyOperations` | `ReadDrivenProvider` |
| `ElidedWritebackOperations` | `ElidedWriteBackProvider` |
| `ElidedWritebackRecordingOperations` | `ElidedWriteBackRecordingProvider` |
| `ElidedWritebackPmemBackend` | `ElidedWriteBackPmemBackend` |
| `ElidedWritebackBackend` | `ElidedWriteBackBackend` |
| `PersistentOperationError` | `PersistenceProviderError` |
| `PersistentEventKind` | `PersistenceEventKind` |
| `PersistentTraceEvent` | `PersistenceEvent` |
| `PersistentTraceEvents` | `PersistenceEvents` |
| `PersistentLoadEvent` | `LoadEvent` |

## The region allocator

| Old | New |
|---|---|
| `PWRegion` | `RegionAllocator` |
| `ImmixPWRegion` | `ImmixRegionAllocator` |
| `ImmixPWRegions` | `ImmixLineMarks` |
| `PWRegions` | `RegionFormat` |
| `MemRegions` | `RegionDefaults` |
| `PWRegionHeader` | `RegionHeader` |
| `PWRegionUtils` | `RegionUtils` |
| `RegionTransaction` | `TransactionCache` |
| `DirectRegionWriter` | `UnloggedWriter` |
| `DirectRegionReader` | `RegionReader` |
| `BlockLists` | `FreeLists` |
| `ListKind` | `FreeListKind` |
| `BlockDevicePWRegionTester` | `MappedFileAllocatorTester` |
| `PWRegionTester` | `AllocatorTester` |
| `ImmixPWRegionTester` | `ImmixAllocatorTester` |
| `PWRegionWrapperTester` | `AllocatorFactoryTester` |
| `RecoveryPWRegionTester` | `RecoveryAllocatorTester` |
| `SmallRingPWRegionTester` | `SmallRingAllocatorTester` |
| `TracePWRegions` | `TraceAllocators` |
| `TracePWRegionBackend` | `TraceAllocatorBackend` |
| `RecoveryPWRegionBackend` | `RecoveryAllocatorBackend` |
| `RecoveryPWBackendRegion` | `RecoveryAllocatorRegion` |
| `runPWRegionWithFailure` | `runAllocatorWithFailure` |
| `recordPWRegionRecovery` | `recordAllocatorRecovery` |
| `X86_64PWMemRegion`, `X86_64PWNVRegion`, `X86_64PWBlockDeviceRegion` | `RegionAllocators.inMemory()`, `onPmem()`, `onMappedFile()` (and the new `onDirectIo()`) |
| `X86_64ImmixPWMemRegion`, `X86_64ImmixPWNVRegion` | `RegionAllocators.immixInMemory()`, `immixOnPmem()` |
| handle `getX(reader)` / `getXCached(cache)` | `getXInRegion(reader)` / `getX(cache)` |
| handle `setX(writer)` / `setXCached(cache)` | `setXUnlogged(writer)` / `setX(cache)` |
| `logChunk` (header field and compounds), "log chunk" | `logBlock`, "log block" |
| `BlockEntry`, `BlockEntryHandle` | `BlockTableEntry`, `BlockTableEntryHandle` |
| `MetaDataDesc`, `metaData` | `MetadataDescriptor`, `metadata` |

## The write-ahead logs

| Old | New |
|---|---|
| `DualTxnWal` | `TwoSlotWal` |
| `DualWalHeader` | `WalHeader` |
| `DualWalRecovery` | `WalRecovery` |
| `DualTxnWalConstants` | `WalLayout` |
| `DualTxnWalMutants` | `WalFaultInjection` |
| `MultiTxnWal` | `RingWal` |
| `MultiWalRecovery` | `RingWalRecovery` |
| `MultiTxnWalConstants` | `RingWalLayout` |
| `TxnRecordHeader` | `WalRecordHeader` |
| `TxnCommitTrailer` | `WalRecordTrailer` |
| `LogEntry` | `WalEntry` |
| `LogEntryHandle` | `WalEntryHandle` |
| `forgeLogEntry` | `forgeWalEntry` |
| `logEntryAt` | `walEntryAt` |
| `forgeDualWalHeader` | `forgeWalHeader` |
| `forgeCommitTrailer` | `forgeRecordTrailer` |
| `commitTrailerAt` | `recordTrailerAt` |
| `storeUpdate` | `storeAfterImage` |
| `applyUpdate` | `applyAfterImage` |
| `prepareApplied` | `writeBackAfterImages` |
| `persistAppliedData` | `persistAfterImages` |
| `recordDualWalRecovery` | `recordWalRecovery` |

## The crash checker

| Old | New |
|---|---|
| `PersistentTrace` | `PersistenceTrace` |
| `PersistentTraceCheck` | `TraceCheck` |
| `PersistentTraceDefect` | `TraceDefect` |
| `PersistentTraces` | `PersistenceTraces` |
| `PersistentTraceTester` | `PersistenceTraceTester` |
| `PersistentCrashMachine` | `CrashModel` |
| `PersistentMachineState` | `CrashModelState` |
| `PersistentDurableImage` | `CrashImage` |
| `PersistentLineState` | `CrashLineState` |
| `PersistentImageView` | `CrashImageView` |
| `PersistentImageViews` | `CrashImageViews` |
| `PersistentImages` | `CrashImages` |
| `PersistentImageError` | `CrashImageError` |
| `PersistentImageTester` | `CrashModelTester` |
| `PersistentExplorer` | `CrashExplorer` |
| `PersistentExploration` | `CrashExploration` |
| `PersistentExplorerError` | `CrashExplorerError` |
| `PersistentExplorerImageSet` | `CrashExplorerImageSet` |
| `PersistentExplorerTester` | `CrashExplorerTester` |
| `PersistentLineClasses` | `CrashLineClasses` |
| `PersistentClassSelection` | `CrashClassSelection` |
| `PersistentSelectionSeeds` | `CrashSelectionSeeds` |
| `PersistentSplitMix` | `CrashSplitMix` |
| `PersistentImageProperty` | `CrashImageProperty` |
| `PersistentCheckResult` | `CrashCheckResult` |
| `PersistentCounterexample` | `CrashCounterexample` |
| `PersistentRecoveries` | `CrashRecoveries` |
| `PersistentRecoveryRun` | `CrashRecoveryRun` |
| `PersistentRecoveryRecording` | `CrashRecoveryRecording` |
| `PersistentRecoveryFailureProperty` | `CrashRecoveryFailureProperty` |
| `PersistentRecoveryTester` | `CrashRecoveryTester` |
| `PersistentImageMount` | `CrashImageMount` |
| `PersistentImageMounts` | `CrashImageMounts` |
| `PersistentImageMounter` | `CrashImageMounter` |
| `PersistentImageMounters` | `CrashImageMounters` |
| `PersistentEagerMounter` | `CrashEagerMounter` |
| `PersistentAnonMounts` | `CrashAnonMounts` |
| `PersistentMountLog` | `CrashMountLog` |
| `PersistentMountError` | `CrashMountError` |
| `PersistentImageBackend` | `CrashImageBackend` |
| `PersistentRegionRun` | `CrashAllocatorRun` |
| `PersistentRegionRecording` | `CrashAllocatorRecording` |
| `PersistentWalAfterImage` | `WalAfterImage` |
| `PersistentWalHistoryProperty` | `WalHistoryProperty` |
| `PersistentWalRecoveryProperty` | `WalRecoveryProperty` |
| `PersistentAllocatorInvariants` | `AllocatorInvariants` |
| `PersistentAllocatorProperty` | `AllocatorProperty` |
| `PersistentAllocatorFailureProperty` | `AllocatorFailureProperty` |
| `PersistentAllocatorTester` | `AllocatorCrashTester` |
| `PersistentBTreeProperty` | `BTreeProperty` |
| `PersistentBTreeTester` | `BTreeCrashTester` |
| `PersistentSieveProperty` | `SieveProperty` |
| `PersistentSieveTester` | `SieveCrashTester` |
| `PersistentControlTester` | `CrashControlTester` |
| `PersistentFormatProperty` | `FormatProperty` |
| `PersistentFormatScenario` | `FormatScenario` |
| `PersistentLoadAuditChecks` | `LoadAuditChecks` |
| `PersistentLoadAuditRun` | `LoadAuditRun` |
| `PersistentLoadAudits` | `LoadAudits` |
| `PreparedRegionBackend` | `PreparedStorageBackend` |
| `cleanupBeforeDestroy` | `cleanupBeforeClose` |
| `destroy()` | `close()` |
| `PersistentLazy*` (every class) | `ReadDriven*` |

Compound names follow the same rules: `Dual(Txn)Wal` became `TwoSlotWal`,
`Multi(Txn)Wal` became `RingWal`, `FileMmap` became `MappedFile` and
`PmemMmap` became `Pmem` (for example, `persistChangesCount` became
`drainCount` and `CommitBoundaryStopFileMmapRegion` became
`CommitBoundaryStopMappedFileRegion`).

## Test groups

The tests' own names after the prefix are unchanged.

| Old prefix | New prefix |
|---|---|
| `dual_wal:` | `two_slot_wal:` |
| `file_mmap:` | `mapped_file:` |
| `multi_wal:` | `ring_wal:` |
| `persistent_alloc:` | `allocator_crash:` |
| `persistent_btree:` | `btree_crash:` |
| `persistent_control:` | `crash_control:` |
| `persistent_explore:` | `crash_explorer:` |
| `persistent_image:` | `crash_model:` |
| `persistent_lazy:` | `read_driven:` |
| `persistent_ops:` | `provider:` |
| `persistent_recovery:` | `crash_recovery:` |
| `persistent_sieve:` | `sieve_crash:` |
| `persistent_trace:` | `persistence_trace:` |
| `pwregion:` | `allocator:` |
| `pwregion_bd:` | `allocator_file:` |
| `pwregion_immix:` | `allocator_immix:` |
| `pwregion_overflow:` | `allocator_overflow:` |
| `pwregion_recovery:` | `allocator_recovery:` |
| `pwregion_wrappers:` | `allocator_factories:` |
| `region_transaction:` | `transaction_cache:` |
| `txn_backend:` | `storage_backend:` |
| `pwbtree_bd:` | `pwbtree_file:` |
| `pwsieve_bd:` | `pwsieve_file:` |

Unchanged: `direct_io:`, `pwbtree:`, `pwbtree_dio:`, `pwops:`, `pwsieve:`,
`single_wal:`.
